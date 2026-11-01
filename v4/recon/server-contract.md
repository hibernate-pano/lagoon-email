# v4 契约种子：HTTP API + 存储 + 边车接口

> 证据基线：本仓 v3.2.0 工作树（2026-10-29 读取）。所有字段/状态码从实现逐行读出，行号即证据；实现里没有的写「未知」。
> 端点总数 **57** = `/api/*` 56 个 + `GET /healthz`（统计：`grep -rhoE 'router\.(get|post|put|patch|delete)' Sources/LagoonServer/Routes/`）。
> 标记：`⟂` 纯本地；`→✉` 改变远端邮箱；`⊕` 出站网络但非邮箱（SMTP/LLM/退订发布方）；`★` 改变远端状态。

## 1. 传输层约定（Web 前端必须照做）

| 项 | 契约 | 证据 |
|---|---|---|
| 监听 | 默认 `127.0.0.1:8080`；客户端依次试 8080–8090，选中端口写 `UserDefaults["lagoon.serverPort"]` | `Runtime/Runtime.swift:55-56`；`Sources/Lagoon/Services/EmbeddedServer.swift:168-199` |
| 非回环绑定 | 无 `LAGOON_API_TOKEN` 时**进程拒绝启动**（不是 403） | `Config.swift:25-35` |
| 鉴权 | 配了 token → fail-closed：除精确 `/healthz` 外全部要 `Authorization: Bearer <token>`；失败 401 `{"error":"api-unauthorized"}`；SHA-256 常量时间比较 | `Networking/APIAuth.swift:28,48-57,66-73` |
| Host 守卫 | 白名单 `127.0.0.1/localhost/::1`（配 token 时并入绑定地址；通配绑定不并入）；失败 403 `{"error":"forbidden-host"}` | `Networking/HostGuard.swift:9,74-82`；`Config.swift:37-61` |
| 中间件顺序 | Host 守卫 → 鉴权 → 路由 | `Runtime.swift:187-191` |
| Content-Type | JSON 统一 `application/json; charset=utf-8`；`GET /healthz` 为纯文本 `ok`；附件为原 MIME；`raw.eml` 为 `message/rfc822` | `Routes/RouteSupport.swift:35-39`；`HealthRoutes.swift:5-7`；`MessageRoutes.swift:1475,1515` |
| 日期 | 线上 ISO-8601（编/解各一个 strategy，禁止默认 decoder）；库里 TEXT `yyyy-MM-dd HH:mm:ss.SSS` UTC | `RouteSupport.swift:80-108`；`LagoonDatabase.swift:15-23`；`StoredDate.swift:26-32` |
| 请求体上限 | 默认 1 MB；仅 send/compose/forward 三个端点 64 MB | `RouteSupport.swift:161,174,177` |
| 无 CORS | 服务端**没有**任何 `Access-Control-*` 头或 Origin 处理 → 跨源 WebView 直连读不到响应 | 全仓 grep 无命中（§9 给绕法） |
| 客户端超时 | fast 10s / interactive 30s / slow 75s；仅 fast 自动重试一次（传输错误 + 5xx） | `Sources/Lagoon/Services/APIClient.swift:15-27,1296-1341` |

## 2. 错误封装与「不知道」语义（前端如何区分）

**错误只有一个形状**：`{"error":"<稳定 code>"}`，HTTP 状态另给；上游/模型/IMAP 原文永不回传（`RouteSupport.swift:44-52,63-78`）。5xx 带域名 label 落日志，客户端只拿 code。

| 层 | 事实 | 证据 |
|---|---|---|
| 状态码 | 400 参数/体格式；401 凭据；403 非法 Host / draft 跨账号（仅一处）；404 目标不存在；409 冲突/能力闸门；410 已被删（message-gone）/撤销过期；413 附件超限；422 退订不可完成；500 本地存储失败；502 provider/AI 失败；503 未配置 | 见 §3 各行 |
| 前端取 code | `APIError.badStatus(code, bodySnippet)` + `serverErrorCode` 从 200 字节片段解析 `error` | `APIClient.swift:41-74,1274-1287` |
| **「不知道」的表达** | HTTP 层没有"未知"状态。约定是**字段缺省即未知**，绝不用 0/false 冒充：`MailCapabilities` 门控字段是 `Bool?`（nil=未探测，false=已确认没有）；`totalCount/hasMore/bodyScanSkipped/sent` 等均可为 nil | `MailCapabilities.swift:7-30,108-118`；`FolderCounts.swift:50-54`；`Action.swift:116-128,216-242` |
| 能力闸门 | 三态读作"允许"：`allowsArchive/allowsDelete/allowsPurge/allowsSent` 只在**确定为 false** 时关闭；真正拒绝由服务端 409 给 | `MailCapabilities.swift:121-156` |
| 409 语义 | `archive-unavailable`、`delete-unavailable`、`not-in-trash`、`send-in-flight`、`already-undone` | `ActionsRoutes.swift:268,355,567,976`；`MessageRoutes.swift:1241`；`ActionsRoutes.swift:1942` |

结论：前端不能把"缺字段"当失败，也不能把"失败"当空数据。**先看 HTTP 状态，再看可选字段是否缺席**。

## 3. 端点清单（按域，字段逐字）

响应列只写顶层对象/数组元素字段；`MessageHeader` 全字段见 §3.1。

### 3.1 共享 wire 类型

