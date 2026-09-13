# M1.5 Smoke Notes — QQ 邮箱（IMAP/SMTP）接入

Date: 2026-09-11 · reliability update: 2026-09-13
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
| `swift test` | ✅ **373 tests, 0 failures**（含写入语义、分组 override、撤销过期、AI 草稿、新邮件、幂等、稳定 Message-ID、连接池与 IMAP 串行回归） |
| `swift build --product LagoonServer` | ✅ Build complete |
| `swift build --product Lagoon` | ✅ Build complete（唯一 warning 来自第三方 `swift-nio-ssl` 的 `PrivacyInfo.xcprivacy` 资源声明，非本仓库代码，M0 起既存） |
| 迁移 008–010 幂等重跑（测试库） | ✅ 已应用项跳过；发送幂等键、稳定 IMAP 身份迁移落库 |

各层自动化覆盖（真实 Postgres + 脚本化 transport，无网络）：

| 层 | 测试 | 覆盖点 |
|----|------|--------|
| IMAP 协议解析 | `IMAPResponseParserTests` 19 | 标签行 / untagged / 字面量 `{n}` 与续行 / `* BYE` / `BAD`·`NO` 分类 |
| IMAP 连接 | `IMAPConnectionTests` 15 + `AsyncMutexTests` 1 | 每账号单连接串行化、greeting、命令超时、断线重连；跨 `await` 的命令互斥 |
| IMAP 语义命令 | `IMAPClientTests` 27 | `CAPABILITY` / `AUTHENTICATE PLAIN`（失败回退 `LOGIN`）/ `ID` / `LIST` 角色解析 / `SELECT` / `UID FETCH` / `Message-ID SEARCH` / `APPEND` / tagged `NO` → `authFailed` |
| IMAP provider | `IMAPProviderTests` 18 | `probe` 全链路、能力协商（归档夹缺失→创建/降级 `archiveUnavailable`）、增量拉取与 `UIDVALIDITY` 重置、归档/还原（含无 MOVE 时的 COPY+EXPUNGE）、已读、正文、IDLE 与轮询两种等待 |
| MIME | `MIMEParserTests` 11 + `GmailBodyExtractorTests` 25 | multipart 递归、base64/QP、**GBK→UTF-8**、HTML→纯文本、附件跳过 |
| 收/发信文构造 | `MIMEBuilderTests` 11 | 新邮件不加 `Re:`、回复前缀去重、非 ASCII 主题 RFC 2047、base64 正文 ≤76 列、`Date`/`Message-ID`、CRLF |
| SMTP | `SMTPClientTests` 7 | 命令序列、535 → `authFailed` 不重试、DATA 后失败终态、DATA 前 421 换新会话重试一次、`dotStuff` |
| 路由 | `RouteTests` 49 | IMAP 接入 probe 失败映射（401/502/409）、归档能力 409、新写/回复发送（线程头/收件人校验/审计/幂等）、**撤销回归 5 例**、账号目录 |
| AI 与连接池 | `AIGatewayTests` 23 + `MailProviderPoolTests` 2 | 批量分类不截断、连接按账号复用、授权码变化后重建 |
| 同步引擎 | `SyncEngineTests` 7 | `needsReconnect` 停止重试、1→300s 退避、健康上浮、能力刷新 |
| 客户端 | `APIClientTests` 24 + `LocalizationTests` 13 + `DomainCodableTests` 7 | 新写/回复 `POST` 契约、QQ 表单/能力门控文案双语非空、`remoteId` 改名后的 Codable 往返 |

## Verified on real QQ

2026-09-13 使用真实账号 `panbo.coding@qq.com` 和最新 Release 二进制执行
`./.build/release/LagoonServer --self-test`，结果：

```text
send: ok
archive: ok
unarchive: ok
sentFolder: ok
self-test: passed
```

同一天完成的其他真实链路验证：

1. **授权码接入** —— `imap.qq.com:993` TLS + 登录成功；当前账号能力为
   `idle=true / move=true / archiveFolder=true / serverSnippet=true`。
2. **收件箱同步** —— 真实邮箱 408 封可见邮件完成首轮同步，后续增量同步和
   IDLE 常驻正常；`syncHealth.status == "ok"`。
3. **正文阅读** —— 中文 text/plain 与 HTML 转文本样张均可打开；GBK/GB18030
   仍由 fixture 覆盖，尚未专门挑一封真实 GBK 邮件做逐字核对。
4. **归档 / 还原** —— 远端 MOVE 后撤销可回到 INBOX；稳定身份改为
   `Message-ID`，不会因归档后 UID 改变而丢失。
5. **新写 / 已发送回填** —— `POST /api/compose/send` 真实验证 SMTP 投递给本人；
   QQ 未自动保存副本，provider 已 `APPEND` 到 `Sent Messages`，延迟索引后
   `--find-subject` 同时找到 INBOX 和 Sent Messages。
6. **阅读并发** —— 对 6 封邮件同时发正文请求，全部返回 200；IMAP 命令按
   `AsyncMutex` 串行，日志不再出现 `imap.unexpectedTag`。

仍未完成的浸泡项是 **IDLE 推送延迟与长连接稳定性**；需要用 14 天每日使用记录
观察重连频率，而不是靠一次自动化自测证明。

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

只验证协议闭环而不发外部邮件时：

```bash
set -a; source .env; set +a
./.build/release/LagoonServer --self-test
```

## Deviations from spec / plan (all documented, none blocking)

