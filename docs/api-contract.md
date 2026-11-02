# v4 API 契约 v0.2 · Lagoon 服务端 HTTP

> 状态：**M0 冻结**（2026-10-29）。本文是 `v4/web`、`v4/shell` 与将来 `v4/crates` 对服务端行为的唯一权威描述。
> 上游事实来源：`v4/recon/server-contract.md`（逐行侦察，带 file:line）。本文是**规范性**的那一份：只写"必须是什么"，不写"为什么当年这样"。
> 可执行证据：`v4/tests/contract/`（golden fixtures，**58 条 = 56 条抓取 + 2 条 contract_expected**）+ 两个脚本。改契约 = 先改本文 + 重抓 fixtures + 再改实现。
> 前端与外壳之间的进程协议不在这里：见 [ipc-contract.md](ipc-contract.md)。

### v0.2 变更（2026-11-02，Rust 实现落地）

只改 AI 平面的两个端点，其余端点一字未动：

| 端点 | v0.1（v3 边车） | v0.2（Rust 后端） |
|---|---|---|
| `POST /api/ai/reload` | body `{environment: {[string]: string}}`（非空）→ 200 `AIStatus` | 无 body 依赖 → 200 `{ok: true, configured: bool, providers: string[]}` |
| `POST /api/ai/probe` | body `{environment}` → 200 `AIProbeResult`（13 种 outcome） | 无 body 依赖 → 200 `{ok: true, provider: string, model: string, latencyMs: int}`；503 `ai-not-configured` |

**为什么偏离 v3**：v3 的 `environment` 体是把 LLM 的 API key 从前端送到边车。v4 的密钥模型是「外壳在首次启动时生成 `keys.json`，再把环境变量注入后端进程」——密钥从不经过 HTTP 请求体，前端永远不持有它。因此 v4 的 reload/probe 只读后端进程自己的环境（`LAGOON_AI_CONFIG` 指向配置文件，key 走环境变量），不接受调用方传来的 key。

**为什么 probe 的形状也变了**：v3 的 `AIProbeResult` 枚举 13 种 outcome，前提是边车自己发 HTTP、能看到状态码与跳转。Rust 后端把失败归成三类可行动的事实——「没配置（没有 key）」、「额度用尽（402/429 或正文说余额不足）」、「连不上 / 答得不能用」——对应 503 `ai-not-configured` / 503 `ai-credit-exhausted` / 502 `provider-unreachable` / 502 `ai-error`。保留 13 种枚举反而会让前端替后端猜语义。

前端目前只调用 `GET /api/ai-status`；reload/probe 还没有界面入口，所以这两处变更不破坏任何已存在的调用方。

---

## 0. 如何验证（先看这段）

```bash
bash v4/scripts/capture-contract.sh    # 用临时边车 + 临时 SQLite + 合成数据重抓 fixtures
bash v4/scripts/contract-check.sh      # 起另一个临时边车，回放 fixtures 并 diff；不一致 → 非零退出
bash v4/scripts/contract-check.sh <base_url> <token>                # 对实现（Rust）：断言 contract_expected、跳过写路径
# 无参 = 对 v3 参考实现：含写路径、跳过 contract_expected。跳过语义见 §7
```

| 事实 | 值 |
|---|---|
| 依赖 | `bash` + `python3` + `curl` + `openssl`；**无 jq、无 Node、无 Rust** |
| 临时库位置 | `mktemp -d` 目录；**绝不**碰 `v4/.dev/data`、v3 用户库或任何邮箱 |
| 网络 | 抓取期间零外联：seed 账号的 credentials 不可解，provider 在解密阶段就失败（`MailError.notConfigured`），不会建立 socket |
| 确定性 | 同一份代码两次抓取 **byte-identical**（键已规范化排序；时间戳按 key 归一为 `"<timestamp>"`） |

---

## 1. 传输层（前端/外壳实现前必须照做）

| 项 | 契约 |
|---|---|
| 基址 | `http://127.0.0.1:<port>`；端口由外壳选空闲端口（**不固定 8080**）。开发期浏览器模式用 `VITE_SIDECAR_URL` |
| 鉴权 | 所有 `/api/*` 需要 `Authorization: Bearer <token>`。**唯一例外**：`GET /healthz` 不需要。缺失/错误一律 401 `{"error":"api-unauthorized"}` |
| Host 守卫 | 请求的 Host 必须是 `127.0.0.1` / `localhost` / `::1`（或配置的绑定地址）；否则 403 `{"error":"forbidden-host"}`。**浏览器 dev 模式也受此约束**，所以只能打回环地址 |
| CORS | **无**。服务端不发任何 `Access-Control-*` 头。浏览器直连（非 Tauri）必须走 Vite 代理或 `dev.sh` 提供的同源路径；生产期一律走 Rust 代理（见 ipc-contract §1） |
| Content-Type（响应） | JSON：`application/json; charset=utf-8`；`/healthz`：`text/plain; charset=utf-8` 体为 `ok`；附件：原 MIME；`raw.eml`：`message/rfc822`；**204**：无 body、无 Content-Type |
| Content-Type（请求） | 有 body 时必须是 `application/json`；服务器不校验该头，但解析失败会按各端点的"格式错误"码返回 400 |
| 日期 | 线上 **ISO-8601**（`2025-01-03T09:00:00Z`）。客户端解码必须用 `.iso8601` 策略，默认策略会失败 |
| 请求体上限 | 1 MB；仅 `send` / `compose/send` / `forward` 例外为 64 MB |
| 流式 | **没有** SSE / WebSocket / 长轮询 / chunked。所有"推送"由客户端轮询（列表与账号目录 30s） |
| 幂等 | 仅发送类端点接受 `requestId`（UUID 字符串）；同一个 requestId 重放返回首次结果，不重复发信。其余端点不幂等 |

