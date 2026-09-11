# Lagoon · 国内邮箱接入设计（IMAP / QQ 邮箱 v1）

> 日期：2026-09-11 · 状态：Approved（设计已逐节确认）· 前置文档：`2026-09-09-lagoon-email-design.md`
>
> 上游 spec §6.4 已预留 “IMAP fallback. IDLE where supported, polling (60s adaptive) otherwise”，
> §6.2 架构图已含 “IMAP Sync” 模块。本文是把它落成可实施设计的文档。

---

## 0. 背景与目标

**动机.** 创始人主用网络在国内，Gmail 全链路需要代理；日常主力邮箱是 QQ 邮箱（个人）。
要让 Lagoon 成为“每天真的会用”的产品，必须先让它接入**国内可直连**的邮箱。

**实测结论（已探活，未登录）.**

| 服务器 | 实测能力 | 网络可达性 |
|--------|----------|------------|
| `imap.qq.com:993` | `IMAP4rev1 XLIST MOVE IDLE XAPPLEPUSHSERVICE SASL-IR AUTH=PLAIN/LOGIN/XOAUTH2 NAMESPACE CHILDREN ID UIDPLUS` | 国内直连 ✅ |
| `smtp.qq.com:465` | ESMTP（implicit TLS） | 国内直连 ✅ |
| `imap.163.com:993` | 有 ID / SPECIAL-USE / UIDPLUS，无 IDLE / MOVE，且登录前需 `ID` 命令 | 直连 ✅（后置接入） |
| 阿里云邮箱 / exmail | 有 IDLE + UIDPLUS；exmail 登录前能力极简 | 直连 ✅（后置接入） |

**目标（v1）.** QQ 邮箱完整闭环：授权码接入 → 同步收件箱 → 阅读正文 → Briefing 五分堆 → AI 摘要
→ SMTP 回复发送 → 归档 + 撤销。Gmail 代码路径保留、可切换（单活跃账号）。

**非目标（v1 明确不做）.**

- Gmail-over-IMAP（Gmail 继续走 REST + 代理）；163 / exmail / 阿里云 preset（协议就绪，接入是后续增量）
- 附件解析与下载、HTML 原样渲染（正文继续转纯文本）、IMAP 服务端草稿箱（Draft 仍是本地 AI 变体）
- IMAP/SMTP 走代理（QQ 直连；`LAGOON_HTTP_PROXY` 只作用于 Gmail REST 出站，本文不改）
- 多账号同时同步（见 §2.5 单活跃账号）、API 鉴权、连接池（仍是既有技术债）

---

## 1. 架构与模块边界

### 1.1 现状诊断：为什么这次改动的成本是有界的

代码盘点结论：**Lagoon 是 “Gmail 形状” 但不是 “Gmail 接线”**。
存储（`message_headers`）、Briefing 五分堆、搜索、撤销（`ai_actions` 30 天）、AI Gateway 全部与 provider 无关；
Gmail 硬编码只集中在三处：

1. **摄入路径**：`GmailPoller` + `GmailClient`（30s 轮询、`labelIds`→`isRead`、`List-Unsubscribe` 探测）
2. **远端写动词**：archive = `users.messages.modify` 去 `INBOX` 标签；send = `users.messages.send`（已实现但无路由调用）
3. **命名**：`gmail_id`（4 张表）/ `:gmailId`（路由参数）/ `gmailId`（JSON 与 `ai_actions.payload` 键）

因此方案是：**抽一根接缝（`MailProvider`），把 Gmail 改成它的一个实现，再新增 IMAP 实现**。
其余模块（Briefing / AI / Undo / Search）零改动——除命名重命名外。

### 1.2 接缝：`MailProvider` 协议

放在 `Sources/LagoonServer/Mail/MailProvider.swift`。风格对齐既有 `BriefingClassifying` / `LLMProvider`
（`Sendable`、协议 + 能力查询、无厂商标识泄漏到调用方）。