| Spec/Plan 说 | 实际 | Why |
|--------------|------|-----|
| 008 之后旧 Gmail 账号显示 `needsReconnect`（§2.6） | 实际显示为**同步失败：`not-configured`**（健康状态 `.error`，连续 3 轮后 `.degraded`） | 迁移删掉了 token 列，Gmail provider 拿不到凭据时抛 `MailError.notConfigured("gmail credentials missing")`（再取 OAuth 凭据就晚了）。恢复动作一样：**重新点 Connect Gmail** |
| 发送路由把 `subject` 填成 `Re: …`（去重） | 路由传**原样主题**，`Re:` 前缀由 `MIMEBuilder` 负责 | T10 的 `MIMEBuilderTests` 已把「去重 + 非 ASCII 编码」钉死在 builder 里，路由再加一次会双重前缀 |
| 发送路由 503 错误码 `provider-unavailable` | `provider-not-configured` | 与既有的 `providerError` 约定、T11 测试期望一致 |
| — （计划外发现）`PostgresData(jsonb:)` 的 `Encodable` 重载 | `AIActionStore.encode` 改为返回 `Data` | 传 `String` 会被二次 JSON 编码，审计 payload 变成 jsonb 里的**字符串**，撤销读不回 `remoteId`。T11 修复并加注释 |
| — （计划外发现）归档审计键 `remoteWrite` vs 撤销读 `remote` | 统一为 `remoteWrite` | 键不匹配导致撤销只改本地、**不还原远端**；T12 修复 + 回归测试 |
| — （计划外发现）分类审计 `fromGroup` 存了 `BriefingReason.needsReply.rawValue`（`"needs-reply"`） | 改存 `BriefingGroup.needsReply.rawValue`（`"needsReply"`） | 前者不是合法的 `BriefingGroup` raw value，撤销的反向覆盖**永远静默跳过**；T12 修复 + 回归测试 |
| — （首次真实连接即崩 #1）`NIOAsyncChannel` 包装在 actor 协程池上执行 | 包装前 `channel.eventLoop.submit` 跳转到事件循环 | `wrappingChannelSynchronously` 必须在事件循环上运行（precondition），脚本传输测试从不触发该路径；修复 + `NIOSSLStreamTransportTests` 回归 |
| — （首次真实连接即崩 #2）IDLE 读与并发命令读重叠在同一 inbound 迭代器 | `NIOSSLStreamTransport` 改为**单后台 pump** 独占迭代器，读取方在缓冲上等待 | 读超时取消的旧读与 `capabilities()` 等并发读撞出 `NIOThrowingAsyncSequenceProducer` 单迭代器 precondition（exit 133）；pump 按 epoch 失效，`fillBuffer` 可取消且不再吞掉后续字节；修复 + 回环 TLS 并发回归测试 |
| — （Release 启动即崩 #3）`Task.sleep(for:)` 子任务释放时命中 Swift 6.3 运行时 `freed pointer was not the last allocation` | 超时改为纳秒睡眠并在任务组内等待被取消子任务退出 | Release 优化下复现、Debug 不复现；修复后 LaunchAgent 连续运行且不再产生崩溃报告 |
| — （真实详情并发失败）IMAP actor 在 `await` 时可重入，多个正文请求交错执行 tagged command | `AsyncMutex` 持有整条命令序列；每条会话串行 | 日志连续出现 `imap.unexpectedTag`，随后整批 `unreachable`；并发 6 个正文请求回归后全部 200 |
| — （详情偶发假超时）每条正文请求都新建 QQ IMAP 登录 | 路由侧 `MailProviderPool` 按账号复用 provider；正文请求上限 30s | 首次登录尾延迟可能超过原 10s；复用后正常请求约 2–3s |
| — （归档后下一封显示旧错误）导航层复用 `MessageDetailView` 的 `@State` | 两个目的地都加 `.id(remoteId)` | 换邮件时重新初始化正文、错误与加载状态 |
| — （AI briefing 整批回退）50 封分类一次请求，输出 4096 token 截断 | 每 12 封一批，严格 JSON 可完整解析 | 真实 MiniMax 日志从 `finishReason=length` 恢复为每批数百至两千 completion tokens |

## 14 天浸泡记录（2026-09-13 → 2026-09-26）

每天用一次，勾选三项；异常记到备注（用 `GET /api/accounts` 的 `syncHealth` 佐证）。

| 日期 | 新邮件同步 | 发送邮件 | 归档 + ⌘Z 撤销 | 备注 |
|------|-----------|---------|---------------|------|
| 09-13 | ☐ | ☐ | ☐ | Release 自动同步与真实自测通过；日常使用待记录 |
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
| 09-26 | ☐ | ☐ | ☐ | |

## 已知缺口（M1.5 内明确不做）

- **无 API 鉴权**：服务端仍只绑 loopback（M0 起的取舍）。
- **单活跃账号**：多账号目录已就绪（activate/delete），但同一时刻只有一个在同步。
- **正文不落库**：按需 `FETCH`，服务端只存 headers/snippet；离线不可读。
- **Postgres 单连接**：无连接池（沿用 M0 结论）。
- **附件、富文本、多草稿标签页**：当前新写与回复都是纯文本，每个草稿可恢复，
  但不能同时并排编辑多封。

## Verdict

M1.5 的协议、逻辑和主要真实 QQ 链路已经闭环：授权码登录、408 封同步、正文、
新写/回复 SMTP 发送、已发送 APPEND、归档/撤销均由自动化测试与真实自测共同覆盖（373 条
测试全绿）。剩余风险主要是 IDLE 长连接与真实 GBK 样张，需要通过 14 天日常使用
而不是一次性测试来确认。