---

## 2. 错误封装与「不知道」

### 2.1 唯一错误形状

```json
{"error": "<稳定 code>"}
```

- 没有 `message`、没有堆栈、没有上游原文；**前端不得展示未经翻译的 code**，也不得把它当自然语言。
- 未命中的路由由框架兜底：**404，空 body，无 Content-Type**（不是错误封装）。前端必须能处理"body 为空"。
- 5xx 的 code 只有 `internal-error` / `ai-error` / `smtp-send-failed` / `provider-unreachable` 等少数稳定值；其余细节只在服务端日志。

### 2.2 状态码总表

| 状态 | 含义 | 典型 code |
|---|---|---|
| 200 | 成功（含"业务上没什么可做"的诚实结果，如 `sent.stale`） | — |
| 201 | 新建（连接账号、建聚合规则） | — |
| 204 | 成功且无 body（激活账号、标记已读默认路径、删除规则成功外的多数写操作） | — |
| 400 | 参数/请求体形状错误 | `malformed-*`、`invalid-*`、`missing-body`、`empty-remoteIds` |
| 401 | 凭据缺失/错误（API token 或 IMAP/SMTP 凭据） | `api-unauthorized`、`imap-auth-failed`、`smtp-auth-failed`、`provider-auth-failed` |
| 403 | Host 非法，或跨账号访问唯一一处（草稿选择） | `forbidden-host`、`draft-different-account` |
| 404 | 目标不存在；也用于"能力确定的否定"（`sent-unavailable`） | `unknown-account`、`unknown-message`、`unknown-stack`、`unknown-draft`、`unknown-reminder`、`unknown-advice`、`unknown-action`、`sent-unavailable` |
| 409 | 冲突或能力闸门 | `archive-unavailable`、`delete-unavailable`、`not-in-trash`、`send-in-flight`、`already-undone`、`account-exists` |
| 410 | 邮件已在服务端消失；撤销过期 | `message-gone`、`action-expired` |
| 413 | 附件超限（单附件 25 MB） | `attachment-too-large` |
| 422 | 退订无法自动完成 | `unsubscribe-unavailable`、`unsubscribe-manual-required`、`unsubscribe-page-required` |
| 500 | 本地存储/加密失败 | `internal-error`、`draft-seal-failed`、`draft-unreadable`、`undo-failed` |
| 502 | 邮件服务器或模型侧失败 | `provider-unreachable`、`smtp-send-failed`、`ai-error`、`unsubscribe-failed`、`forward-original-unavailable` |
| 503 | 未配置（没有可用的 provider / AI），不是故障 | `provider-not-configured`、`ai-not-configured`、`ai-credit-exhausted`、`ai-budget-exceeded`、`ai-circuit-open` |

### 2.3 「不知道」的表示（前端六态的硬约束）

**HTTP 没有"未知"状态。未知只能由字段缺席表达，绝不能用 0 / false / 空字符串冒充。** 实现时必须遵守：

| 位置 | 规则 |
|---|---|
| `MailCapabilities` 的 `archiveFolder` / `uidplus` / `sentFolder` / `trashFolder` | 三态：`null`/`缺席` = **未探测**；`false` = **已确认没有**。只有 `false` 才关闭 UI 动词；`null` 读作"允许"，真正的拒绝由服务端 409 给 |
| `SyncResponse.totalCount`、`AIActionListResponse.totalCount/hasMore`、`SearchResponse.totalCount/truncated/bodyScanSkipped`、`FolderCounts.sent` | 可为 `null`/`缺席`。"缺"≠"0"。缺席时前端不显示数字，而不是显示 0 |
| `SentResponse.staleReason` | 非 null = 服务端拉取失败、列表是旧数据。UI 必须显示"可能不是最新"，而不是假装成功或报错 |
| `BriefingResponse.omittedCount/backlogCount` | 缺失 = 该服务端没有这个数；0 = 确实没有 |
| `AIStatus` | `configured=false` 是**正常降级**（启发式仍在工作），不是错误 |

调用方判断顺序：**先看 HTTP 状态 → 再看 body 的 `error` code → 最后才看可选字段是否缺席**。把 `ok:false`（IPC 传输失败）与 4xx 混为一谈是明令禁止的（见 ipc-contract §4.2）。