```swift
public protocol MailProvider: Sendable {
    var kind: MailProviderKind { get }                 // .gmail | .qq

    /// 运行时能力协商：IMAP 需登录 + LIST 文件夹后才知道（163 无 MOVE 等）。
    func capabilities() async -> MailCapabilities

    /// 统一“等待变化”原语：有新变化立即返回；否则最多阻塞 waitUpTo。
    /// Gmail 实现内部按 30s 轮询直到 waitUpTo；IMAP 实现用 IDLE（无 IDLE 则退化为轮询）。
    func pullChanges(after cursor: MailSyncState, waitUpTo: Duration) async throws -> MailChangeSet

    func fetchBody(remoteId: String) async throws -> String          // 纯文本
    func fetchRawHeaderValues(remoteId: String) async throws -> [String: String]

    func setRead(remoteId: String, isRead: Bool) async throws
    func archive(remoteId: String) async throws                     // 归档
    func unarchive(remoteId: String) async throws                   // 撤销：移回收件箱
    func send(_ outbound: OutboundMessage) async throws -> String   // 返回 provider 侧消息 id（尽力）
    func probe() async throws                                       // 接入时的一次 连+登+能力 检查
}

public struct MailCapabilities: Codable, Sendable {
    public var archiveFolder: Bool      // 归档文件夹可用（QQ 无 \Archive 时会尝试 CREATE，失败则 false）
    public var idle: Bool
    public var move: Bool               // 无 MOVE 时用 COPY+STORE+EXPUNGE 回退
    public var serverSnippet: Bool      // 支持 BODY.PEEK[TEXT]<0.256> 部分取
}

public struct MailChangeSet: Sendable {
    public var upserts: [RemoteHeader]     // 新增或 flags 变化的邮件（含 isRead）
    public var resetRequired: Bool         // UIDVALIDITY 变化 / Gmail 全量重建
    public var cursor: MailSyncState       // 仅在 upserts 成功落库后持久化
}

public struct RemoteHeader: Sendable {
    public var remoteId: String            // Gmail message id / IMAP UID（十进制字符串）
    public var threadId: String            // Gmail threadId；IMAP 取 References 首项或自身 Message-ID
    public var fromAddress, fromName: String
    public var subject: String?, snippet: String?
    public var receivedAt: Date
    public var isRead: Bool
    public var listUnsubscribe: Bool
    public var messageIdHeader, inReplyTo, references: String?   // 为线程化/回复链保存
}
```

**关键设计决定.**

- `pullChanges(after:waitUpTo:)` 把 “IDLE 推送” 与 “Gmail 轮询” 统一成同一语义：**阻塞式等待变化**。
  SyncEngine 不关心底层是推送还是轮询，只做 `while !cancelled { changes = try await provider.pullChanges(...); apply(changes) }`。
- `capabilities()` 是**运行时**的：能力在登录 + `LIST` 之后才确定，不按 provider 名硬编码（163 的 `ID` 前置要求这类怪癖
  由 IMAP 层内建处理，不上浮到业务）。
- `unarchive` 与 `archive` 对称，撤销语义因此对两种 provider 都成立。

### 1.3 目录与文件（新增 / 改动）

```
Sources/LagoonServer/
├── Mail/
│   ├── MailProvider.swift            # 协议 + MailCapabilities + MailChangeSet + RemoteHeader + MailError
│   ├── MailProviderKind.swift        # .gmail | .qq（枚举 + preset 引用）
│   ├── ProviderPresets.swift         # qq: {imap imap.qq.com:993, smtp smtp.qq.com:465}；后续 163 等在此加一行
│   └── MailProviderFactory.swift     # Account → MailProvider（注入 cipher / logger / 连接登记）
├── IMAP/
│   ├── IMAPTransport.swift           # 协议：TLS 字节流收发（可替换 stub，镜像 URLProtocolStub 模式）
│   ├── IMAPConnection.swift          # NIO actor：socket + TLS(993) + 行/字面量分帧 + 命令串行化 + 超时
│   ├── IMAPResponseParser.swift      # tagged/untagged/literal{N} 解析 → 结构化响应
│   ├── IMAPClient.swift              # 语义操作：LOGIN / ID / LIST / SELECT / UID FETCH / IDLE / MOVE / CREATE
│   ├── IMAPProvider.swift            # MailProvider 实现（读路径 + 写动词 + capability 探测 + 文件夹角色解析）
│   ├── MIMEParser.swift              # 自研子集：RFC2047 头、multipart、base64/QP、GB 系字符集
│   └── SMTPClient.swift              # 465 implicit TLS：EHLO/AUTH PLAIN/MAIL/RCPT/DATA/QUIT
├── Sync/
│   └── SyncEngine.swift              # 活跃账号唯一同步循环：pullChanges → 落库 → 健康/退避/UIDVALIDITY 重建
├── Gmail/
│   ├── GmailProvider.swift           # 新增：把 GmailClient/GmailTokenService 包成 MailProvider
│   └── GmailPoller.swift             # 删除（逻辑并入 GmailProvider.pullChanges）
├── Routes/
│   ├── AccountsRoutes.swift          # 增：POST /api/accounts/imap、activate、DELETE；GET 增健康/能力/isActive
│   ├── MessageRoutes.swift           # 增：POST /api/messages/{remoteId}/send；参数改名
│   └── ComposerRoutes?               # 不新增文件：send 放 MessageRoutes
Sources/LagoonKit/
│   ├── Account.swift                 # credentials(Data?) / syncState / isActive / lastSyncAt / lastSyncError / capabilities
│   ├── MessageHeader.swift           # gmailId → remoteId；新增 messageIdHeader/inReplyTo/references
│   └── Migrations/008_imap_providers.sql
Sources/Lagoon/ (客户端)
│   ├── Views/ConnectView.swift       # 替代 ConnectGmailView：provider 分段（Gmail / QQ）+ 各自表单
│   ├── Views/ComposerSheet.swift     # 回复编辑器：正文 + ⌘↩ 发送 + 错误就地显示
│   ├── Views/MessageDetailView.swift # 增“回复”按钮；归档按钮按 capability 禁用
│   ├── Views/RootView.swift          # 工具栏账号菜单：切换活跃账号 / 状态点 / 断开
│   └── Services/APIClient.swift      # 新端点 + 改名
```