| 类型 | 字段 | 证据 |
|---|---|---|
| `MessageHeader` | `id, accountId, remoteId, threadId, fromAddress, fromName?, subject?, snippet?, receivedAt, isRead, isArchived, isDeleted, isPinned, isSent, messageIdHeader?, inReplyTo?, references?`（全 camelCase；`snippet` 由服务端解封后返回） | `LagoonKit/MessageHeader.swift:3-30`；`MessageStore.swift:1288-1317` |
| `SyncResponse` | `cursor{accountId,lastFetchedAt,totalUnread}, messages[], totalCount?` | `SyncResponse.swift:4-15`；`SyncCursor.swift:5-14` |
| `ConnectedAccount` | `id, provider("qq"), email, isActive, unreadCount, syncHealth{status,lastSyncAt?,lastError?}, capabilities` | `ConnectedAccount.swift:13-20`；`SyncHealth.swift:5-41`；`MailCapabilities.swift:31-118` |
| `MessageBody` | `remoteId, subject?, fromAddress, fromName?, toAddress?, receivedAt, text, html?, attachments[], hasMore, to[], cc[]` | `Briefing.swift:124-193` |
| `Attachment` | `id, filename?, mimeType, size, contentId?, disposition("attachment"/"inline")` | `Briefing.swift:199-231` |
| `AIAction` | `id, accountId, kind, payload{string:string}, createdAt, expiresAt?`；kind ∈ archive/read/pin/unpin/unsubscribe/classify_override/draft_create/send/undo/delete/purge | `Action.swift:5-56` |

### 3.2 accounts（4）

| 方法 路径 | 入参 | 成功响应 | 错误码 | 远端 | 证据 |
|---|---|---|---|---|---|
| `GET /api/accounts` | — | 200 `[ConnectedAccount]` | 500 internal-error | ⟂ | `AccountsRoutes.swift:33-59` |
| `POST /api/accounts/imap` | body `{provider,email,authCode}` | 201 `ConnectedAccount` | 400 missing-body/missing-field；409 account-exists；401 imap-auth-failed；502 imap-unreachable；503 provider-not-configured；500 | →✉ 探活（IMAP LOGIN，不改邮箱） | `AccountsRoutes.swift:61-244` |
| `POST /api/accounts/:id/activate` | — | 204 无体 | 404 unknown-account（含 id 非 UUID）；500 | ⟂ | `AccountsRoutes.swift:250-267` |
| `DELETE /api/accounts/:id` | — | 204 | 404 unknown-account；500；FK 级联删 messages/pins/drafts/advice | ⟂ | `AccountsRoutes.swift:271-291` |

### 3.3 列表与同步（2）

| 方法 路径 | 入参 | 成功响应 | 错误码 | 证据 |
|---|---|---|---|---|
| `GET /api/messages` | query `accountId`（必）；`limit` 默认 500、上限 1000；`sender`（精确 from_address）；`archived`/`deleted`/`pinned`/`unread` = 字符串 `"true"`；`stackId`（UUID） | 200 `SyncResponse` | 400 malformed-accountId；404 unknown-stack；500 | `SyncRoutes.swift:24-108` |
| `POST /api/sync` | — | 204 | — | `SyncRoutes.swift:110-113` |

### 3.4 单封邮件 / 附件 / 发送（13）

| 方法 路径 | 入参 | 成功响应 | 错误码 | 远端 | 证据 |
|---|---|---|---|---|---|
| `GET /api/messages/:remoteId/body` | query `accountId` | 200 `MessageBody`（命中 `message_bodies` 即返缓存） | 400 malformed-accountId/malformed-remoteId；404 unknown-account；410 message-gone；401 provider-auth-failed；502 provider-unreachable；503 provider-not-configured；413 attachment-too-large；500 | →✉ 读（未缓存时） | `MessageRoutes.swift:56-98,1359-1438` |
| `GET /api/messages/:remoteId/attachments/:attachmentId` | query `accountId` | 200 二进制 + `Content-Type: <mime>`；`Content-Disposition: attachment; filename="…"; filename*=UTF-8''…`；`Content-Length` | 400；404 attachment-not-found/unknown-account；413 attachment-too-large；401；502；503 | →✉ 每次重新解析整封 | `MessageRoutes.swift:102-135,1442-1503` |
| `GET /api/messages/:remoteId/raw.eml` | query `accountId` | 200 `message/rfc822`，文件名 = subject（≤80）`+.eml` | 同 attachments（无 413） | →✉ | `MessageRoutes.swift:139-172,1505-1549` |
| `POST /api/messages/:remoteId/read` | query `accountId`；`isRead` 默认 true（true/1/yes、false/0/no）；`record` 默认 false | `record=false` → 204；`record=true` → 200 `StateChangeResponse{ok,remoteId,actionId?}` | 400 malformed-isRead；404 unknown-account；500 | →✉ `UID STORE \Seen`（best-effort，失败只记日志） | `MessageRoutes.swift:180-274` |
| `POST /api/messages/:remoteId/pin` | query `accountId`、`pinned=true|false`（必填） | 200 `StateChangeResponse` | 400 malformed-pinned；404 unknown-account；500 | ⟂（本地 pin + 审计） | `MessageRoutes.swift:277-329` |
| `GET /api/messages/:remoteId/summary` | query `accountId`；header `Accept-Language` | 200 `MessageSummary{remoteId,summary,actionItems[],provider?}` | 503 ai-not-configured/ai-credit-exhausted/ai-budget-exceeded/ai-circuit-open；502 ai-error/provider-unreachable；400；404；410；401 | ⊕ LLM | `MessageRoutes.swift:333-424` |
| `GET /api/messages/:remoteId/inline-images` | query `accountId` | 200 `{images:{"<cid 小写无尖括号>":<base64>}}`；上限 40 张 / 8 MB | 400；404 unknown-account；410；401；502；503；500 | →✉ 读一次整封 | `InlineImageRoutes.swift:65-166`；`InlineImages.swift:26-33` |
| `POST /api/messages/:remoteId/send` | body `{body, requestId?, to?[], cc?[], bcc?[], attachments?[{filename,mimeType,dataBase64}]}` | 200 `SendResponse{ok,providerMessageId?}` | 400 malformed-body/-recipient/-attachment/-request-id；404 unknown-account/unknown-message；409 send-in-flight；401 smtp-auth-failed；502 smtp-send-failed；503 provider-not-configured；410 message-gone | →✉ SMTP | `MessageRoutes.swift:426-434,1102-1346,1063-1095` |
| `POST /api/compose/send` | body `{to:String, subject, body, requestId?, cc?[], bcc?[], attachments?}` | 200 `SendResponse` | 400 malformed-compose/-recipient/-attachment/-request-id；404 unknown-account；409；401；502；503 | →✉ SMTP | `MessageRoutes.swift:436-446,461-665` |
| `POST /api/messages/:remoteId/forward` | body `{to[], body?, subject?, cc?[], bcc?[], requestId?}` | 200 `SendResponse` | 400 malformed-forward/-recipient/-request-id；404 unknown-message/unknown-account；410 message-gone；502 forward-original-unavailable；401；503（注释另称 409 forward-too-large，实现未见该分支 → **未知**） | →✉ SMTP + 读原信 | `MessageRoutes.swift:448-456,667-891` |
| `GET /api/messages/:remoteId/drafts` | query `accountId` | 200 `{drafts:[DraftReply{id,accountId,remoteId,variants[],chosenVariant?,createdAt}]}` | 500 draft-unreadable/internal-error | ⟂ | `DraftRoutes.swift:213-241`；`Action.swift:96-113` |
| `POST /api/messages/:remoteId/draft` | query `accountId`；header `Accept-Language` | 200 **裸** `DraftReply`（不是信封） | 503 ai-*；502 ai-error/provider-unreachable；500 draft-seal-failed/internal-error；404 unknown-account | ⊕ LLM | `DraftRoutes.swift:43-138` |
| `POST /api/drafts/:id/choose` | query `accountId`；body `{variant:Int}` | 200 `{ok,draftId,chosen}` | 400 malformed-draft-id/invalid-body/variant-out-of-range；403 draft-different-account；404 unknown-draft；500 draft-unreadable | ⟂ | `DraftRoutes.swift:140-211` |