---

## 3. 共享数据类型（逐字段）

字段名即 JSON 键，**全 camelCase**（数据库列名 snake_case 与线上无关）。

| 类型 | 字段 |
|---|---|
| `MessageHeader` | `id: UUID, accountId: UUID, remoteId: string, threadId: string, fromAddress: string, fromName?: string, subject?: string, snippet?: string, receivedAt: ISO date, isRead: bool, isArchived: bool, isDeleted: bool, isPinned: bool, isSent: bool, messageIdHeader?: string, inReplyTo?: string, references?: string` |
| `SyncCursor` | `accountId: UUID, lastFetchedAt: ISO date, totalUnread: int` |
| `SyncResponse` | `cursor: SyncCursor, messages: MessageHeader[], totalCount?: int` |
| `ConnectedAccount` | `id: UUID, provider: "qq", email: string, isActive: bool, unreadCount: int, syncHealth: SyncHealth, capabilities: MailCapabilities` |
| `SyncHealth` | `status: "ok"｜"degraded"｜"needsReconnect"｜"error"｜"accountMissing", lastSyncAt?: ISO date, lastError?: string` |
| `MailCapabilities` | `archiveFolder?: bool, idle: bool, move: bool, serverSnippet: bool, uidplus?: bool, sentFolder?: bool, trashFolder?: bool, archiveFolderName?: string` |
| `MessageBody` | `remoteId: string, subject?: string, fromAddress: string, fromName?: string, toAddress?: string, receivedAt: ISO date, text: string, html?: string, attachments: Attachment[], hasMore: bool, to: string[], cc: string[]` |
| `Attachment` | `id: string, filename?: string, mimeType: string, size: int, contentId?: string, disposition: "attachment"｜"inline"` |
| `MessageSummary` | `remoteId: string, summary: string, actionItems: string[], provider?: string` |
| `InlineImagesResponse` | `images: { [contentIdLowercase: string]: base64 }` |
| `SendResponse` | `ok: bool, providerMessageId?: string` |
| `DraftReply` | `id: int64, accountId: UUID, remoteId: string, variants: string[], chosenVariant?: int, createdAt: ISO date` |
| `StateChangeResponse` | `ok: bool, remoteId: string, actionId?: int64` |
| `ArchiveResponse` | `ok: bool, remoteId: string, remote: bool, actionId: int64` |
| `PurgeResponse` | `ok: bool, remoteId: string, purged: int`（**无 actionId**：不可撤销） |
| `ArchiveBulkResponse` | `items: {remoteId, ok, actionId?, errorCode?}[], truncatedCount?: int` |
| `UndoResponse` / `UndoBulkResponse` | `{ok, undone}` / `{items:{actionId, ok, errorCode?}[], undone}` |
| `UnsubscribeResponse` | `ok: bool, unsubscribed: bool, publisher: string, actionId: int64` |
| `ClassifyResponse` | `ok: bool, actionId: int64, fromGroup: string, toGroup: string` |
| `AIAction` | `id: int64, accountId: UUID, kind: enum, payload: {[string]: string}, createdAt: ISO date, expiresAt?: ISO date`；kind ∈ `archive｜read｜pin｜unpin｜unsubscribe｜classify_override｜draft_create｜send｜undo｜delete｜purge` |
| `AdviceRecord` | `id: int64, accountId: UUID, remoteId: string, advice: {action, category?, confidence, rationale?, dueText?}, source: "heuristic"｜"ai", model?: string, decision: "pending"｜"accepted"｜"dismissed", createdAt, decidedAt?` |
| `BriefingResponse` | `items: {message: MessageHeader, group: "needsReply"｜"awaitingReply"｜"safeToArchive"｜"subscriptionNoise"｜"pinned", reasonCode?: string}[], omittedCount?: int, backlogCount?: int` |
| `SearchResponse` | `results: MessageHeader[], query: string, totalCount?: int, truncated?: bool, bodyScanSkipped?: int, bodyScanLimit?: int` |
| `FolderCountsResponse` | `counts: {id: "live"｜"unread"｜"archived"｜"pinned"｜"deleted"｜"sent", count: int}[]` |
| `SenderListResponse` | `senders: {address, displayName?, totalCount, unreadCount, latestAt: ISO date}[]` |
| `StackSummary` | `rule: {id: UUID, accountId: UUID, name, kind: "sender"｜"keyword", value, createdAt}, count: int` |
| `Reminder` | `id: int64, accountId: UUID, remoteId: string, subject?: string, dueAt: ISO date, note?: string, createdAt: ISO date, dismissedAt?: ISO date` |
| `TimeSavedReport` | `today: Window, week: Window`；Window = `{minutesSaved: double, messagesHandled, draftsSent, unsubscribed, byDay: {date, minutesSaved, messagesHandled}[]}` |
| `UsageReport` | `monthUSD: double, capUSD: double, callCount: int, costTrackingAvailable: bool, accounts: {accountEmail, monthUSD, callCount}[]` |
| `AIStatus` | `configured: bool, creditExhausted: bool, circuitOpen: bool` |
| `AIReloadResult` | `ok: bool, configured: bool, providers: string[]`（v0.2；reload 之后的真实状态） |
| `AIProbeResponse` | `ok: bool, provider: string, model: string, latencyMs: int`（v0.2） |
| `AIProbeResult` | **v3 遗留，本文不再使用**。v0.1 形状：`outcome: reachable｜unauthorized｜notFound｜outOfCredit｜rateLimited｜rejected｜providerError｜unexpectedResponse｜timedOut｜unreachable｜redirected｜invalidSettings｜serviceError, httpStatus?: int, detail?: string` |
| `SentResponse` | `messages: MessageHeader[], totalCount: int, refreshedFromServer: int, staleReason?: string` |
| `StoreNotice` | `id: string, createdAt: ISO date, detail?: string` |