### 1.4 里程碑切分（本文档对应 “M1.5”）

| 阶段 | 内容 | 可独立验收 |
|------|------|-----------|
| M1.5a 身份重构 | 迁移 008 + `remoteId` 全量改名 + `MailProvider` 接缝 + GmailProvider 抽取 | 既有 164 测试全绿，Gmail 行为不变 |
| M1.5b QQ 读路径 | IMAP 客户端 + MIME + SyncEngine + 接入 API/表单 + 同步健康 | QQ 收件箱可同步、可读正文、Briefing 五分堆可用 |
| M1.5c 写路径 | SMTP 发送 + Composer + 归档（MOVE）+ 撤销 | 完整 10 秒闭环 |
| M1.5d 实测浸泡 | 冒烟清单 + 14 天自用（spec §8） | 见 §5.4 |

---

## 2. 数据模型与迁移

### 2.1 迁移 `008_imap_providers.sql`

**运行前必做**：`pg_dump` 备份（`docker exec lagoon-postgres pg_dump -U lagoon lagoon > backup-pre-008.sql`）。
本迁移包含破坏性变更（见 §2.6）。

```sql
-- 1) accounts：provider 域扩展 + 凭据泛化 + 同步状态/健康/活跃位
ALTER TABLE accounts DROP CONSTRAINT IF EXISTS accounts_provider_check;
ALTER TABLE accounts ADD CONSTRAINT accounts_provider_check CHECK (provider IN ('gmail','qq'));

ALTER TABLE accounts
    ADD COLUMN IF NOT EXISTS credentials   BYTEA,                       -- AES-GCM 密封的 JSON blob
    ADD COLUMN IF NOT EXISTS sync_state    JSONB NOT NULL DEFAULT '{}'::jsonb,
    ADD COLUMN IF NOT EXISTS capabilities  JSONB NOT NULL DEFAULT '{}'::jsonb,
    ADD COLUMN IF NOT EXISTS is_active     BOOLEAN NOT NULL DEFAULT TRUE,
    ADD COLUMN IF NOT EXISTS last_sync_at  TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS last_sync_error TEXT;

-- 2) 身份泛化：gmail_id → remote_id（PG 的 RENAME COLUMN 自动更新索引与约束）
ALTER TABLE message_headers RENAME COLUMN gmail_id TO remote_id;
ALTER TABLE message_pins    RENAME COLUMN gmail_id TO remote_id;
ALTER TABLE draft_replies   RENAME COLUMN gmail_id TO remote_id;
ALTER TABLE ai_overrides    RENAME COLUMN gmail_id TO remote_id;
ALTER INDEX IF EXISTS draft_replies_gmail_id_idx RENAME TO draft_replies_remote_id_idx;
ALTER INDEX IF EXISTS ai_overrides_gmail_id_idx  RENAME TO ai_overrides_remote_id_idx;

-- 3) 线程化头（Reply 链，IMAP 侧没有 threads API，必须自存）
ALTER TABLE message_headers
    ADD COLUMN IF NOT EXISTS message_id_header TEXT,
    ADD COLUMN IF NOT EXISTS in_reply_to       TEXT,
    ADD COLUMN IF NOT EXISTS references_header TEXT;

-- 4) ai_actions.payload 键改名（撤销回放读这个键）
UPDATE ai_actions
   SET payload = (payload - 'gmailId') || jsonb_build_object('remoteId', payload->'gmailId')
 WHERE payload ? 'gmailId';

-- 5) 旧凭据列删除（见 §2.6 破坏性声明）
ALTER TABLE accounts
    DROP COLUMN IF EXISTS access_token,
    DROP COLUMN IF EXISTS refresh_token,
    DROP COLUMN IF EXISTS token_expires_at,
    DROP COLUMN IF EXISTS history_id;
```

**为何 `capabilities` 落库**：归档可用性（QQ 可能无 `\Archive`）要在客户端禁用按钮，
属于“接入时确定、长期稳定”的账号属性；存 JSONB 避免为每个能力开列。

### 2.2 身份：`remote_id` 的语义

