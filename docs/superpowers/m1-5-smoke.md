# M1.5 Smoke Notes — QQ 邮箱（IMAP/SMTP）接入

Date: 2026-09-11
Executor: AI co-founder (autonomous), macOS 26 / Xcode 26.6 / Swift 6.3 / OrbStack Docker

> **M1.5 范围：** 把 Lagoon 从「Gmail 专用」泛化成多 provider —— `MailProvider`
> 接缝（`GmailProvider` / `IMAPProvider`）+ 迁移 008（`gmail_id`→`remote_id`、
> 凭据 blob、同步健康列）+ QQ 邮箱作为 v1 主力账号，并补齐**发送闭环**
> （`MIMEBuilder` → `SMTPClient` → `POST /api/messages/{remoteId}/send` →
> ComposerSheet ⌘↩）、归档/撤销、客户端账号目录与能力门控。Gmail 路径原样保留。

## Verified end-to-end (automated)

| Check | Result |
|-------|--------|
| `bash scripts/run-all-tests.sh` | ✅ `ALL CHECKS PASSED`（守卫 → 守卫自测 → 测试库迁移 → `swift test` → 双端编译，`set -euo pipefail` 全链通过） |
| `swift test` | ✅ **323 tests, 0 failures**（M1.5 新增约 150 条：IMAP 协议层 / MIME / SMTP / 发送路由 / 客户端） |
| `swift build --product LagoonServer` | ✅ Build complete |
| `swift build --product Lagoon` | ✅ Build complete（唯一 warning 来自第三方 `swift-nio-ssl` 的 `PrivacyInfo.xcprivacy` 资源声明，非本仓库代码，M0 起既存） |
| 迁移 008 幂等重跑（测试库） | ✅ 已应用项跳过，新列/约束落库 |

各层自动化覆盖（真实 Postgres + 脚本化 transport，无网络）：

| 层 | 测试 | 覆盖点 |
|----|------|--------|
| IMAP 协议解析 | `IMAPResponseParserTests` 19 | 标签行 / untagged / 字面量 `{n}` 与续行 / `* BYE` / `BAD`·`NO` 分类 |
| IMAP 连接 | `IMAPConnectionTests` 15 | 每账号单连接串行化、greeting、命令超时、断线重连（`ScriptedTransport`） |
| IMAP 语义命令 | `IMAPClientTests` 25 | `CAPABILITY` / `AUTHENTICATE PLAIN`（失败回退 `LOGIN`）/ `ID` / `LIST` 角色解析 / `SELECT` / `UID FETCH` / `APPEND` / tagged `NO` → `authFailed` |
| IMAP provider | `IMAPProviderTests` 18 | `probe` 全链路、能力协商（归档夹缺失→创建/降级 `archiveUnavailable`）、增量拉取与 `UIDVALIDITY` 重置、归档/还原（含无 MOVE 时的 COPY+EXPUNGE）、已读、正文、IDLE 与轮询两种等待 |
| MIME | `MIMEParserTests` 11 + `GmailBodyExtractorTests` 25 | multipart 递归、base64/QP、**GBK→UTF-8**、HTML→纯文本、附件跳过 |
| 收/发信文构造 | `MIMEBuilderTests` 10 | `Re:` 前缀去重、非 ASCII 主题 RFC 2047、base64 正文 ≤76 列、`Date`/`Message-ID`、CRLF |
| SMTP | `SMTPClientTests` 7 | 命令序列、535 → `authFailed` 不重试、DATA 后失败终态、DATA 前 421 换新会话重试一次、`dotStuff` |
| 路由 | `RouteTests` 40 | IMAP 接入 probe 失败映射（401/502/409）、归档能力 409、发送 7 例（线程头/审计/错误映射）、**撤销回归 5 例**、账号目录 |
| 同步引擎 | `SyncEngineTests` 7 | `needsReconnect` 停止重试、1→300s 退避、健康上浮、能力刷新 |
| 客户端 | `APIClientTests` 20 + `LocalizationTests` 12 + `DomainCodableTests` 7 | `POST /send` 契约、QQ 表单/能力门控文案双语非空、`remoteId` 改名后的 Codable 往返 |

## NOT verified (requires founder action)

以下全部需要**真实 QQ 邮箱 + 真实网络**，自动化测试只覆盖到脚本化 transport 为止：

1. **授权码接入** —— `POST /api/accounts/imap` 对 `imap.qq.com:993` 的真实
   TLS 握手 + `AUTHENTICATE PLAIN`/`LOGIN`。未验证项：QQ 是否接受 SASL-IR 形态、
   新账号是否需要先发 `ID`。
2. **收件箱同步** —— 真实邮箱的 `UID FETCH` 数据量、`UIDVALIDITY` 稳定性、
   首次全量（最近 500 封窗口）耗时与内存。
3. **GBK 正文** —— 中文邮件正文按 GBK/GB18030 转 UTF-8 的实际解码效果
   （解析层已用 GBK fixture 覆盖，真实样张未跑）。
4. **归档文件夹实测** —— QQ 是否返回 `\Archive` SPECIAL-USE、无 SPECIAL-USE 时
   「归档」名称兜底匹配是否命中、`UID MOVE` 实际可用性。
5. **SMTP 已发送是否自动保存** —— `smtp.qq.com:465` 发出的回复，QQ Web
   「已发送」里**是否自动出现**（无 `APPEND` 到 `\Sent` 的逻辑；若 QQ 不自动保存，
   这是一个已知缺口，需要后续在 provider 里补 `APPEND`）。