---

## 4. 端点字典

列说明：**远端** = `✉写` 改远端邮箱 / `✉读` 读远端 / `⊕` 出站网络非邮箱 / `—` 纯本地。**fixture** = `tests/contract/fixtures/fixtures.json` 中覆盖它的条目（`—` = 只有本文定义，尚未被 fixture 锁定）。

### 4.1 健康与账号

| Method Path | 入参 | 成功 | 错误 | 远端 | fixture |
|---|---|---|---|---|---|
| `GET /healthz` | 无（**免鉴权**） | 200 `text/plain` 体 `ok` | — | — | `healthz` |
| `GET /api/accounts` | 无 | 200 `ConnectedAccount[]` | 500 `internal-error` | — | `accounts.list` |
| `POST /api/accounts/imap` | body `{provider:"qq", email, authCode}` | 201 `ConnectedAccount` | 400 `missing-body`/`missing-field`；401 `imap-auth-failed`；409 `account-exists`；502 `imap-unreachable`；503 `provider-not-configured` | ✉读（IMAP LOGIN 探活） | — |
| `POST /api/accounts/:id/activate` | 路径 id=UUID | 204 | 404 `unknown-account`（含 id 非 UUID） | — | — |
| `DELETE /api/accounts/:id` | 路径 id=UUID | 204 | 404 `unknown-account` | — | — |

### 4.2 列表与同步

| Method Path | 入参 | 成功 | 错误 | 远端 | fixture |
|---|---|---|---|---|---|
| `GET /api/messages` | query：`accountId`（**必**，UUID）、`limit`（默认 500，上限 1000）、`sender`（精确 from_address）、`archived`/`deleted`/`pinned`/`unread`（字符串 `"true"`；其他值视为 false）、`stackId`（UUID） | 200 `SyncResponse` | 400 `malformed-accountId`；404 `unknown-stack`；500 | — | `messages.list*`（6 条） |
| `POST /api/sync` | 无 | 204 | — | ✉读（重启同步循环） | — |

列表语义：`pinned` 是**独立 lens**（忽略 archived/deleted 轴）；`deleted` 忽略 archived 轴；`sent` 只能通过 `/api/sent` 看到（列表接口没有 sent 参数）。`totalCount` 忽略 `limit`，用于"被截断但仍真实"的显示。

### 4.3 单封邮件

| Method Path | 入参 | 成功 | 错误 | 远端 | fixture |
|---|---|---|---|---|---|
| `GET /api/messages/:remoteId/body` | query `accountId` | 200 `MessageBody`（命中本地缓存即返回） | 400 `malformed-accountId`/`malformed-remoteId`；404 `unknown-account`；410 `message-gone`；401 `provider-auth-failed`；413 `attachment-too-large`；502 `provider-unreachable`；503 `provider-not-configured` | ✉读（未缓存时） | `body.provider-unconfigured`（503 路径） |
| `GET /api/messages/:remoteId/attachments/:attachmentId` | query `accountId` | 200 二进制；`Content-Type`=原 MIME；`Content-Disposition: attachment; filename="…"; filename*=UTF-8''…` | 400；404 `attachment-not-found`/`unknown-account`；413 `attachment-too-large`；401；502；503 | ✉读（每次重解析整封） | — |
| `GET /api/messages/:remoteId/raw.eml` | query `accountId` | 200 `message/rfc822`，文件名 = subject（≤80）`.eml` | 同 attachments（无 413） | ✉读 | `raw-eml.provider-unconfigured`（503 路径） |
| `GET /api/messages/:remoteId/inline-images` | query `accountId` | 200 `InlineImagesResponse`（≤40 张且 ≤8 MB；键为小写、去尖括号的 content-id） | 400；404 `unknown-account`；410；401；502；503 | ✉读（一次读整封） | `inline-images.provider-unconfigured`（503 路径） |
| `GET /api/messages/:remoteId/summary` | query `accountId`；header `Accept-Language` | 200 `MessageSummary` | 503 `ai-not-configured`/`ai-credit-exhausted`/`ai-budget-exceeded`/`ai-circuit-open`；502 `ai-error`/`provider-unreachable`；400；404；410；401 | ⊕ LLM | — |