| Provider | `remote_id` | `thread_id` | `sync_state` |
|----------|-------------|-------------|--------------|
| Gmail | `messages.id`（不变） | `threadId`（不变） | `{"historyId": "…"}`（沿用现有 `historyId` 语义） |
| IMAP/QQ | UID 的十进制字符串（`UID` 保证会话间稳定，`UIDVALIDITY` 界定其有效域） | `References` 首项 → 无则自身 `Message-ID` → 再无则 `"uid:"+remoteId` | `{"uidValidity": 42, "lastUid": 12345, "inboxUidNext": 12346, "archiveFolder": "…"}` |

命名统一为 **`remoteId`**：DB 列 `remote_id`、Swift 字段 `remoteId`、JSON 键 `remoteId`、
路由参数 `:remoteId`、`ai_actions.payload["remoteId"]`。**代码中不再出现 `gmailId` 标识符**。

### 2.3 凭据：加密 JSON blob

`accounts.credentials` = 同一个 `AccessTokenCipher`（AES-GCM，`LAGOON_TOKEN_KEY`）密封的 JSON：

```jsonc
// gmail
{"kind":"gmail","accessToken":"…","refreshToken":"…","expiresAt":"2026-09-11T08:00:00Z"}
// qq
{"kind":"imap","username":"123456@qq.com","authCode":"abcdefghijklmnop"}
```

- 读写集中在 `AccountStore`；`GET /api/accounts` 永不回显 credentials 内容（只回 email/provider/状态）。
- 授权码/令牌**永不进日志**（见 §5.2）；`probe()` 失败只报错误类别，不报凭据。
- IMAP 授权码不过期、无刷新语义；Gmail 的主动刷新逻辑（≤60s 提前 + 401 重试一次）原样保留在 `GmailTokenService`，
  刷新成功后重写 blob。

### 2.4 `SyncEngine` 与 `sync_state` 的持久化契约

- 落库成功**之后**才写 `sync_state`（游标只前进不回退；重复拉取因 upsert 幂等而无害）。
- `UIDVALIDITY` 变化 → 事务内：`DELETE FROM message_headers WHERE account_id=$1` → 重置 `sync_state` → 全量重同步。
  **已声明的代价**：本地已读态与置顶在重建后失效（pin 按 remote_id 关联，UID 变了会悬空）。
  v1 接受，日志显式记录 `sync.uidValidityReset`，不做迁移映射。
- `message_pins` 悬空行清理：重建时同事务删除该账号 pins（v1 简化，文档化）。

### 2.5 单活跃账号（`is_active`）

- 语义：**同一时间只有一个账号被同步、被客户端展示**；其余账号保留数据但不同步。
- 不变式：任何时刻 `SELECT count(*) FROM accounts WHERE is_active` ≤ 1。写入路径：
  - 接入新账号（QQ / Gmail 回调落库）→ 同事务 `UPDATE accounts SET is_active = (id = $1)`。
  - `POST /api/accounts/{id}/activate` → 同上；随后 SyncEngine 收到切换信号（见 §3.4）。
- 启动时若发现 0 个活跃账号 → 取最近 `updated_at` 的一个置活；>1 个 → 保留 `updated_at` 最新者。
- 客户端账号菜单显示全部账号：活跃者打勾，状态点（🟢 ok / 🟡 degraded / 🔴 needsReconnect）。

### 2.6 破坏性变更声明（必须写进 `docs/使用说明.md`）

**旧 Gmail 账号的存量 token 无法自动迁移**（密文→新 blob 的结构转换需要解密再密封，迁移脚本不做密文处理，
避免把密钥逻辑复制进 SQL）。因此 008 之后：**已有 Gmail 账号会显示为 `needsReconnect`，点“重新连接”即可恢复**
（QQ 为主力后这条基本不痛）。迁移前有 `pg_dump` 兜底；`DELETE /api/accounts/{id}`（新增）用于清理不再需要的账号行。

---

## 3. 同步引擎与连接管理

### 3.1 连接生命周期（7 步）

`IMAPConnection`（NIO actor，每账号一条 TCP+TLS 连接，**所有命令串行**——QQ 对并发登录敏感，
串行化 + 单连接是刻意选择；不用 pipelining）：

1. `connect(host, 993)` → NIOSSL 握手（**full verification + hostname check**，不提供降级开关）
2. 读 greeting（`* OK`），否则 `MailError.greeting`
3. `CAPABILITY`
4. 认证：`AUTHENTICATE PLAIN`（SASL-IR；`base64(\0username\0authCode)`）；失败回退 `LOGIN`（`AUTH=LOGIN` 已实测可用）
5. 认证后重读 `CAPABILITY`；若含 `ID` 则发 `ID ("name" "Lagoon" "version" "…")`（163 这类服务器因此受益，QQ 无害）
6. `LIST "" "*"` → 解析文件夹与角色（`\Archive` / `\Sent` / `\Trash` / `\Drafts`，无 SPECIAL-USE 时按名称兜底匹配 `Archive/归档`）
7. `SELECT "INBOX"` → 记录 `UIDVALIDITY` / `UIDNEXT` / `EXISTS`