### 3.5 动作 / 撤销 / 批量（14）

| 方法 路径 | 入参 | 成功响应 | 错误码 | 远端 | 证据 |
|---|---|---|---|---|---|
| `POST /api/messages/:remoteId/archive` | query `accountId` | 200 `{ok,remoteId,remote:true,actionId}` | 409 archive-unavailable；404；503；502；500 | →✉ MOVE | `ActionsRoutes.swift:244-330` |
| `POST /api/messages/:remoteId/delete` | query `accountId` | 200 同上（`remote:true`） | 409 delete-unavailable（provider 抛 trashUnavailable）；404；502；500 | →✉ 移到服务器废纸篓 | `ActionsRoutes.swift:704-787` |
| `POST /api/messages/:remoteId/unarchive` | query `accountId` | 200 同上 | 409 archive-unavailable；404；502；500 | →✉ MOVE 回 INBOX | `ActionsRoutes.swift:332-426` |
| `POST /api/messages/:remoteId/restore` | query `accountId` | 200 同上 | 409 delete-unavailable；404；502 | →✉ 从 Trash 回 INBOX | `ActionsRoutes.swift:428-517` |
| `POST /api/messages/:remoteId/purge` | query `accountId` | 200 `{ok,remoteId,purged:1}`（**无 actionId**，不可撤销） | 409 not-in-trash；404；502；500 | →✉ `UID EXPUNGE`（需 UIDPLUS） | `ActionsRoutes.swift:519-621` |
| `POST /api/trash/empty` | query `accountId` | 200 `{ok,remoteId:"",purged:N}` | 500 | →✉ 批量 EXPUNGE | `ActionsRoutes.swift:623-702` |
| `POST /api/delete-bulk` | query `accountId`；body `{remoteIds?[], allMatching?, archived?, deleted?, sent?, stackId?}` | 200 `{items:[{remoteId,ok,actionId?,errorCode?}], truncatedCount?}` | 400 empty-remoteIds/invalid-body/missing-body；404 unknown-stack/unknown-account | →✉ 每条一次远端移动 | `ActionsRoutes.swift:789-934`；`Stacks.swift:92-139,142-171` |
| `POST /api/archive-bulk` | query `accountId`；body `{remoteIds[]}` | 200 同上 | 400 empty-remoteIds/invalid-body；409 archive-unavailable；404 | →✉ | `ActionsRoutes.swift:936-992` |
| `POST /api/messages/:remoteId/unsubscribe` | query `accountId` | 200 `{ok,unsubscribed,publisher,actionId}` | 422 unsubscribe-unavailable/-manual-required/-page-required；502 unsubscribe-failed/provider-unreachable；401；500 | ⊕ 向发布方 HTTP，随后本地归档+已读 | `ActionsRoutes.swift:1196-1401` |
| `POST /api/messages/:remoteId/classify` | query `accountId`；body `{toGroup, fromGroup?, scope?}` | 200 `{ok,actionId,fromGroup,toGroup}` | 400 invalid-group/invalid-body/missing-body；404 unknown-account | ⟂（写 ai_overrides） | `ActionsRoutes.swift:1405-1595` |
| `GET /api/actions` | query `accountId`；`since`（ISO8601）；`limit` 默认 100 上限 500；`before=<actionId>` | 200 `{actions[], totalCount?, hasMore?}` | 400 malformed-accountId/malformed-before/unknown-before；500 | ⟂ | `ActionsRoutes.swift:1635-1721` |
| `POST /api/actions/:id/undo` | query `accountId` | 200 `{ok,undone:<actionId>}` | 400 not-undoable/malformed-action-id；404 unknown-account/**unknown-action**；409 already-undone；410 action-expired；500 undo-failed | 视 kind：可能 →✉ | `ActionsRoutes.swift:1725-1759,1919-1944` |
| `POST /api/actions/undo-bulk` | query `accountId`；body `{actionIds[]}`（去重、上限 500） | 200 `{items:[{actionId,ok,errorCode?}], undone:N}`；item.errorCode ∈ not-undoable/unknown-action/action-expired/already-undone/undo-failed | 400 malformed-accountId/missing-body/invalid-body/empty-actionIds；404 unknown-account；500 | 同上（逐条、串行） | `ActionsRoutes.swift:1761-1822`；`Action.swift:183-192` |

### 3.6 advice / briefing / search / stacks / reminders（13）

| 方法 路径 | 入参 | 成功响应 | 错误码 | 证据 |
|---|---|---|---|---|
| `GET /api/advice` | `accountId`；`decision`（缺省/空=pending，`any`=全部，否则 accepted/dismissed）；`limit` 默认 200 上限 500 | 200 `{advice:[{id,accountId,remoteId,advice{action,category?,confidence,rationale?,dueText?},source,model?,decision,createdAt,decidedAt?}]}` | 400 malformed-accountId/-decision；404 unknown-account；500 | `AdviceRoutes.swift:34-70`；`Advice.swift:99-105,160-275` |
| `GET /api/advice/accepted-stats` | `accountId` | 200 `{stats:[{category?,action,count}]}`（最多 5 条） | 400；404 | `AdviceRoutes.swift:72-90` |
| `POST /api/advice/:id/decision` | `accountId`；body `{decision}` | 200 `{id,decision}` | 400 malformed-adviceId/-body/-decision；404 unknown-advice/unknown-account（跨账号统一 404，不泄露存在性） | `AdviceRoutes.swift:92-129` |
| `GET /api/briefing` | `accountId`；`limit` 默认/上限 500（maxItems）；backlog 上限 50；header `Accept-Language` | 200 `{items:[{message:MessageHeader,group,reasonCode?}], omittedCount?, backlogCount?}`；group ∈ needsReply/awaitingReply/safeToArchive/subscriptionNoise/pinned；窗口 30 天 + 旧未读 backlog | 400 malformed-accountId；404 unknown-account；500 | `BriefingRoutes.swift:54-190`；`Briefing.swift:8-114` |
| `GET /api/search` | `q`（空 → 空结果 200）；`accountId` = UUID 或 `all` 或缺省；`sender`；`since` | 200 `{results[], query, totalCount?, truncated?, bodyScanSkipped?, bodyScanLimit?}`（结果上限 100；解封扫描预算 1000） | 400 malformed-accountId；500 | `DraftRoutes.swift:284-363`；`Action.swift:206-258` |
| `GET /api/stacks` | `accountId` | 200 `{stacks:[{rule:{id,accountId,name,kind,value,createdAt}, count}]}` | 400；500 | `StackRoutes.swift:16-32`；`Stacks.swift:7-21` |
| `POST /api/stacks` | `accountId`；body `{name,kind,value}`（name ≤80、value ≤200） | 201 `{stack}` | 400 malformed-accountId/missing-body/invalid-body/invalid-name/invalid-value/invalid-kind；500 | `StackRoutes.swift:35-73` |
| `PATCH /api/stacks/:id` | `accountId`；body `{name?,kind?,value?}` | 200 `{stack}` | 400 malformed-stackId/…；404 unknown-stack；500 | `StackRoutes.swift:85-147` |
| `DELETE /api/stacks/:id` | `accountId` | 200 `{ok:true}` | 400 malformed-stackId；404 unknown-stack；500 | `StackRoutes.swift:150-171` |
| `GET /api/reminders` | `accountId`；`includeDismissed=true` | 200 `{reminders:[{id,accountId,remoteId,subject?,dueAt,note?,createdAt,dismissedAt?}]}` | 400 malformed-accountId；404 unknown-account；500 | `ReminderRoutes.swift:35-60`；`Reminder.swift:19-87` |
| `POST /api/reminders` | `accountId`；body `{remoteId, dueAt(ISO-8601), note?}` | 200 裸 `Reminder` | 400 malformed-remoteId/-body/reminder-due-in-past；404 unknown-account/unknown-message；500 | `ReminderRoutes.swift:64-125` |
| `POST /api/reminders/:id/dismiss` | `accountId`；body `{dismissed?:Bool}`（空体=dismiss） | 200 裸 `Reminder` | 400 malformed-reminderId；404 unknown-reminder；500 | `ReminderRoutes.swift:129-167` |
| `DELETE /api/reminders/:id` | `accountId` | 204 | 400 malformed-reminderId；500（实现不做存在性检查 → 不存在也 204；注释声称 404，**以实现为准**） | `ReminderRoutes.swift:171-191` |

### 3.7 只读报表 / 运维（11）

| 方法 路径 | 入参 | 成功响应 | 错误码 | 证据 |
|---|---|---|---|---|
| `GET /api/senders` | `accountId`；`limit` 默认 60 上限 300；`q` 子串 | 200 `{senders:[{address,displayName?,totalCount,unreadCount,latestAt}]}` | 400；404 unknown-account；500 | `SenderRoutes.swift:40-69`；`Senders.swift:15-59` |
| `GET /api/sent` | `accountId`；`limit` 上限 1000 | 200 `{messages[], totalCount, refreshedFromServer, staleReason?}` | 400；404 unknown-account/**sent-unavailable**；503；500（provider 失败**不报错**，填 `staleReason`） | `SentRoutes.swift:45-132,181-192` |
| `GET /api/folder-counts` | `accountId` | 200 `{counts:[{id,count}]}`，id ∈ live/unread/archived/pinned/deleted/sent | 400；404；500 | `FolderCountsRoutes.swift:35-87`；`FolderCounts.swift:25-88` |
| `GET /api/time-saved` | `accountId` | 200 `{today:{minutesSaved,messagesHandled,draftsSent,unsubscribed,byDay[]}, week:{…+byDay}}` | 400；500 | `TimeSavedRoutes.swift:45-109`；`TimeSaved.swift:9-65` |
| `GET /api/usage` | — | 200 `{monthUSD,capUSD,callCount,costTrackingAvailable,accounts:[{accountEmail,monthUSD,callCount}]}` | —（breakdown 失败降级为空数组） | `DraftRoutes.swift:670-696`；`Action.swift:282-343` |
| `GET /api/ai-status` | — | 200 `{configured,creditExhausted,circuitOpen}` | — | `DraftRoutes.swift:702-709`；`Action.swift:264-273` |
| `GET /api/store-notices` | — | 200 `{notices:[{id,createdAt,detail?}]}`（读时顺带补 `body-key-lost` 通知） | 500 | `StoreNoticeRoutes.swift:33-44,86-99`；`StoreNotice.swift:22-73` |
| `POST /api/store-notices/:id/ack` | 路径 id | 200 `{ok,id}` | 400 malformed-noticeId；500 | `StoreNoticeRoutes.swift:46-60` |
| `GET /api/export/index` | `accountId` | 200 `{messages:[MessageHeader], totalCount, deletedCount, sentCount}`（**全量、无 limit**，oldest first） | 400；404；500 | `BackupRoutes.swift:37-99` |
| `POST /api/ai/reload` | body `{environment:{…}}`（非空） | 200 `{configured,creditExhausted,circuitOpen}` | 400 malformed-environment/invalid-budget-cap | `AIRoutes.swift:67-158` |
| `POST /api/ai/probe` | body `{environment}` | 200 `{outcome,httpStatus?,detail?}`（outcome ∈ reachable/unauthorized/notFound/outOfCredit/rateLimited/rejected/providerError/unexpectedResponse/timedOut/unreachable/redirected/invalidSettings/serviceError） | 400 malformed-environment | `AIRoutes.swift:160-198`；`AIProbeResult.swift:24-79` |
| `GET /healthz` | — | 200 纯文本 `ok`（唯一免鉴权路径） | — | `HealthRoutes.swift:5-7`；`APIAuth.swift:28` |

## 4. 读一封邮件要几次请求（Q1）

| 步 | 请求 | 何时发 | 证据 |
|---|---|---|---|
| 1 | `GET /api/messages/:remoteId/body` | 打开详情立即 | `MessageDetailView.swift:931-943` |
| 2 | `GET /api/messages/:remoteId/inline-images` | **仅当** body 里有 `disposition==inline` 的附件；与步骤 1 **并行**（fire-and-forget），失败时退化为逐张 `GET …/attachments/:id` | `MessageDetailView.swift:949-1000`；`InlineImageRoutes.swift:6-54` |
| 3 | `POST /api/messages/:remoteId/read`（无 body） | 停留 1s 后（`markReadDwell`），用户已走开则取消 | `MessageDetailView.swift:190-192,243-253` |

- **回答**：正常 2 次（body + read），有内联图 3 次；正文缓存命中时 body 不再走 IMAP。附件字节**不在** body 里（`attachments[]` 只有元数据），下载是单独 1 次 `GET …/attachments/:id`，且每次都会重新 fetch+parse 整封（已知成本）。
- 列表不返回正文：列表只看 `snippet`（已解封）。

## 5. 有没有 SSE / 长轮询 / WebSocket（Q2）

**没有。** 全仓无 `text/event-stream`、无 `Upgrade`、无 WebSocket、无长轮询（grep 无命中）。所有"推送"都是客户端轮询：

| 轮询点 | 周期 | 证据 |
|---|---|---|
| 列表 `GET /api/messages` | 30s | `Sources/Lagoon/Views/MessageListView.swift:400` |
| 账号目录 `GET /api/accounts` | 30s | `Sources/Lagoon/Models/DirectoryStore.swift:19` |
| 时间节省 | 60s | `Sources/Lagoon/Models/TimeSavedStore.swift:15` |
| 邮箱变更监控 | 30s | `Sources/Lagoon/Platform/MailboxMonitor.swift:53` |

服务端内部的 IMAP IDLE 只把变化写进 SQLite，**对 HTTP 不可见**（`IMAPProvider.swift:33-37,340-366`）。→ Web 前端只能轮询；要 SSE 是**新增契约**，不是复用。

## 6. 哪些端点会写远端邮箱 / 哪些纯本地（Q4）

| 类别 | 端点 | 说明 |
|---|---|---|
| →✉ 改远端邮箱 | `archive`、`delete`、`unarchive`、`restore`、`purge`、`trash/empty`、`delete-bulk`、`archive-bulk`、`read`(isRead)、`send`、`compose/send`、`forward` | 先远端成功再落本地审计（例外：`read` 本地优先、远端 best-effort） |
| →✉ 只读远端 | `body`、`inline-images`、`attachments`、`raw.eml`、`sent`、`accounts/imap`(探活)、`summary`/`draft`(先取 body) | 会把 body/`unsubscribe_links`/sent 行写进本地库 |
| ⊕ 出站网络（非邮箱） | `unsubscribe`（向发布方 HTTP）、`summary`/`draft`/`ai/reload`/`ai/probe`（LLM） | `unsubscribe` 同时本地归档+已读，**不可撤销** |
| ⟂ 纯本地 | `accounts`(GET/activate/DELETE)、`messages`、`sync`、`pin`、`classify`、`actions*`、`advice*`、`briefing`、`search`、`stacks*`、`reminders*`、`senders`、`folder-counts`、`time-saved`、`usage`、`ai-status`、`store-notices*`、`export/index`、`healthz` | 只读写 `lagoon.sqlite` |

**AI 只读宪法**：AI 从不直接调邮箱。分类/摘要/草稿全部经 HTTP 路由，AI 侧写入只有 `advice`/`ai_overrides`/`draft_replies`/`usage_log`/`ai_actions`（`AdviceRoutes.swift:7-19`；`ReminderRoutes.swift:21-25`）。

## 7. 存储契约（`LagoonKit/LagoonDatabase.swift`）

| 表 | 列（真实 DDL） | 关键语义 | 行 |
|---|---|---|---|
| `accounts` | `id BLOB PK`, `provider CHECK('gmail','qq')`, `oauth_user`, `email`, `credentials BLOB`, `sync_state TEXT`, `capabilities TEXT`, `is_active`, `sync_status`, `last_sync_at`, `last_sync_error`, `created_at`, `updated_at`, `UNIQUE(provider,oauth_user)` | 凭据 = AES-GCM `combined` 裸 blob；`sync_state` JSON 含 cursor/archiveFolder；`capabilities` JSON | 526-545 |
| `message_headers` | `id BLOB PK`, `account_id FK→accounts CASCADE`, `remote_id`, `thread_id`, `from_address`, `from_name`, `subject`, `snippet_cipher`（v6 前名 `snippet`）, `received_at TEXT`, `is_read`, `is_archived`, `fetched_at`, `list_unsubscribe`, `message_id_header`, `in_reply_to`, `references_header`, `unsubscribe_links TEXT '[]'`, `is_deleted`, `is_sent`（v5 加）, `UNIQUE(account_id,remote_id)` | 列表/计数/搜索唯一来源；`snippet` 加密、读时解封 | 547-593,415-420 |
| `message_bodies` | `account_id`, `remote_id`, `body_cipher`, `body_html_cipher`, `has_more`, `attachments TEXT`, `to_addresses TEXT`, `cc_addresses TEXT`, `fetched_at`, `PK(account_id,remote_id)`, `FK→message_headers CASCADE` | 正文缓存；**无 header 行就不可缓存**（headerMissing） | 664-678；`MessageRoutes.swift:1395-1403` |
| `message_pins` | `account_id FK CASCADE`, `remote_id`, `created_at`, `PK(account_id,remote_id)` | 置顶独立表；列表 LEFT JOIN 出 `is_pinned` | 595-600 |
| `ai_actions` | `id INTEGER PK AI`, `account_id FK CASCADE`, `kind`, `payload TEXT`, `created_at`, `expires_at`（默认 +30 天） | 审计+撤销源；send 幂等唯一索引 `(account_id, json_extract(payload,'$.requestId'))`；undo 用 `$.undoOf` | 616-639 |
| `usage_log` | `id`, `year_month`, `account_email`, `capability`, `model`, `prompt_tokens`, `completion_tokens`, `cost_micro_usd`, `created_at` | 成本唯一账本；按月保留 | 602-614 |
| `draft_replies` | `id`, `account_id FK CASCADE`, `remote_id`, `variants TEXT`（整数组一个信封）, `chosen_variant`, `created_at` | 无 UNIQUE，同一邮件可多行 | 641-651 |
| `ai_overrides` | `id`, `account_id FK CASCADE`, `remote_id`, `from_group`, `to_group`, `created_at`, `scope`（v8，默认 sender）, `from_address`（v10） | 分组覆盖；scope=message/sender | 653-662,327-358 |
| `advice` | `id`, `account_id FK CASCADE`, `remote_id`, `action`, `category`, `confidence`, `rationale`, `due_text`, `source`, `model`, `decision`, `created_at`, `decided_at`, `UNIQUE(account_id,remote_id)`, `FK(account_id,remote_id)→message_headers CASCADE` | 每封一条，upsert | 695-717 |
| `reminders` | `id`, `account_id FK CASCADE`, `remote_id`, `due_at`, `note`, `created_at`, `dismissed_at`, `UNIQUE(account_id,remote_id)`, 复合 FK→message_headers CASCADE | 指向邮件；随邮件删除级联 | 722-737 |
| `stack_rules` | `id BLOB PK`, `account_id FK CASCADE`, `name`, `kind CHECK('sender','keyword')`, `value`, `created_at` | 归集规则，读时求值 | 680-689 |
| `store_notices` | `id TEXT PK`, `detail`, `created_at` | 一次性通知（drafts-dropped-no-key / body-key-lost） | 743-747 |

| 维度 | 约定 | 证据 |
|---|---|---|
| 迁移链（注册顺序） | v1 schema → v2 索引 → v3 删表 → v4 advice → v5 is_sent → **v5b accountID 修复** → v6 正文封存（rename+seal）→ v7 reminders → v8 override.scope → v9 草稿封存+store_notices → v10 override.from_address；没有单一「版本号」常量，版本 = 最后一条迁移 id | `LagoonDatabase.swift:236-306,28-234` |
| 日期 | TEXT `yyyy-MM-dd HH:mm:ss.SSS`，UTC，en_US_POSIX；SQL 侧 `strftime('%Y-%m-%d %H:%M:%f','now')` 同格式 | 同上 15-23；`StoredDate.swift:26-32` |
| Bool / UUID | Bool=INTEGER 1/0；UUID=16 字节 BLOB（GRDB 默认） | 同上 21-23 |
| 封存列 | `message_bodies.body_cipher`、`body_html_cipher`、`message_headers.snippet_cipher`、`draft_replies.variants`（信封 `lgb1:`+base64(nonce‖ct‖tag)，AES-256-GCM）；`accounts.credentials` 为裸 `combined` blob | `BodyCipher.swift:42-97`；`DraftCipher.swift:42-57`；`AccessTokenCipher.swift:14` |
| 明文列（故意不封） | 发件人、主题、收件时间、附件名、to/cc 列表、审计 payload | `BodyCipher.swift:20-40` |
| 自定义 SQL 函数 | 每连接注册 `lagoon_cipher_contains` / `lagoon_cipher_seal`（搜索/迁移用） | `LagoonDatabase.swift:505-516` |
| FK | `foreignKeysEnabled = true`；删账号级联清 headers/pins/drafts/advice/reminders/actions；删 header 级联清 body/advice/reminder | 502-504；`AccountsRoutes.swift:269-270` |

## 8. 服务端内部：同步 / 能力 / AI（含迁 Rust 判断）

| 模块 | LOC | 事实 | 迁 Rust 风险 |
|---|---|---|---|
| `IMAP/*` | 4135 | 自写 IMAP over NIO SSL：capability/login/select/UID FETCH/SEARCH/STORE/MOVE/COPY/EXPUNGE；IDLE 预算 290s，无 IDLE 时 30s 轮询；GBK/GB18030 解码分支；MIME 递归解析，text 200KB / html 5MB 截断 | **最高**：QQ 特有（GBK 回退、Sent/Trash/Archive 角色发现、UIDPLUS 撤销语义）+ 手写 framing |
| `Mail/*` | 1713 | `MailProvider` 协议 = 唯一后端缝；`MailSyncReading` 是只读子集（同步引擎**类型上**拿不到写方法）；`MailProviderPool` 按账号池化 long-lived provider（QQ 并发会话有上限） | 中：可 1:1 映射 Rust trait；池化与连接上限要保留 |
| `Sync/SyncEngine` | 557 | 每账号一个 actor 循环；`waitBudget` 300s；失败指数退避 `min(300, 2^(n-1))` ±20% jitter，连续 3 次降 `degraded`；authFailed/notConfigured → `needsReconnect` 并 park；`accountMissing` 单独状态；每轮重读 accounts 行；顺带 reconcileInbox + sent 回信信号 | 中低：状态机可照抄；难点是 GRDB 事务语义 |
| `Storage/*` | 4199 | 全部裸 SQL + `LagoonDB.write/read`；无 ORM 抽象（GRDB 只做行解码） | 中：SQL 可移植，但 strftime、JSON1 json_extract、复合 FK 需在 rusqlite 逐条对齐；封存/解封必须同算法 |
| `AI/*`（server） | 931 | `UsageBudget` actor（cap 来自 `LAGOON_BUDGET_USD_PER_MONTH`，micro-USD 精确）；分类缓存+串行队列（后台模式）；分组解析器；启发式分类器 | 低 |
| `LagoonAI/*` | 1270 | OpenAI 兼容 HTTP 网关 + provider 注册表 + 熔断/信用/预算错误码（`insufficient-credit`/`budget-exceeded`/`circuit-open`） | 低（reqwest 直译） |
| `Networking/*` | 587 | NIO SSL 传输 + 两个中间件 | 低（axum middleware） |
| `Routes/*` | 7548 | API 表面本身；`ActionsRoutes` 2145 / `MessageRoutes` 1613 是主要重量 | 中：逐端点翻译，§2 的 code 必须逐字一致 |
| `Runtime`/`Config` | 387 | 单进程内嵌：开池 → 造 SyncEngine → 注册路由 → 起 ServiceGroup → **同处启动同步** | 关键：边车与 HTTP 不可分离（见 §9） |

补充事实：能力每轮同步协商一次并写回 accounts（`SyncEngine.swift:154-182`）；分类只在未分类/读态变化时请求模型（`BriefingRoutes.swift:175-190`）；时间节省完全由 `ai_actions` 推导，无计数器（`TimeSavedRoutes.swift:31-109`）。

## 9. 连接池与边车模式（Q5）+ v4 集成硬事实

**同一个池。** `LagoonRuntime.start` 只打开一次 `LagoonDatabase.open`，得到 `LagoonDB`，同一实例交给 `SyncEngine` 和全部路由（`Runtime.swift:144-157,193-281`）；WAL 池多读单写（`LagoonDatabase.swift:10-13`；`LagoonDB.swift:1-48`）。同步注释明确"所有 loop 共享一个 LagoonDB"（`SyncEngine.swift:406-409`）。

| 边车风险 | 事实 | 结论 |
|---|---|---|
| 双进程同库 | v3 宿主 App 与边车同时运行 → 两个进程各开 WAL 写 + 两套 IMAP 会话与迁移 | **必须单写者**；v4 启动前探活 v3（与 `00-理解与方案.md` §6.1 一致） |
| 迁移主权 | 边车启动即跑 GRDB 迁移（含 `foreign_key_check`，失败则**打不开库**） | M1–M2 只让 v3/边车迁移；Rust 只读 schema，未知版本 fail-closed |
| 自定义 SQL 函数 | 搜索依赖 `lagoon_cipher_contains`（每连接注册） | Rust 若直连库必须自行注册等价函数，否则搜索行为不同 |
| 同步不可关 | `LagoonRuntime.start` 无条件 `syncEngine.start()`（`Runtime.swift:300`），无 HTTP-only 模式 | 边车 = 唯一同步者；Rust 在 M3 前**不要**自带同步 |
| 端口回传 | CLI 用 `LAGOON_SERVER_PORT`（默认 8080）；`RunningLagoonServer.port` 返回**配置值**，传 0 就回报 0（`Runtime.swift:283-309`） | 方案里的"端口 0 + stdout 握手"**当前不可用**：需给 CLI 打补丁读真实绑定端口，或改用固定高端口 |
| stdout 日志 | 启动打 `starting host=… port=… db=…`（swift-log 默认 stdout） | 可作弱握手信号，但 port 同上不可信 |
| 密钥传递 | CLI 只认 `LAGOON_TOKEN_KEY`/`LAGOON_BODY_KEY` 环境变量（`Sources/LagoonServerCLI` 头部） | 与 §6.3"不用 env 传密钥"冲突 → M1 需补丁（stdin/0600 文件）或接受同用户 `ps -E` 可读 |
| 退出 | CLI 的 SIGINT/SIGTERM 直接 `exit(0)`，无优雅关闭 | SQLite WAL 崩溃安全；IMAP 会话不会主动 QUIT（依赖服务端超时） |
| **CORS** | 服务端无任何 CORS/Origin 处理 | WKWebView 里 `fetch("http://127.0.0.1:8080")` 跨源**读不到响应**；必须走 Tauri 的 Rust 侧 HTTP（tauri-plugin-http / 自定义 command 代理）或给 Swift 加 CORS（=改 v1，需决策） |
| 鉴权前提 | 有 token 才启用 Bearer；`APIClient` 从 `LAGOON_API_TOKEN` 或 `UserDefaults["lagoon.apiToken"]` 取（`APIClient.swift:86-99`） | Web 侧需自存 token 并注入 header；v3 Keychain 的 `lagoon.apiTokenSecret` 与之对应 |

## 10. 附录

### 10.1 Rust 移植顺序（按依赖，风险等级）

| 序 | 模块 | 风险 | 说明 |
|---|---|---|---|
| 1 | `storage`（12 表 + 只读迁移 + 封存/解封） | 中 | 先做"只读同一个 v3 库"，用 §7 做 golden |
| 2 | `api`（axum 复刻 §3，先只读 ~26 条） | 中 | code 必须逐字；状态码表先固化成测试 |
| 3 | `ai`（网关/预算/usage_log） | 低 | OpenAI 兼容，直译 |
| 4 | `mail`（IMAP/SMTP/MIME + GBK） | **高** | QQ 特有行为最多；用 v3 的 IMAP 测试当 oracle |
| 5 | `sync`（循环/退避/reconcile） | 中 | 状态机照抄；IMAP IDLE 语义要对齐 |
| 6 | 写路径（actions/undo/bulk/send） | 中高 | 审计行与撤销逆操作必须与 v3 同形 |

### 10.2 可当契约 oracle 的现有测试

- **路由总纲**：`Tests/LagoonServerTests/RouteTests.swift`（3726 行，覆盖端点最多）
- 端点级：`DeleteBulkTests`、`SentListingTests`、`PurgeRoutesTests`、`RestoreRoutesTests`、`TrashListingTests`、`AttachmentDownloadTests`、`InlineImageRouteTests`、`BackupRouteTests`、`FolderCountsRouteTests`、`SenderRouteTests`、`StackUpdateRouteTests`、`StackCountConsistencyTests`、`ReminderStoreTests`、`AdviceRouteTests`、`AcceptedAdviceStatsTests`、`BriefingWindowTests`、`BriefingBacklogTests`、`SearchResultCountTests`、`SearchDecryptBudgetTests`、`CrossAccountSearchTests`、`ActionHistoryPagingTests`、`FilterConvergenceTests`、`ComposeAttachmentsTests`、`ForwardTests`、`SendIntegrityTests`、`DraftSealTests`、`BodyEncryptionTests`、`BodyStoreTests`、`BodyKeyGuardTests`、`TimeSavedRouteTests`
- 传输/鉴权：`APIAuthTests`、`HostGuardTests`、`ServerConfigTests`、`CapabilityRoleTests`
- 协议层：`IMAPProviderTests`、`IMAPClientTests`、`IMAPFramingTests`、`IMAPConnectionTests`、`IMAPResponseParserTests`、`MIMEParserTests`、`MIMEBuilderTests`、`MIMEAddressListTests`、`SMTPClientTests`、`SMTPDeliveryTests`、`FromHeaderTests`
- 同步/存储：`SyncEngineTests`、`SchemaMigrationTests`、`AccountIDRepairTests`、`AdvisoryOnlySyncTests`、`MailProviderPoolTests`
- 客户端契约（Web 端可复用断言）：`Tests/LagoonTests/APIClientTests.swift`、`InlineImageWiringTests`、`ErrorCenterTests`

### 10.3 本文未覆盖 / 未验证（写「未知」，不猜）

- `MailProviderPool` 的具体上限数值、QQ 并发会话上限实测值：**未知**（`MailProviderFactory.swift` 只注释"QQ caps concurrent sessions"）。
- `forward` 的 409 `forward-too-large` 分支：注释声称，实现未见 → **未知**。
- `trash/empty` 的远端批量 EXPUNGE 命令序列：未逐行核（`ActionsRoutes.swift:623-702` 只核了响应与本地删除）。
- 前端「六态」文案映射：属 `client-surface.md` 范围，本文只给数据侧的三态/缺省语义。