### 4.4 本地状态写（不改远端）

| Method Path | 入参 | 成功 | 错误 | 远端 | fixture |
|---|---|---|---|---|---|
| `POST /api/messages/:remoteId/read` | query `accountId`；`isRead` 默认 `true`（接受 true/1/yes、false/0/no）；`record` 默认 `false` | `record=false` → **204 无 body**；`record=true` → 200 `StateChangeResponse` | 400 `malformed-isRead`；404 `unknown-account`；500 | ✉写（`\Seen`，best-effort：失败只记日志） | `read.mark-read`、`read.recorded` |
| `POST /api/messages/:remoteId/pin` | query `accountId`、`pinned`（**必**，`true`/`false`） | 200 `StateChangeResponse` | 400 `malformed-pinned`；404 `unknown-account`；500 | — | `pin.set` |
| `POST /api/messages/:remoteId/classify` | query `accountId`；body `{toGroup, fromGroup?, scope?}` | 200 `ClassifyResponse` | 400 `invalid-group`/`invalid-body`/`missing-body`；404 `unknown-account` | — | — |

### 4.5 邮件动作（远端写，可撤销）

| Method Path | 入参 | 成功 | 错误 | 远端 | fixture |
|---|---|---|---|---|---|
| `POST /api/messages/:remoteId/archive` | query `accountId` | 200 `ArchiveResponse` | 409 `archive-unavailable`；404；502；503 | ✉写 MOVE | `archive.capability-gate`（409 路径） |
| `POST /api/messages/:remoteId/unarchive` | 同上 | 200 `ArchiveResponse` | 409 `archive-unavailable`；404；502 | ✉写 MOVE | — |
| `POST /api/messages/:remoteId/delete` | 同上 | 200 `ArchiveResponse` | 409 `delete-unavailable`；404；502 | ✉写→服务器废纸篓 | — |
| `POST /api/messages/:remoteId/restore` | 同上 | 200 `ArchiveResponse` | 409 `delete-unavailable`；404；502 | ✉写→回 INBOX | — |
| `POST /api/messages/:remoteId/purge` | 同上 | 200 `PurgeResponse`（无 actionId，**不可撤销**） | 409 `not-in-trash`；404；502 | ✉写 `UID EXPUNGE`（需 UIDPLUS） | — |
| `POST /api/trash/empty` | query `accountId` | 200 `PurgeResponse`（`remoteId:"", purged:N`） | 500 | ✉写 批量 EXPUNGE | — |
| `POST /api/delete-bulk` | query `accountId`；body `{remoteIds?: string[], allMatching?: bool, archived?: bool, deleted?: bool, sent?: bool, stackId?: UUID}` | 200 `ArchiveBulkResponse`（单次最多 500 条） | 400 `empty-remoteIds`/`invalid-body`/`missing-body`；404 `unknown-stack` | ✉写（逐条） | — |
| `POST /api/archive-bulk` | query `accountId`；body `{remoteIds: string[]}` | 200 `ArchiveBulkResponse` | 400 `empty-remoteIds`/`invalid-body`；409 `archive-unavailable` | ✉写（逐条） | — |
| `POST /api/messages/:remoteId/unsubscribe` | query `accountId` | 200 `UnsubscribeResponse` | 422 `unsubscribe-unavailable`/`-manual-required`/`-page-required`；502 `unsubscribe-failed`/`provider-unreachable`；401；500 | ⊕ 向发布方发 HTTP；本地归档+已读 | — |

批量语义：`remoteIds` 与 `allMatching` 二选一；单次最多 500，超出部分由 `truncatedCount` 报告；`items` 逐条报告成功/失败（部分成功是正常结果，**不是**错误）。

### 4.6 撤销与历史

| Method Path | 入参 | 成功 | 错误 | 远端 | fixture |
|---|---|---|---|---|---|
| `GET /api/actions` | query `accountId`；`since`（ISO-8601）；`limit` 默认 100 上限 500；`before`=actionId（keyset 翻页） | 200 `{actions: AIAction[], totalCount?, hasMore?}` | 400 `malformed-before`/`unknown-before`；500 | — | — |
| `POST /api/actions/:id/undo` | query `accountId` | 200 `UndoResponse` | 400 `not-undoable`/`malformed-action-id`；404 `unknown-action`；409 `already-undone`；410 `action-expired`；500 `undo-failed` | 视 kind（可能 ✉写） | — |
| `POST /api/actions/undo-bulk` | query `accountId`；body `{actionIds: int64[]}`（去重，≤500） | 200 `UndoBulkResponse`；逐条 code ∈ `not-undoable｜unknown-action｜action-expired｜already-undone｜undo-failed` | 400 `empty-actionIds`；404 `unknown-account`；500 | 同上 | — |

### 4.7 发送与草稿