超时：连接 10s、命令 30s、IDLE 290s（协议上限 30min 内主动 `DONE` 重入）。
空转保活：IDLE 不可用时每 5 min `NOOP`。

### 3.2 增量同步算法（UIDNEXT 游标）

每轮 `pullChanges`：

1. `SELECT "INBOX"`（刷新 `UIDNEXT`/`EXISTS`）→ 若 `UIDVALIDITY` ≠ 存值 → 返回 `resetRequired: true`
2. 新邮件头：`UID FETCH <lastUid+1>:* (UID FLAGS INTERNALDATE BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE MESSAGE-ID IN-REPLY-TO REFERENCES LIST-UNSUBSCRIBE)])`
   - **`BODY.PEEK` 恒定**：同步过程绝不置 `\Seen`
   - `RFC2047` 解码（GBK/UTF-8 等）→ `from/subject`；`INTERNALDATE` → `receivedAt`
3. 已读态回扫：`UID FETCH <max(1,lastUid-199)>:<lastUid> (UID FLAGS)` → 比对 `\Seen` 差异并入 `upserts`
   （每轮 200 个 UID 的 flags，实测成本可忽略；常量集中在 `IMAPProvider` 顶部便于调参）
4. `snippet`：对**新增**邮件尽力 `BODY.PEEK[TEXT]<0.256>`；返回是 base64/QP 编码体则放弃（snippet 置空，不报错）
5. 无新变化 → 进入等待（§3.3）；有变化 → 返回 `MailChangeSet`，SyncEngine 事务落库后持久化游标

### 3.3 `pullChanges` 的等待语义（IDLE / 轮询统一）

- **有 IDLE**：发 `IDLE`，等待 untagged `EXISTS` / `FETCH` / `EXPUNGE`（QQ 的 IDLE 会推送 flags 变化）
  或 `waitUpTo - 10s` 超时 → `DONE` → 回到 §3.2 第 1 步。新邮件端到端延迟目标 < 5s。
- **无 IDLE**：`min(waitUpTo, 30s)` 间隔轮询（对齐现有 GmailPoller 节奏），期间有变化即提前返回。
- SyncEngine 以 `waitUpTo: .seconds(300)` 调用，因此一个“同步周期”对上层永远是 ≤5 min 的阻塞等待，
  进程内单循环、无定时器抖动。

### 3.4 退避、重连与健康状态

| 状态 | 触发 | 行为 |
|------|------|------|
| `ok` | 周期成功完成 | 正常；退避计数清零（连接稳定 ≥60s 即清零） |
| `degraded` | 网络错误 / TLS / 超时（非认证类） | 指数退避重连：1→2→4→…→300s（±20% jitter）；`last_sync_error` 落库并出现在 `GET /api/accounts` |
| `needsReconnect` | `NO [AUTHENTICATIONFAILED]` / 授权码被重置 | **停止重试**，UI 提示重新输入授权码；重新接入成功才恢复 |
| `error` | 结构性错误（`BAD` 语法、能力缺失到无法工作） | 保持退避重试，日志带命令标签；连续 3 轮失败升级为 `degraded` 展示 |

- 断线重连后**不重放**已确认游标之前的拉取；游标未持久化则自然重拉（幂等 upsert）。
- 认证失败**永不**快速重试（QQ 有登录风控）；`probe()` 同样计入该策略。
- 账号切换（activate）→ SyncEngine 取消当前循环、`LOGOUT` 旧连接、按新账号重建。
- 优雅退出（SIGINT/SIGTERM）→ `LOGOUT` + 关 socket。

### 3.5 同步健康的上浮（修掉“静默停止同步”）

`GET /api/accounts` 每个账号返回：

```jsonc
{ "id": "…", "provider": "qq", "email": "…@qq.com", "isActive": true,
  "syncHealth": { "status": "ok", "lastSyncAt": "2026-09-11T02:11:00Z", "lastError": null },
  "capabilities": { "archiveFolder": true, "idle": true, "move": true, "serverSnippet": true } }
```

客户端：账号菜单状态点 + 非 ok 时简报页顶部一条可关闭横幅（文案区分 needsReconnect / degraded）。

### 3.6 MIME 解析（自研子集，最大技术成本项）

`MIMEParser` 支持范围（其余一律 best-effort 降级，**永不 500**）：