6. **IDLE 延迟** —— QQ 的 IDLE 支持与推送延迟；`pullChanges` 已按
   `capabilities.idle` 二选一（IDLE / 轮询），但真实推送延迟未测。

跑法（创始人操作，记录到本文件）：

```bash
# 终端 1
set -a; source .env; set +a
export DATABASE_URL=postgres://lagoon:lagoon@127.0.0.1:5433/lagoon
swift run LagoonServer
# 终端 2
swift run Lagoon
```

1. QQ 邮箱网页版 → 设置 → 账户 → 开启 IMAP/SMTP → 生成 16 位授权码（需短信验证）
2. 客户端选「QQ 邮箱」→ 填地址 + 授权码 → 连接
3. `curl -s "http://127.0.0.1:8080/api/accounts" | python3 -m json.tool` 看
   `syncHealth.status == "ok"` 与 `lastSyncAt` 是否推进
4. 打开一封中文/GBK 邮件 → 归档 → ⌘Z 撤销 → 回复发送 → QQ Web 核对「已发送」
5. 拔网 60s → 观察状态点转 degraded → 恢复网络 → 自动恢复 ok

## Deviations from spec / plan (all documented, none blocking)

| Spec/Plan 说 | 实际 | Why |
|--------------|------|-----|
| 008 之后旧 Gmail 账号显示 `needsReconnect`（§2.6） | 实际显示为**同步失败：`not-configured`**（健康状态 `.error`，连续 3 轮后 `.degraded`） | 迁移删掉了 token 列，Gmail provider 拿不到凭据时抛 `MailError.notConfigured("gmail credentials missing")`（再取 OAuth 凭据就晚了）。恢复动作一样：**重新点 Connect Gmail** |
| 发送路由把 `subject` 填成 `Re: …`（去重） | 路由传**原样主题**，`Re:` 前缀由 `MIMEBuilder` 负责 | T10 的 `MIMEBuilderTests` 已把「去重 + 非 ASCII 编码」钉死在 builder 里，路由再加一次会双重前缀 |
| 发送路由 503 错误码 `provider-unavailable` | `provider-not-configured` | 与既有的 `providerError` 约定、T11 测试期望一致 |
| — （计划外发现）`PostgresData(jsonb:)` 的 `Encodable` 重载 | `AIActionStore.encode` 改为返回 `Data` | 传 `String` 会被二次 JSON 编码，审计 payload 变成 jsonb 里的**字符串**，撤销读不回 `remoteId`。T11 修复并加注释 |
| — （计划外发现）归档审计键 `remoteWrite` vs 撤销读 `remote` | 统一为 `remoteWrite` | 键不匹配导致撤销只改本地、**不还原远端**；T12 修复 + 回归测试 |
| — （计划外发现）分类审计 `fromGroup` 存了 `BriefingReason.needsReply.rawValue`（`"needs-reply"`） | 改存 `BriefingGroup.needsReply.rawValue`（`"needsReply"`） | 前者不是合法的 `BriefingGroup` raw value，撤销的反向覆盖**永远静默跳过**；T12 修复 + 回归测试 |

## 14 天浸泡记录（2026-09-12 → 2026-09-25）

每天用一次，勾选三项；异常记到备注（用 `GET /api/accounts` 的 `syncHealth` 佐证）。

| 日期 | 新邮件同步 | 回复发送 | 归档 + ⌘Z 撤销 | 备注 |
|------|-----------|---------|---------------|------|
| 09-12 | ☐ | ☐ | ☐ | |
| 09-13 | ☐ | ☐ | ☐ | |
| 09-14 | ☐ | ☐ | ☐ | |
| 09-15 | ☐ | ☐ | ☐ | |
| 09-16 | ☐ | ☐ | ☐ | |
| 09-17 | ☐ | ☐ | ☐ | |
| 09-18 | ☐ | ☐ | ☐ | |
| 09-19 | ☐ | ☐ | ☐ | |
| 09-20 | ☐ | ☐ | ☐ | |
| 09-21 | ☐ | ☐ | ☐ | |
| 09-22 | ☐ | ☐ | ☐ | |
| 09-23 | ☐ | ☐ | ☐ | |
| 09-24 | ☐ | ☐ | ☐ | |
| 09-25 | ☐ | ☐ | ☐ | |

## 已知缺口（M1.5 内明确不做）

- **发送后不 `APPEND` 到 `\Sent`**：依赖 QQ 服务端是否自动保存（见 NOT verified #5）。
- **无 API 鉴权**：服务端仍只绑 loopback（M0 起的取舍）。
- **单活跃账号**：多账号目录已就绪（activate/delete），但同一时刻只有一个在同步。
- **正文不落库**：按需 `FETCH`，服务端只存 headers/snippet；离线不可读。
- **Postgres 单连接**：无连接池（沿用 M0 结论）。

## Verdict

M1.5 的**协议与逻辑**层面已在自动化测试里闭环（IMAP 连接/解析/同步/归档/SMTP 发送
/撤销/能力门控，共 323 条测试全绿），剩余风险集中在「真实 QQ 服务器行为」这一类
（授权码握手细节、GBK 样张、归档夹命名、SMTP 已发送回填、IDLE 延迟），
清单见上，需要创始人用真实账号跑一遍 5 步并把结果记进本文件。