| Method Path | 入参 | 成功 | 错误 | 远端 | fixture |
|---|---|---|---|---|---|
| `POST /api/messages/:remoteId/send` | query `accountId`；body `{body, requestId?, to?: string[], cc?: string[], bcc?: string[], attachments?: {filename, mimeType, dataBase64}[]}` | 200 `SendResponse` | 400 `malformed-body`/`-recipient`/`-attachment`/`-request-id`；404 `unknown-account`/`unknown-message`；409 `send-in-flight`；410 `message-gone`；401 `smtp-auth-failed`；502 `smtp-send-failed`；503 | **✉写 SMTP** | — |
| `POST /api/compose/send` | query `accountId`；body `{to: string, subject, body, requestId?, cc?, bcc?, attachments?}` | 200 `SendResponse` | 400 `malformed-compose`/`-recipient`/`-attachment`/`-request-id`；404 `unknown-account`；409；401；502；503 | **✉写 SMTP** | — |
| `POST /api/messages/:remoteId/forward` | query `accountId`；body `{to: string[], body?, subject?, cc?, bcc?, requestId?}` | 200 `SendResponse` | 400 `malformed-forward`/`-recipient`/`-request-id`；404；410；502 `forward-original-unavailable`；401；503 | **✉写 SMTP** | — |
| `POST /api/messages/:remoteId/draft` | query `accountId`；header `Accept-Language` | 200 **裸 `DraftReply`** | 404 `unknown-account`；503 `ai-*`；502 `ai-error`；500 `draft-seal-failed`/`internal-error` | ⊕ LLM | — |
| `GET /api/messages/:remoteId/drafts` | query `accountId` | 200 `{drafts: DraftReply[]}` | 500 `draft-unreadable` | — | — |
| `POST /api/drafts/:id/choose` | query `accountId`；body `{variant: int}` | 200 `{ok, draftId, chosen}` | 400 `malformed-draft-id`/`invalid-body`/`variant-out-of-range`；403 `draft-different-account`；404 `unknown-draft`；500 | — | — |

发送语义：附件的 `dataBase64` 总上限约 48 MB（单文件 25 MB）；**任一附件解码失败则整封拒绝**，绝不静默丢附件；`to` 中任一地址非法 → 400，绝不静默丢收件人。

### 4.8 只读视图

| Method Path | 入参 | 成功 | 错误 | fixture |
|---|---|---|---|---|
| `GET /api/briefing` | query `accountId`；`limit` 默认/上限 500；header `Accept-Language` | 200 `BriefingResponse` | 400 `malformed-accountId`；404；500 | `briefing` |
| `GET /api/search` | query `q`（空 → 空结果 200）；`accountId`=UUID｜`all`｜缺省；`sender`；`since` | 200 `SearchResponse`（结果上限 100；解封扫描预算 1000） | 400 `malformed-accountId`；500 | `search.contract`、`search.contract.sealed-body`（contract_expected，见 §7.1） |
| `GET /api/advice` | query `accountId`；`decision`（缺省/空=pending，`any`=全部，或 accepted/dismissed）；`limit` 默认 200 上限 500 | 200 `{advice: AdviceRecord[]}` | 400 `malformed-decision`；404 | `advice.list` |
| `GET /api/advice/accepted-stats` | query `accountId` | 200 `{stats: {category?, action, count}[]}`（最多 5） | 400；404 | — |
| `POST /api/advice/:id/decision` | query `accountId`；body `{decision}` | 200 `{id, decision}` | 400；404 `unknown-advice` | — |
| `GET /api/stacks` | query `accountId` | 200 `{stacks: StackSummary[]}` | 400；500 | `stacks.list` |
| `POST /api/stacks` | query `accountId`；body `{name, kind, value}`（name ≤80，value ≤200） | 201 `{stack: StackSummary}` | 400 `invalid-name`/`-value`/`-kind`；500 | — |
| `PATCH /api/stacks/:id` | query `accountId`；body `{name?, kind?, value?}` | 200 `{stack: StackSummary}` | 400；404 `unknown-stack` | — |
| `DELETE /api/stacks/:id` | query `accountId` | 200 `{ok: true}` | 404 `unknown-stack` | — |
| `GET /api/reminders` | query `accountId`；`includeDismissed="true"` | 200 `{reminders: Reminder[]}` | 400；404 | `reminders.list` |
| `POST /api/reminders` | query `accountId`；body `{remoteId, dueAt: ISO, note?}` | 200 **裸 `Reminder`** | 400 `malformed-remoteId`/`-body`/`reminder-due-in-past`；404 `unknown-account`/`unknown-message` | — |
| `POST /api/reminders/:id/dismiss` | query `accountId`；body `{dismissed?: bool}`（空体=dismiss） | 200 **裸 `Reminder`** | 400 `malformed-reminderId`；404 `unknown-reminder` | — |
| `DELETE /api/reminders/:id` | query `accountId` | 204 | 400 `malformed-reminderId`；500（**不存在也 204**，实现无存在性检查） | — |
| `GET /api/senders` | query `accountId`；`limit` 默认 60 上限 300；`q` 子串 | 200 `SenderListResponse` | 400；404 | `senders` |
| `GET /api/sent` | query `accountId`；`limit` 上限 1000 | 200 `SentResponse` | 404 `sent-unavailable`/`unknown-account`；400；500 | `sent.stale`（200 + staleReason） |
| `GET /api/folder-counts` | query `accountId` | 200 `FolderCountsResponse` | 400；404 | `folder-counts` |
| `GET /api/export/index` | query `accountId` | 200 `{messages: MessageHeader[], totalCount, deletedCount, sentCount}`（全量、oldest first） | 400；404 | `export.index` |
| `GET /api/time-saved` | query `accountId` | 200 `TimeSavedReport` | 400；500 | `time-saved` |
| `GET /api/usage` | 无 | 200 `UsageReport` | —（分项失败降级为空数组） | `usage` |
| `GET /api/ai-status` | 无 | 200 `AIStatus` | — | `ai-status` |
| `GET /api/store-notices` | 无 | 200 `{notices: StoreNotice[]}` | 500 | `store-notices` |
| `POST /api/store-notices/:id/ack` | 路径 id | 200 `{ok: true, id}` | 400 `malformed-noticeId` | — |
| `POST /api/ai/reload` | 无 body（v0.2：不再收 `environment`） | 200 `AIReloadResult` | 500 `internal-error`（配置文件读不出来） | — |
| `POST /api/ai/probe` | 无 body（v0.2：不再收 `environment`） | 200 `AIProbeResponse` | 503 `ai-not-configured`/`ai-credit-exhausted`/`ai-circuit-open`；502 `provider-unreachable`/`ai-error` | — |