| 维度 | 支持 | 降级 |
|------|------|------|
| 头部编码 | RFC2047 `B`/`Q`（UTF-8 / GBK / GB18030 / GB2312 / ISO-8859-1 / ASCII） | 原文透传 |
| 结构 | `multipart/alternative`（取 text/plain，无则 html→text）、`multipart/mixed`、`multipart/related`（取文本部分）、一层嵌套 `message/rfc822` | 取第一个 text 部分；全无则空正文 |
| 传输编码 | 7bit / 8bit / binary / base64 / quoted-printable | 原文透传 |
| 正文类型 | `text/plain`、`text/html`（复用既有 HTML→纯文本逻辑） | — |
| 明确不做 | 附件内容、内嵌图片、加密/签名（S/MIME、PGP） | 提示“此邮件含附件/签名，正文可能不完整” |

失败逃生舱（已评估、暂不引入）：MailCore2（2697★，有 `Package.swift`）。若浸泡期 MIME 边界问题
> 每周 1 例，则切 MailCore2，接口只影响 `IMAPProvider.fetchBody` 一处。

### 3.7 正文按需拉取

- `GET /api/messages/{remoteId}/body`（既有端点）→ `IMAPProvider.fetchBody`：
  `UID FETCH <uid> (BODY.PEEK[])` → `MIMEParser` → 纯文本；**正文不入库**（维持现有 §6.6 约定）。
- 远端已删除（`EXPUNGE`）导致 `UID FETCH` 空结果 → `410 {"error":"message-gone"}`，
  客户端提示“该邮件已在服务器上删除”，并从列表淡出（本地行保留 `is_read` 供撤销/审计）。
- 打开正文时标记已读：`UID STORE <uid> +FLAGS (\Seen)`（Gmail 侧保持现状 `labels` 逻辑）。

---

## 4. 写路径与接入流程

### 4.1 发送：SMTP（465 implicit TLS）

`SMTPClient`（NIO + NIOSSL，与 IMAP 共用 TLS 配置）：

```
connect smtp.qq.com:465 → TLS → greeting 220 → EHLO <client-host>
→ AUTH PLAIN <base64(\0user\0authCode)> → (235)
→ MAIL FROM:<me> → RCPT TO:<to> → DATA → <MIME 正文> → "." → QUIT
```

- 仅 implicit TLS（465）；**不实现 587/STARTTLS**（QQ 465 简洁可靠；明文端口不引入）。
- 4xx/超时 → 重试 1 次（**仅在 `DATA` 前可重试**；`DATA` 阶段后不重试以免重复投递）。
- 5xx → 直接失败，原文映射为中文提示（535 → “授权码/发信权限异常”）。
- QQ 是否把 SMTP 发出的信自动存入“已发送”：**待实测**（§5.5）；无论结果 v1 都不做 `APPEND`，避免重复。
- 发送**不可撤销**：`ai_actions` 记 `kind="send"` 审计行（payload `{remoteId, to}`），Undo 面板不提供回放
  ——符合 spec「人做最终确认的动作不进撤销队列」的原则。

### 4.2 回复内容的组装（`MIMEBuilder`）

- 头：`From`(账号地址) / `To`(原 From) / `Subject`(`Re: ` 前缀去重) / `Date`(RFC5322) /
  `Message-ID`(本地生成 `<uuid@lagoon>`) / `In-Reply-To` + `References`（取自 §2.1 新增列）/ `MIME-Version: 1.0`
- 体：`Content-Type: text/plain; charset=UTF-8` + base64（避免行宽/特殊字符问题）
- 非 ASCII 主题/显示名：RFC2047 `B` 编码

### 4.3 归档与撤销

| 动作 | Gmail | IMAP/QQ |
|------|-------|---------|
| archive | `modify` 去 `INBOX`（现状不变） | `UID MOVE <uid> <Archive>`；无 `MOVE` 则 `COPY`+`STORE +FLAGS \Deleted`+`EXPUNGE` |
| unarchive（撤销） | `modify` 加回 `INBOX` | `UID MOVE <uid> "INBOX"` |
| 本地先写 | `is_archived=TRUE` + `ai_actions(kind=archive)`（现状不变） | 同左 |

- **归档文件夹解析顺序**：`\Archive`（SPECIAL-USE）→ 名称匹配 `Archive`/`归档` → `CREATE "Archive"`（一次性，成功则记入
  `capabilities.archiveFolder=true`）→ 都不行 → `false`，客户端**禁用**归档按钮并附说明“该邮箱无归档文件夹”。
  禁用即“诚实降级”，不做 archive→Trash 的语义错配。
- 远端写失败时本地仍归档（现状行为），`ai_actions.payload.remoteWrite=false` 记录，撤销时再尝试远端还原。

### 4.4 API 变化一览

