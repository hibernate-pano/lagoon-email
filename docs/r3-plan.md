# R3 计划：Rust 邮件协议 + 同步 + 写路径（让 v4 彻底离开 Swift）

> 前置：R1/R2 已通过（读面 48/48 契约、46/48 与 v3 同库一致，2 条为 v3 缺陷修复）。
> 目标：**发布物与开发期都不再需要 Swift 边车**；Web 的写操作打到 Rust 后端。

## 切片（互不阻塞，按依赖排序）

| 切片 | 内容 | 归属 | 验收 |
|---|---|---|---|
| **R3.1** | `crates/lagoon-mail`：provider trait、IMAP/SMTP 传输（隐式 TLS）、MIME 解析、GBK/GB18030/Shift-JIS 解码、附件/内联图提取；**假传输**测试 | rust-mail | 无网络单测覆盖：登录、SELECT、UID FETCH 头/体、MOVE、EXPUNGE、STORE、SMTP 投递、GBK 正文、多部分 MIME |
| **R3.2** | 迁移与**可写 store**：v3 的 11 条迁移在 Rust 里逐条等价；首次启动自建库 | rust-backend | Rust 建库 vs v3 建库的 `sqlite_master` dump **逐字节一致**；写入路径单测 |
| **R3.3** | 连接/探活/能力探测（QQ）：`POST /api/accounts/imap`、`activate`、`delete` | rust-backend | 契约 fixtures 覆盖；假传输下的 401/409/502/503 矩阵 |
| **R3.4** | 同步引擎：UIDVALIDITY、头/体抓取、封存写库、IDLE/轮询、退避、单写者 | rust-backend | 假传输端到端：首同步/增量/UIDVALIDITY 重置；与 v3 同库 diff 仍绿 |
| **R3.5** | 写路径：archive/delete/unarchive/restore/purge（**UIDPLUS 闸门**）、read（STORE）、pin（本地）、send（SMTP）、undo 审计 `ai_actions` | rust-backend | 3 条 `r2_skip` 纳入断言；409/410/502 矩阵；发送幂等（requestId 唯一索引） |
| **R3.6** | 外壳 `--backend rust\|swift`（默认 **swift** 直到 R3.5 完成，之后翻默认） | rust-spike | 两种后端下同一份 UI 都能跑；切换只改一个参数 |

## 不变量（每一片都必须守住）

1. **测试零外联**：所有协议测试走注入式假传输；真实邮箱只在用户明确授权后手动验。
2. **只读宪法**：同步路径用无写方法的 trait 表达（对应 v3 的 `MailSyncReading`），编译期拿不到写能力。
3. **迁移单一主权**：R3.2 之前 schema 归 v3；R3.2 通过后归 Rust，且必须先证明两边的 schema 等价。
4. **契约是唯一的对账面**：任何端点形状变化 = 先改 `docs/api-contract.md` + fixture，再改实现。
5. **密钥不落盘**：仍由外壳持有；测试用固定假密钥。

## 主要风险

| 风险 | 说明 | 应对 |
|---|---|---|
| GBK/GB18030 头与正文 | QQ 邮件最常见的中文编码坑 | `encoding_rs` + v3 的 `MIMEParser` 用例做对照表 |
| UIDVALIDITY 重置 | 重置后必须全量重同步，否则 UID 错位会删错信 | 单测强制覆盖；比对 v3 的 `SyncEngine` 行为 |
| UIDPLUS 缺失 | 退化成普通 EXPUNGE 会误删同文件夹其他客户端的待删信 | 与 v3 一致：无 UIDPLUS 直接拒绝，不降级 |
| 角色文件夹 | archive/trash/sent 依赖 `SPECIAL-USE` 或名字启发 | 探测 + 建文件夹；失败时能力闸门置 false（三态） |
| SMTP 报错解码 | 服务器返回的状态码/文本要映射成稳定错误码 | 按 v3 的映射表；未知码归 502，原文不进响应 |
| TLS 证书链 | 自签/漏链的服务器必须拒绝 | rustls-native-certs + 全验证；测试覆盖拒绝路径 |