---

## 5. 语义规则（跨端点）

| 规则 | 契约 |
|---|---|
| UUID | 线上恒为 36 字符字符串；库里是 16 字节 BLOB。**不存在**"文本形式的 UUID 也能查到"的兼容路径 |
| 能力闸门 | `archiveFolder=false` → 409 `archive-unavailable`（在**任何写入之前**）；`trashFolder=false` → 409 `delete-unavailable`；`uidplus=false` → 409 `delete-unavailable`（彻底删除）；`sentFolder=false` → 404 `sent-unavailable` |
| 撤销 | 只有 `archive/read/pin/unpin/classify_override/delete` 可撤销；`unsubscribe/send/draft_create/purge` 不可撤销（400 `not-undoable`）；撤销本身不可再撤销、单次使用、30 天过期 |
| 幂等 | `send`/`compose/send`/`forward` 的 `requestId` 是**幂等键**；同 key 并发 → 409 `send-in-flight`；同 key 重放 → 200 首次结果 |
| 附件下载 | 每次都从 IMAP 重新解析整封（无缓存）；单附件 25 MB 上限；下载响应带 RFC 6266 `filename*` |
| 列表截断 | 列表上限 1000；超限由 `totalCount` 暴露；**禁止**把截断列表当全量渲染 |
| AI 只读 | AI 永不直接写邮箱；AI 侧产生的写只有 `advice`/`ai_overrides`/`draft_replies`/`usage_log`/`ai_actions` |

---

## 6. 封存列（前端不需要，但错误文案与迁移需要知道）

| 列 | 封存 | 信封 |
|---|---|---|
| `message_headers.snippet_cipher` | 是 | `lgb1:` + base64(nonce‖ct‖tag)，AES-256-GCM |
| `message_bodies.body_cipher`、`body_html_cipher` | 是 | 同上 |
| `draft_replies.variants`（整个数组一个信封） | 是 | 同上 |
| `accounts.credentials` | 是 | 裸 `AES.GCM.SealedBox.combined`（无前缀） |
| 发件人/主题/时间/附件名/to/cc | **否**（故意明文） | — |

解不开时：`500 draft-unreadable`（草稿）、`500 internal-error`（正文缓存被当作缓存丢弃并重取）；`GET /api/store-notices` 会给出 `body-key-lost` 通知。

---

## 7. fixture 状态与跳过语义（含 v3 已知缺陷）

每条 fixture 的「期望值来源」写在 JSON 自身里，不在文档另记一份。三种状态：

| 状态 | 字段 | 默认行为 | 断言方式 |
|---|---|---|---|
| 正常（49 条） | — | 断言 | — |
| R2 写路径（3 条） | `r2_skip: "<原因>"` | **跳过**（capture 仍抓 v3 真实响应） | `--include-write` 或 `LAGOON_CONTRACT_INCLUDE_WRITE=1` |
| 契约应为（2 条） | `contract_expected: true` + `defect_evidence` | **跳过**（v3 参考实现无法满足） | `--assert-contract-expected`；两参数 `contract-check.sh <url> <token>` 默认开启 |

- **`r2_skip`**：写路径，Rust R2 是 READ_ONLY。capture 照抓（v3 真实行为），check 默认跳过；对 Rust 跑两参数模式时这些不出现在断言里。当前 3 条：`read.mark-read`、`read.recorded`、`pin.set`。
- **`contract_expected`**：期望值是**契约应为**，不是 v3 实测。默认跳过；两参数模式（实现验证口径）默认断言 —— 这就是 Rust/后续实现通过 oracle 的方式。当前 2 条：`search.contract`、`search.contract.sealed-body`。
- **旧机制 `known_defect`**（把 v3 的 500 当期望值）**已废弃**；harness 仅为兼容保留，当前 fixtures 中无人使用。