| 方法 | 路径 | 说明 |
|------|------|------|
| `POST` | `/api/accounts/imap` | 新。body `{provider:"qq", email, authCode}`；`probe()` 通过才落库（201 返回账号）；错误：400 参数缺失、401 `imap-auth-failed`、502 `imap-unreachable`、409 `account-exists`（提示改为切换） |
| `GET` | `/api/accounts` | 增 `isActive` / `syncHealth` / `capabilities`；credentials 永不回显 |
| `POST` | `/api/accounts/{id}/activate` | 新。切活跃账号（204） |
| `DELETE` | `/api/accounts/{id}` | 新。级联删除该账号邮件与动作（FK 已 `ON DELETE CASCADE`） |
| `POST` | `/api/messages/{remoteId}/send` | 新。body `{body}`；200 `{ok, providerMessageId?}`；401 `smtp-auth-failed` / 502 `smtp-send-failed` |
| 其余 messages/actions/drafts 路由 | | 参数 `:gmailId` → `:remoteId`，JSON 键同名替换 |

### 4.5 客户端改动

- **`ConnectView`**（替代 `ConnectGmailView`）：顶部 provider 分段；Gmail 保留现有按钮与轮询握手；
  QQ 表单 = 邮箱地址 + 16 位授权码，内嵌获取指引（QQ 邮箱 → 设置 → 账户 → 开启 IMAP/SMTP → 生成授权码，需短信验证）。
  提交后 loading → 成功进入列表 / 失败就地红字（区分“授权码错误”“网络不可达”）。
- **`ComposerSheet`**：详情页“回复”按钮打开；`To`/`Subject` 只读回显，正文可编辑，`⌘↩` 发送；
  发送中禁用输入；失败保留正文并显示原因；成功后 toast + 关闭。
- **`RootView` 账号菜单**：活跃账号打勾 + 状态点；点其他账号 = activate；`needsReconnect` 项点击直达 ConnectView。
- **归档按钮**：按 `capabilities.archiveFolder` 禁用/启用；撤销入口不变（`⌘Z` / Undo 面板）。

### 4.6 接入流程（QQ onboarding，真实步骤）

1. 客户端选 “QQ 邮箱” → 填地址 + 授权码 → `POST /api/accounts/imap`
2. 服务端 `probe()`：连接 → TLS → 认证 → 发 `ID` → `LIST` → `SELECT INBOX` → 解析角色（归档可用性）
3. 落库（credentials 密封 + `is_active=true` + `capabilities`）→ 启动/切换 SyncEngine
4. 首次同步：`UID FETCH 1:*` 全量头（QQ 新账号默认可见最近收件箱；量大时按 `UIDNEXT` 反向取最近 500 封，
   即 `UID FETCH <uidNext-500>:*`），正文仍按需
5. 客户端轮询 `GET /api/accounts` → 出现即切列表（沿用 M0 握手，不改）

---

## 5. 错误处理 · 测试策略 · 验收标准

### 5.1 错误分类与行为

| 错误 | 分类 | 行为 / 用户可见文案 |
|------|------|---------------------|
| `AUTHENTICATIONFAILED`（IMAP/SMTP） | 凭据 | `needsReconnect`，停止重试；“授权码错误或已失效，请在 QQ 邮箱设置中重新生成” |
| DNS/TCP/TLS 失败、超时 | 网络 | 退避重连；“网络异常，正在重试” |
| `BAD` 语法 / 服务器不支持某能力 | 协议 | 记日志（带命令标签）并按 §3.4 `error` 处理 |
| `UIDVALIDITY` 变化 | 数据 | 全量重建 + 日志；“邮箱结构变化，正在重新同步” |
| 正文 UID 已被 EXPUNGE | 数据 | `410 message-gone`；“该邮件已在服务器上删除” |
| MIME 解析失败 | 内容 | 降级纯文本（§3.6），永不 500 |
| SMTP 5xx | 发送 | 就地失败显示；**不重试** |
| SMTP 4xx / DATA 前超时 | 发送 | 重试 1 次；仍失败 → 502 |
| 归档文件夹缺失 | 能力 | 客户端禁用按钮 + 说明（§4.3） |

### 5.2 安全边界（沿用 spec §6.6，本设计新增项）

- IMAP/SMTP 连接**仅** 993/465 + implicit TLS，NIOSSL full verification；无“跳过证书校验”开关。
- 连接主机来自服务端 preset（QQ 固定 `imap.qq.com` / `smtp.qq.com`），不接受用户任意 host —— 无 SSRF 面。
- 授权码/令牌：密封落库、永不出现在任何日志/错误串/API 响应；`probe` 失败只回错误类别。
- 新增代码同样受 `scripts/ci-guardrails.sh` 约束：SQL 全参数化、无密钥形状字面量；测试库 `lagoon_test` 隔离不变。
- 服务器仍只绑 `127.0.0.1`（无 API 鉴权，维持现状）；不退化为“暴露端口换便利”。

### 5.3 测试策略

