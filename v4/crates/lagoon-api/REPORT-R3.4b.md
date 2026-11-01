# REPORT-R3.4b ——（进行中，未验收）

> 状态：**未完成，不标 complete**。下面是当前进度与剩余项，供 lead 接手或安排续做。
> 范围：`v4/crates/lagoon-api/`；已加入 `lagoon-mail` 依赖（path）。

## 已完成（代码可编译，现有测试无回归）

| 项 | 状态 |
|---|---|
| `src/provider/lagoon_mail.rs` 适配层 | 已写：`LagoonMailFactory::production()` 用 `lagoon_mail::TlsTransport`（隐式 TLS 993/465 + 平台信任库，由 lagoon-mail 负责）；`with_transport` 供测试注入 |
| 错误映射 | `MailErrorKind::AuthFailed→ProviderError::AuthFailed`、`NotConfigured→NotConfigured`、`Unreachable→Unreachable`、其余→Protocol；对应 HTTP 层 401/503/502 |
| 能力三态 | `lagoon_mail::MailCapabilities → wire::MailCapabilities`（Option<bool> 原样保留，`None` 缺键） |
| 凭据 | 继续用 `token.rs` 的裸 AES-GCM 解封，交给 `ProviderCredentials`；解不开/缺 token key 在连接路由改为 503 `provider-not-configured`（代码已改） |
| `pull_changes` | 调 lagoon-mail 的 `ImapProvider::pull_changes`，把 `SyncCursor{uid_validity,last_uid}` ↔ `MailSyncCursor{uid_validity,uid_next}` 映射；`upserts` 转换 |
| 成员填充 | 适配层用公开的 `ImapClient`（不碰协议字节）对 INBOX/archive/trash 做 `SELECT + UID SEARCH ALL + FETCH headers` 得到 remote-id 集合；超过 5000 条则返回 `None`（未知）；`reset_required` 轮不填 |
| 删除语义 | 引擎改为：只有 inbox/archived/trashed **三个集合都已知**时才计算 `local_live − union` 作为可删集合；任一未知 → 不删任何行（v3 语义）；新增 `write::live_remote_ids` |
| 构建 | `cargo build -p lagoon-api` **0 warning** |
| 回归 | `cargo test -p lagoon-api` **74/74 通过**（R3.4a 及之前全绿） |

## 未完成（因此不能验收）

1. **生产接线未做**：`AppState::new` 仍用 `NoProviderFactory`。需要决定默认后端策略（建议 `LAGOON_MAIL_PROVIDER=production|none`，默认 none 以免测试/契约跑到真实 QQ），把 `LagoonMailFactory::production()` 接进去，并让 `start_all` 只在真实 provider 启用时启动循环。
2. **适配层零测试**：尚未用 lagoon-mail 的 `ScriptedTransport` 写 probe/错误矩阵/能力三态测试（我已把该 fake 复制到 `tests/support/scripted_transport.rs`，但还没写用例；`tests/r3_provider.rs` 不存在）。
3. **成员填充的线级测试缺失**：成员逻辑只做了代码与单元级设计，尚未用脚本化 IMAP 对话验证 INBOX/archive/trash 的集合与“未知不删”。
4. **`REPORT-R3.4b.md` 的验收输出**（contract 48/48、HTTP 错误矩阵、能力三态）未采集。
5. 连接路由的 503 修改尚未由测试覆盖。

## 建议接手顺序

1. 先写 `tests/r3_provider.rs`：probe 脚本（`imap_session_script` + LIST + SELECT）断言三态；空脚本/NO LOGIN 断言 401/502；HTTP `POST /api/accounts/imap` 用 `LagoonMailFactory::with_transport` 断言 401/502。
2. 再做生产接线与 `LAGOON_MAIL_PROVIDER` 开关，跑 `contract-check-r2.sh` 确认读面不退化。
3. 最后补 member 的脚本化测试与 REPORT-R3.4b.md 真实输出。

## 风险

- 适配层每次 pull 会额外开 3 个连接（INBOX/archive/trash 成员）；在真实 QQ 上可能触及并发会话上限，建议 R3.4b 收尾时复用同一 session 或把成员查询并入 lagoon-mail（需要改 lagoon-mail，超出本次“只写 lagoon-api”的约束，需 lead 协调）。
- 大邮箱（>5000）成员返回 None：安全（不删行），但归档/垃圾箱的本地同步语义会退化到“只增不删”，需在 README 说明。