### 7.1 `GET /api/search`：v3.2.0 的缺陷，契约仍按 200

| 项 | 内容 |
|---|---|
| v3.2.0 实测 | **必然 500** `internal-error` |
| 证据 | 服务端日志 `SQLite error 1: no such column: a.category`；pass-B 的 `scanSQL` 引用 `COALESCE((… a.category …))`，但只 JOIN 了 `message_bodies`，漏了 `advice a` |
| 契约 | **200 `SearchResponse`**（§3 类型表）：`results / query / totalCount? / truncated? / bodyScanSkipped? / bodyScanLimit?`；结果上限 100，解封扫描预算 1000 |
| fixtures | `search.contract`（`q=fixture`，账号 A 命中 3 封，按 `received_at DESC, id DESC`）、`search.contract.sealed-body`（`q=sealedneedle`，只命中封存正文那一封）；header 字节取自同次抓取的 `export.index` / `messages.list.b` |
| 处理 | 不把 500 写进 oracle：Rust 实现正确版本即可让这两条转绿；若 v3 修复，两参数模式同样转绿 |

已知但未锁定（本文按实现写、无 fixture）：`forward` 的 409 `forward-too-large`（注释有、实现无）；`DELETE /api/reminders/:id` 对不存在 id 返回 204；未测 `OPTIONS`/`405`。

---

## 8. 版本与兼容规则

| 规则 | 内容 |
|---|---|
| 版本 | 本文 v0.1，与 `v4/docs/ipc-contract.md` v0.1 同步冻结 |
| 允许的向后兼容变更 | 新增**可选**响应字段（老客户端忽略即安全）；新增端点；新增错误 code（前端必须把未知 code 显示为通用错误） |
| 破坏性变更（必须升 v0.2 并同时改 fixtures） | 改已有字段名/类型/语义；改状态码含义；改错误 code 拼写；把可选字段改为必填；改变列表排序 |
| 错误 code 稳定性 | `error` 值是**机器可读标识**，不是文案；只增不改。前端不得按英文子串匹配状态码 |
| fixtures 是版本的一部分 | 任何上述变更都必须伴随 `capture-contract.sh` 重抓 + 提交 diff，否则视为未完成 |
| 契约归属 | 本文由 Lead 维护；`v4/web`、`v4/shell`、`v4/crates` 只引用不复制 |

---

## 9. fixture 覆盖矩阵（**58 条 = 56 抓取 + 2 contract_expected** / 57 端点）

| 覆盖程度 | 端点 |
|---|---|
| **有 fixture（56 条抓取，成功或错误路径）** | `healthz`、accounts 列表、messages 列表（5 个 lens + 2 个 400 + 账号 B 列表）、folder-counts、senders（空/有数据）、export/index、advice 列表（空/有数据/`decision=any`）、advice accepted-stats、stacks（空/有数据）、reminders（空/有数据/含 dismissed）、time-saved（零/非零）、actions 列表（有数据）、usage、ai-status、ai/reload、ai/probe、store-notices（1 条）、briefing、body（缓存 **200** / 无 provider 503）、inline-images(503)、raw.eml(503)、summary(503)、draft 生成(503)、drafts 列表（有数据）、sent(200+stale)、archive(409)、folder-counts(404)、read(204+200)、pin(200)、sync(204)、accounts IMAP（空体/缺字段/未知服务商/已存在）、auth 401×2、host 403、unknown-route 404×2 |
| **只有本文定义（实现前必须补 fixture）** | accounts 激活/删除、attachments 下载、send/compose/forward、draft choose、delete/unarchive/restore/purge/trash-empty、delete-bulk/archive-bulk、unsubscribe、classify、actions undo/undo-bulk、advice decision、stacks 增删改、reminders 写、store-notices ack |
| **contract_expected（v3 不通过，对实现断言）** | `GET /api/search` ×2：subject 命中、sealed-body 命中（见 §7.1） |
| **r2_skip（写路径，R2 不断言）** | `POST /api/messages/:remoteId/read`（默认 + `record=true` 两态）、`POST /api/messages/:remoteId/pin` |

> 判定口径：fixtures 覆盖的是"**形状**"（路径、状态码、content-type、错误 code、字段集合），不是"业务正确性"。业务正确性由 v3 的 53k 行测试与 M2 的逐屏对照负责；Rust/Web 只要通过 fixtures + 本文，就算契约一致。
>
> 仍存的空白：`attachments` 字节下载与 `raw.eml` 的 **200** 响应需要真实 IMAP（本仓库禁止联网抓取），fixtures 只锁它们的 503 形状；200 形状以 §3 类型表为准。`body` 的 200 已由「封存正文缓存」覆盖（`body.cached`）。