1. **MIMEParser 表驱动单测**（无网络，最大用例集）：RFC2047（GBK/UTF-8/Q 编码混合）、multipart/alternative 取舍、
   嵌套 multipart、base64/双行 QP、异常截断输入、附件标记降级。fixture 存 `Tests/LagoonServerTests/Fixtures/mime/`。
2. **IMAP 协议单测**：`IMAPTransport` 协议 + 脚本化 stub（镜像既有 `URLProtocolStub` 模式）：
   断言命令**精确序列**（含 `BODY.PEEK`、`IDLE…DONE` 重入、literal 分帧、UIDVALIDITY 变化路径）、
   认证失败→`needsReconnect`、退避序列。
3. **存储层测**：迁移后 `remote_id` 读写、credentials blob 加解密往返（cipher 复用既有测试基建）、
   `is_active` 不变式、`capabilities` JSONB、`sync_state` 迁移（Gmail `historyId` 字段映射）。
4. **路由测**：`POST /api/accounts/imap` 参数校验/401/409；`activate` 切换后 SyncEngine 收到信号；
   `send` 分发到 stub provider；`DELETE` 级联；archive capability 缺失时返回 `archive-unavailable`。
5. **回归**：现有 164 个测试全绿（改名 + 接缝重构后行为不变）；`bash scripts/run-all-tests.sh` 全绿。
6. **冒烟 + 浸泡**：真实 QQ 账号按 `docs/superpowers/m1-5-smoke.md` 清单走一遍（新建文档，格式对齐 m0-smoke）；
   14 天自用（spec §8）：每日新邮件同步、回复发送、归档撤销各至少一次。

### 5.4 验收标准（DoD）

- [ ] QQ：授权码接入 → 列表出现最近邮件 → 打开正文（GBK/HTML 邮件正确转文本）→ Briefing 五分堆 → AI 摘要（配 key）
- [ ] QQ：AI 草稿 → Composer 修改 → `⌘↩` 发送 → 收件人收到、QQ Web 已发送可见（或实测说明）
- [ ] QQ：归档（MOVE 或明确降级说明）→ `⌘Z` 撤销 → 邮件回到收件箱
- [ ] 同步健康：拔网 60s → 状态转 degraded + 自动恢复；授权码改错 → needsReconnect + 引导重录
- [ ] 新邮件端到端延迟 < 5s（IDLE 生效时）；无 IDLE 时 < 35s
- [ ] Gmail 回归：OAuth 重连路径可用（有代理环境），既有行为无变化
- [ ] `swift build` 三产物 + `swift test`（旧 164 + 新增）+ `scripts/run-all-tests.sh` 全绿
- [ ] `docs/使用说明.md` 更新（QQ 接入步骤、008 破坏性变更、排障条目）；`m1-5-smoke.md` 记录实测结果
- [ ] 14 天浸泡无 P0/P1 缺陷（P0 = 数据丢失或凭据泄漏；P1 = 同步静默停止 / 发送失败无提示）

### 5.5 开放问题（用真实账号在实施期确认，结论记入 smoke 文档）

1. QQ 发信后是否自动存入“已发送”（决定未来是否 `APPEND`）
2. QQ 的归档语义：IMAP 文件夹里有无 `\Archive` / `Archive` / `归档`；`CREATE` 是否允许
3. QQ IDLE 长连接稳定性（浸泡期观察重连频率）
4. QQ `UID FETCH <uidNext-500>:*` 对超大邮箱（>10 万封）的响应时间
5. 每轮 200 UID flags 回扫的真实成本（决定是否降频或引入 CONDSTORE）

### 5.6 风险与缓解

| 风险 | 缓解 |
|------|------|
| MIME 边界情况失控 | 自研子集范围明确；失败降级永不 500；逃生舱 MailCore2（单点替换） |
| QQ 登录风控（并发/频繁重连） | 单连接 + 命令串行 + 认证失败不重试 + 退避 jitter |
| 迁移破坏性（旧 token 不可迁移） | 迁移前 pg_dump；`needsReconnect` 状态有明确 UI 引导；文档化 |
| 范围蔓延（163/exmail/附件/HTML） | §0 非目标清单 + §1.4 里程碑闸门，v1 不含 |
| 接缝重构引入回归 | M1.5a 单独成阶段：先全量改名 + GmailProvider 抽取，164 测试全绿才进入 M1.5b |

---

## 6. 设计自检

- 占位符：无 TODO/TBD；开放问题集中在 §5.5 且均为“实测确认项”，不阻塞实施。
- 一致性：`MailProvider` 方法 ↔ §4 写路径 ↔ §5.3 测试项一一对应；`remoteId` 命名全文统一（§2.2 为唯一权威定义）。
- 范围：所有新增项都能追溯到 §0 目标；未引入 spec §10 之外的新特性。
- 歧义：§3.4 状态机、§4.3 归档解析顺序、§2.5 单活跃不变式均为确定性规则，无“视情况而定”。
