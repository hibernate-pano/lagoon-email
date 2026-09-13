# Lagoon IMAP / QQ 邮箱接入 Implementation Plan（M1.5）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 Lagoon 在国内网络直连 QQ 邮箱完成完整闭环（接入 → 同步 → 阅读 → Briefing → AI 摘要 → SMTP 回复 → 归档/撤销），Gmail 路径保留且行为不变。

**Architecture:** 抽一根 `MailProvider` 协议接缝，把 Gmail 轮询逻辑封装为 `GmailProvider`，新增 IMAP 实现（自研最小 IMAP 客户端于 NIO+NIOSSL，零新依赖）与 `SyncEngine`（单活跃账号、IDLE/轮询统一的 `pullChanges`）。身份从 `gmail_id` 泛化为 `remote_id`，凭据从双列泛化为 AES-GCM 密封 JSON blob。

**Tech Stack:** Swift 6.3 / macOS 26 SDK、Hummingbird 2.6.0、PostgresNIO 1.33.1、SwiftNIO + NIOSSL 2.27.0（已是直接依赖）、swift-crypto 3.9.0、Postgres 16（Docker :5433）、SwiftUI 客户端。

**Spec:** `docs/superpowers/specs/2026-09-11-imap-qq-provider-design.md`

## Global Constraints

（来自 spec §6.6 与本文档 §5.2；每个任务隐含继承，不再重复。）

1. 所有 SQL 必须参数绑定（`$N`）；字符串拼接 SQL 一律禁止；`Sources/LagoonKit/SQLBuilder.swift` 是唯一例外。守卫：`bash scripts/ci-guardrails.sh`。
2. 任何外部输入（授权码、邮件 id、UID、URL query）都视为不可信，只参数绑定或先解析为强类型。
3. 密钥形状的值不进 git；`.env` 已 gitignore；`bash scripts/test-guardrails.sh` 必须通过。
4. OAuth token / QQ 授权码：仅以 AES-GCM（`LAGOON_TOKEN_KEY`）密封形态落库；**永不进日志、永不出现在 API 响应**。
5. 服务端只绑 loopback（`127.0.0.1`），维持现状；M1.5 不引入 API 鉴权。
6. 邮件正文不落服务端存储（headers/snippet 除外）；正文只在请求时拉取并立即返回。
7. IMAP/SMTP 只允许 993 / 465 + implicit TLS，NIOSSL 完整证书校验，无“跳过校验”开关；连接主机来自服务端 preset，不来自用户输入。
8. 依赖版本精确锁定（`Package.swift` 用 `exact:`）；本计划不新增任何依赖。
9. 时间戳一律 UTC 存储；测试库只连 `lagoon_test`（`TestDatabase` 守卫）。
10. 每个任务结束时 `bash scripts/run-all-tests.sh` 必须全绿；提交信息跟随仓库风格（`feat(imap):` / `refactor(...)` / `docs(...)`）。

---

## File Structure（目标布局）

```
Sources/LagoonKit/
├── Account.swift              # Account 泛化：credentials/syncState/capabilities/isActive/health
├── MailProviderKind.swift     # 原 MailProvider 枚举改名（gmail | qq）
├── MailCapabilities.swift     # 新：运行时能力
├── MailSyncState.swift        # 新：游标（historyId | uidValidity/lastUid/archiveFolder）
├── SyncHealth.swift           # 新：ok|degraded|needsReconnect|error
├── MessageHeader.swift        # remoteId + messageIdHeader/inReplyTo/references
├── ConnectedAccount.swift     # + isActive/syncHealth/capabilities
└── Migrations/008_imap_providers.sql

Sources/LagoonServer/
├── Mail/
│   ├── MailProvider.swift         # 协议 + RemoteHeader/MailChangeSet/OutboundMessage/MailError
│   ├── MailProviderFactory.swift
│   └── ProviderPresets.swift      # qq: imap.qq.com:993 / smtp.qq.com:465
├── Sync/
│   └── SyncEngine.swift
├── IMAP/
│   ├── IMAPResponseParser.swift
│   ├── IMAPConnection.swift
│   ├── IMAPClient.swift
│   ├── IMAPProvider.swift
│   ├── MIMEParser.swift
│   └── SMTPClient.swift
├── Networking/
│   ├── StreamTransport.swift      # 新：协议（IMAP/SMTP 共用）
│   └── NIOSSLStreamTransport.swift# 新：NIO+NIOSSL 实现
├── Gmail/
│   ├── GmailProvider.swift        # 新：GmailClient/GmailTokenService → MailProvider
│   └── GmailPoller.swift          # 删除
└── Storage/
    ├── AccountCredentials.swift   # 新：AccountCredentials 枚举 + CredentialVault
    ├── AccountStore.swift         # 重写：blob 凭据 + 新列 + active/health API
    ├── AccessTokenCipher.swift    # 保留 seal/open/validateKey；read/StoredCredentials 移除
    └── MessageStore.swift         # remote_id + 新头字段 + find/deleteAll

Sources/Lagoon/
├── Views/ConnectView.swift        # 新（替代 ConnectGmailView.swift）
├── Views/ComposerSheet.swift      # 新
├── Views/MessageDetailView.swift  # + 回复按钮、归档 capability 门控
├── Views/RootView.swift           # + 账号菜单 + 健康横幅
├── Models/DirectoryStore.swift    # 新：客户端账号目录（活跃账号/健康/能力）
└── Services/APIClient.swift       # 新端点 + remoteId 改名

Tests/LagoonServerTests/
├── Fixtures/mime/*.eml            # 新：MIME 解析 fixture
├── StubMailProvider.swift         # 新：SyncEngine 测试替身
├── ScriptedTransport.swift        # 新：StreamTransport 脚本替身
├── SyncEngineTests.swift / GmailProviderTests.swift（原 GmailPollerTests.swift）
├── IMAPResponseParserTests.swift / IMAPConnectionTests.swift / IMAPClientTests.swift
├── MIMEParserTests.swift / SMTPClientTests.swift / MIMEBuilderTests.swift
└── RouteTests（QQ 相关用例追加）
```

---

### Task 1: 迁移 008 + `gmailId→remoteId` 全量改名 + 凭据/状态泛化（Gmail 行为不变）

**Files:**
- Create: `Sources/LagoonKit/Migrations/008_imap_providers.sql`
- Create: `Sources/LagoonKit/MailProviderKind.swift`（原 `Account.swift` 内枚举迁移）
- Create: `Sources/LagoonKit/MailCapabilities.swift`、`Sources/LagoonKit/MailSyncState.swift`、`Sources/LagoonKit/SyncHealth.swift`
- Create: `Sources/LagoonServer/Storage/AccountCredentials.swift`
- Modify: `Sources/LagoonKit/Account.swift`、`MessageHeader.swift`、`ConnectedAccount.swift`
- Modify: `Sources/LagoonServer/Storage/AccountStore.swift`（重写）、`AccessTokenCipher.swift`、`MessageStore.swift`
- Modify: 机械改名波及的全部文件（Sources + Tests，排除 `Sources/LagoonKit/Migrations/`）
- Test: `Tests/LagoonServerTests/AccountStoreTests.swift`（重写凭据部分）、`MessageStoreTests.swift`、`Tests/LagoonKitTests/DomainCodableTests.swift`、`RouteTests.swift`（构造参数）

**Interfaces:**
- Consumes: 现有 `AccessTokenCipher`（seal/open/validateKey 保留）。
- Produces（后续任务依赖的确切形状）:

```swift
// LagoonKit
public enum MailProviderKind: String, Codable, Sendable, CaseIterable { case gmail, qq }

public struct MailSyncState: Codable, Equatable, Sendable {
    public var historyId: String?
    public var uidValidity: Int64?
    public var lastUid: Int64?
    public var archiveFolder: String?
    public init(historyId: String? = nil, uidValidity: Int64? = nil,
                lastUid: Int64? = nil, archiveFolder: String? = nil)
}

public struct MailCapabilities: Codable, Equatable, Sendable {
    public var archiveFolder: Bool
    public var idle: Bool
    public var move: Bool
    public var serverSnippet: Bool
    public static let unknown = MailCapabilities(
        archiveFolder: false, idle: false, move: false, serverSnippet: false)
    public init(archiveFolder: Bool, idle: Bool, move: Bool, serverSnippet: Bool)
}

public struct SyncHealth: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case ok, degraded, needsReconnect, error }
    public var status: Status
    public var lastSyncAt: Date?
    public var lastError: String?
    public init(status: Status, lastSyncAt: Date? = nil, lastError: String? = nil)
}

public struct Account: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let provider: MailProviderKind
    public let oauthUser: String
    public let email: String
    public let credentials: Data?        // 密封 blob；Codable 序列化时不参与 API 输出（Account 从不出现在 API 响应里）
    public let syncState: MailSyncState
    public let capabilities: MailCapabilities
    public let isActive: Bool
    public let syncHealth: SyncHealth
    public init(id: UUID, provider: MailProviderKind, oauthUser: String, email: String,
                credentials: Data?, syncState: MailSyncState = .init(),
                capabilities: MailCapabilities = .unknown, isActive: Bool = false,
                syncHealth: SyncHealth = SyncHealth(status: .ok))
}

public struct MessageHeader: Codable, Equatable, Sendable, Identifiable {
    // …既有字段不变，改动两项：
    public let remoteId: String                 // was gmailId
    public let messageIdHeader: String?         // 新增（默认 nil）
    public let inReplyTo: String?               // 新增（默认 nil）
    public let references: String?              // 新增（默认 nil）
    // init(..., remoteId:, messageIdHeader: nil, inReplyTo: nil, references: nil, ...)
}

public struct ConnectedAccount: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let provider: MailProviderKind
    public let email: String
    public let isActive: Bool
    public let syncHealth: SyncHealth
    public let capabilities: MailCapabilities
}

// LagoonServer
public enum AccountCredentials: Codable, Sendable, Equatable {
    case gmail(accessToken: String, refreshToken: String, expiresAt: Date)
    case imap(username: String, authCode: String)
}
public enum CredentialVault {   // 密封编解码，唯一读写 accounts.credentials 的入口
    public static func write(_ c: AccountCredentials, accountId: UUID, db: PostgresConnection) async throws
    public static func read(accountId: UUID, db: PostgresConnection) async throws -> AccountCredentials
}
public enum AccountStore {
    public static func upsert(_ a: Account, credentials: Data, db: PostgresConnection) async throws
    public static func updateCredentials(accountId: UUID, credentials: Data, db: PostgresConnection) async throws
    public static func updateSyncState(accountId: UUID, syncState: MailSyncState, db: PostgresConnection) async throws
    public static func updateCapabilities(accountId: UUID, capabilities: MailCapabilities, db: PostgresConnection) async throws
    public static func updateHealth(accountId: UUID, health: SyncHealth, db: PostgresConnection) async throws
    public static func all(db: PostgresConnection) async throws -> [Account]
    public static func active(db: PostgresConnection) async throws -> Account?
    public static func setActive(accountId: UUID, db: PostgresConnection) async throws
    public static func reconcileActive(db: PostgresConnection) async throws
    public static func delete(accountId: UUID, db: PostgresConnection) async throws
    public static func find(byId id: UUID, db: PostgresConnection) async throws -> Account?
    public static func find(byOAuthUser: String, provider: MailProviderKind, db: PostgresConnection) async throws -> Account?
}
public enum MessageStore {
    public static func upsert(_ m: MessageHeader, listUnsubscribe: Bool = false, db: PostgresConnection) async throws
    public static func deleteAll(accountId: UUID, db: PostgresConnection) async throws
    public static func find(remoteId: String, accountId: UUID, db: PostgresConnection) async throws -> MessageHeader?
    // 其余签名不变（remoteId 改名）
}
```

- [ ] **Step 1: 写迁移 `008_imap_providers.sql`**

完整内容（注意：**不要**修改 001–007 任何文件）：

```sql
-- M1.5: 从 Gmail 专用身份/凭据泛化到多 provider。
-- 破坏性：旧 token 列被删除（密文无法在 SQL 内重密封）；既有 Gmail 账号会显示
-- needsReconnect，重新 Connect 一次即可恢复。运行前先 pg_dump。

ALTER TABLE accounts DROP CONSTRAINT IF EXISTS accounts_provider_check;
ALTER TABLE accounts ADD CONSTRAINT accounts_provider_check CHECK (provider IN ('gmail','qq'));

ALTER TABLE accounts
    ADD COLUMN IF NOT EXISTS credentials    BYTEA,
    ADD COLUMN IF NOT EXISTS sync_state     JSONB NOT NULL DEFAULT '{}'::jsonb,
    ADD COLUMN IF NOT EXISTS capabilities   JSONB NOT NULL DEFAULT '{}'::jsonb,
    ADD COLUMN IF NOT EXISTS is_active      BOOLEAN NOT NULL DEFAULT TRUE,
    ADD COLUMN IF NOT EXISTS sync_status    TEXT NOT NULL DEFAULT 'ok',
    ADD COLUMN IF NOT EXISTS last_sync_at   TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS last_sync_error TEXT;

UPDATE accounts SET sync_state = jsonb_build_object('historyId', history_id)
 WHERE history_id IS NOT NULL AND sync_state = '{}'::jsonb;

ALTER TABLE message_headers RENAME COLUMN gmail_id TO remote_id;
ALTER TABLE message_pins    RENAME COLUMN gmail_id TO remote_id;
ALTER TABLE draft_replies   RENAME COLUMN gmail_id TO remote_id;
ALTER TABLE ai_overrides    RENAME COLUMN gmail_id TO remote_id;
ALTER INDEX IF EXISTS draft_replies_gmail_id_idx RENAME TO draft_replies_remote_id_idx;
ALTER INDEX IF EXISTS ai_overrides_gmail_id_idx  RENAME TO ai_overrides_remote_id_idx;

ALTER TABLE message_headers
    ADD COLUMN IF NOT EXISTS message_id_header TEXT,
    ADD COLUMN IF NOT EXISTS in_reply_to       TEXT,
    ADD COLUMN IF NOT EXISTS references_header TEXT;

UPDATE ai_actions
   SET payload = (payload - 'gmailId') || jsonb_build_object('remoteId', payload->'gmailId')
 WHERE payload ? 'gmailId';

ALTER TABLE accounts
    DROP COLUMN IF EXISTS access_token,
    DROP COLUMN IF EXISTS refresh_token,
    DROP COLUMN IF EXISTS token_expires_at,
    DROP COLUMN IF EXISTS history_id;
```

- [ ] **Step 2: 备份开发库（破坏性迁移前的安全网）**

Run:
```bash
docker compose up -d
docker exec lagoon-postgres pg_dump -U lagoon lagoon > /tmp/backup-pre-008.sql && wc -l /tmp/backup-pre-008.sql
```
Expected: 输出行数 > 0；若容器名不同用 `docker ps` 确认。

- [ ] **Step 3: 机械改名（run-once，排除历史迁移目录）**

```bash
git grep -lz 'gmailId' -- Sources Tests | xargs -0 sed -i '' 's/gmailId/remoteId/g'
git grep -lz 'gmail_id' -- Sources Tests | xargs -0 sed -i '' 's/gmail_id/remote_id/g'
git grep -lz 'MailProvider' -- Sources Tests | xargs -0 sed -i '' 's/MailProvider/MailProviderKind/g'
```
再跑一次确认（应为空）：
```bash
git grep -n 'gmailId\|gmail_id' -- Sources Tests | grep -v 'Sources/LagoonKit/Migrations/' ; echo "exit=$?"
```
Expected: 无输出（`exit=1`）。注意：此 sed 不能重复执行（`MailProviderKind` 会被二次替换）。

- [ ] **Step 4: 修正 sed 误伤与枚举声明位置**

`Sources/LagoonKit/Account.swift` 里现在是 `public enum MailProviderKind: String, …`——把它整段剪切到新文件 `Sources/LagoonKit/MailProviderKind.swift`（含 `case gmail, qq`），`Account.swift` 只留 `Account` 结构体并按 **Interfaces** 重写。注意 `MailProviderKindKind` 之类的二次替换若出现，手工改回。

- [ ] **Step 5: 新增 LagoonKit 三个类型文件**

`MailSyncState.swift` / `MailCapabilities.swift` / `SyncHealth.swift` 按 **Interfaces** 原样落地（`import Foundation`）。

- [ ] **Step 6: 重写 `AccountCredentials.swift`（凭据密封编解码）**

```swift
import Foundation
import PostgresNIO
import LagoonKit

public enum AccountCredentials: Codable, Sendable, Equatable {
    case gmail(accessToken: String, refreshToken: String, expiresAt: Date)
    case imap(username: String, authCode: String)

    private enum CodingKeys: String, CodingKey { case kind, accessToken, refreshToken, expiresAt, username, authCode }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .gmail(let a, let r, let e):
            try c.encode("gmail", forKey: .kind)
            try c.encode(a, forKey: .accessToken)
            try c.encode(r, forKey: .refreshToken)
            try c.encode(e, forKey: .expiresAt)
        case .imap(let u, let code):
            try c.encode("imap", forKey: .kind)
            try c.encode(u, forKey: .username)
            try c.encode(code, forKey: .authCode)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "gmail":
            self = .gmail(accessToken: try c.decode(String.self, forKey: .accessToken),
                          refreshToken: try c.decode(String.self, forKey: .refreshToken),
                          expiresAt: try c.decode(Date.self, forKey: .expiresAt))
        case "imap":
            self = .imap(username: try c.decode(String.self, forKey: .username),
                         authCode: try c.decode(String.self, forKey: .authCode))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown credential kind")
        }
    }
}

/// 唯一读写 `accounts.credentials` 的入口：AES-GCM 密封 JSON。
public enum CredentialVault {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

    public static func seal(_ credentials: AccountCredentials) throws -> Data {
        let json = try encoder.encode(credentials)
        return try AccessTokenCipher.seal(String(decoding: json, as: UTF8.self))
    }

    public static func open(_ blob: Data) throws -> AccountCredentials {
        let json = try AccessTokenCipher.open(blob)
        guard let data = json.data(using: .utf8) else { throw TokenCipherError.notUTF8 }
        return try decoder.decode(AccountCredentials.self, from: data)
    }

    public static func write(_ credentials: AccountCredentials, accountId: UUID, db: PostgresConnection) async throws {
        try await db.query(
            "UPDATE accounts SET credentials = $2, updated_at = now() WHERE id = $1",
            [PostgresData(uuid: accountId), PostgresData(bytes: try seal(credentials))]
        ).get()
    }

    public static func read(accountId: UUID, db: PostgresConnection) async throws -> AccountCredentials {
        let result = try await db.query(
            "SELECT credentials FROM accounts WHERE id = $1",
            [PostgresData(uuid: accountId)]
        ).get()
        guard let row = result.rows.first,
              let blob = try row.makeRandomAccess()["credentials"].decode(Data?.self)
        else { throw AccountStoreError.notFound }
        return try open(blob)
    }
}
```
**同时**从 `AccessTokenCipher.swift` 删除 `StoredCredentials` 与 `read(accountId:db:)`（blob 取代），保留 `seal/open/validateKey`；`TokenCipherError` 保留。

- [ ] **Step 7: 重写 `AccountStore.swift`**

关键点（全部 `$N` 绑定）：SELECT 列清单统一为
`id, provider, oauth_user, email, credentials, sync_state, capabilities, is_active, sync_status, last_sync_at, last_sync_error`；
`decode` 中 `sync_state`/`capabilities` 用 `JSONDecoder`（`dateDecodingStrategy = .iso8601`）解 `MailSyncState`/`MailCapabilities`，空 `{}` 要能解出默认值（给两个类型都加 `decodeIfPresent` 友好性：直接解 `{}` 即可，字段都是 optional / 有默认值——`MailCapabilities` 需自定义 `init(from:)`，缺失键取 `false`）。

```swift
public static func upsert(_ a: Account, credentials: Data, db: PostgresConnection) async throws {
    let sql = """
        INSERT INTO accounts (
            id, provider, oauth_user, email, credentials, sync_state, capabilities,
            is_active, sync_status, last_sync_at, last_sync_error, created_at, updated_at
        ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11, now(), now())
        ON CONFLICT (provider, oauth_user) DO UPDATE SET
            email = EXCLUDED.email,
            credentials = EXCLUDED.credentials,
            updated_at = now()
    """
    try await db.query(sql, [
        PostgresData(uuid: a.id), PostgresData(string: a.provider.rawValue),
        PostgresData(string: a.oauthUser), PostgresData(string: a.email),
        PostgresData(bytes: credentials),
        PostgresData(jsonb: try Self.encodeJSON(a.syncState)),
        PostgresData(jsonb: try Self.encodeJSON(a.capabilities)),
        PostgresData(bool: a.isActive), PostgresData(string: a.syncHealth.status.rawValue),
        a.syncHealth.lastSyncAt.map { PostgresData(date: $0) } ?? .null,
        a.syncHealth.lastError.map { PostgresData(string: $0) } ?? .null
    ]).get()
}
```
（`PostgresData(jsonb:)` 在 PostgresNIO 1.33 为 `PostgresData(jsonb: String)`；`encodeJSON` 返回 String——若该初始化器不存在，改用 `PostgresData(string:)` 并在 SQL 中显式 `$6::jsonb` 转换。以编译结果为准，二选一，不要两个都留。）

`setActive`：
```swift
public static func setActive(accountId: UUID, db: PostgresConnection) async throws {
    try await db.query("UPDATE accounts SET is_active = (id = $1), updated_at = now()", [PostgresData(uuid: accountId)]).get()
}
public static func active(db: PostgresConnection) async throws -> Account? {
    let rows = try await db.query(
        "SELECT \(Self.columns) FROM accounts WHERE is_active = TRUE ORDER BY updated_at DESC LIMIT 1", []
    ).get()
    return try rows.first.map { try Self.decode($0) }
}
public static func reconcileActive(db: PostgresConnection) async throws {
    let accounts = try await all(db: db)
    let actives = accounts.filter(\.isActive)
    if actives.count == 1 { return }
    if actives.isEmpty, let newest = accounts.max(by: { $0.id.uuidString < $1.id.uuidString }) {
        try await setActive(accountId: newest.id, db: db)
    } else if let keep = actives.first {
        try await setActive(accountId: keep.id, db: db)
    }
}
```
`updateHealth` 写 `sync_status/last_sync_at/last_sync_error`；`updateSyncState` 写 `sync_state::jsonb`；`delete` 直接 `DELETE FROM accounts WHERE id=$1`（FK 级联清理）。

- [ ] **Step 8: 更新 `MessageStore`**

- SQL 列名/占位符改名 `remote_id`；upsert 增加 `message_id_header/in_reply_to/references_header` 三列（`m.messageIdHeader.map { PostgresData(string: $0) } ?? .null`）。
- 新增：
```swift
public static func deleteAll(accountId: UUID, db: PostgresConnection) async throws {
    try await db.query("DELETE FROM message_headers WHERE account_id = $1", [PostgresData(uuid: accountId)]).get()
}
public static func find(remoteId: String, accountId: UUID, db: PostgresConnection) async throws -> MessageHeader? {
    let rows = try await db.query(
        "SELECT \(Self.columns) FROM message_headers WHERE account_id = $1 AND remote_id = $2 LIMIT 1",
        [PostgresData(uuid: accountId), PostgresData(string: remoteId)]
    ).get()
    return try rows.first.map { try Self.decode($0) }
}
```
（把 SELECT 列清单抽成 `static let columns` 常量，`recent/decode/find` 共用。）

- [ ] **Step 9: 修复编译与测试**

- `GmailTokenService`：读写改为 `CredentialVault`（`.gmail(...)` 分支）；刷新成功后 `CredentialVault.write(.gmail(accessToken:refreshToken:expiresAt:))`。
- 其余调用点：`MessageHeader(gmailId:` → `remoteId:`（sed 已改标识符，构造参数标签同步核对）；`Account(tokenExpiresAt:historyId:)` 构造点改为新 init（GmailPoller/RouteTests/AccountStoreTests 等）。
- 测试断言里 `ConnectedAccount(id:provider:email:)` 增加三参数（`isActive: false, syncHealth: SyncHealth(status: .ok), capabilities: .unknown`）。
- 删除测试中依赖旧 `AccessTokenCipher.read/StoredCredentials` 的断言，改用 `CredentialVault.read` 返回的 `.gmail` 关联值。

Run: `swift build && swift test 2>&1 | tail -20`
Expected: 编译通过，全部测试 PASS（数量不少于改名前 164）。

- [ ] **Step 10: 迁移测试库并全量自检**

Run: `bash scripts/run-all-tests.sh`
Expected: 末尾 `ALL CHECKS PASSED`（迁移 008 在 `lagoon_test` 上应用；重复执行应跳过已应用）。

- [ ] **Step 11: Commit**

```bash
git add -A
git commit -m "refactor(store): 迁移 008（remote_id/credentials blob/sync_state/is_active）+ provider 泛化，Gmail 行为不变"
```

---

### Task 2: `MailProvider` 接缝 + `GmailProvider` + `SyncEngine`

**Files:**
- Create: `Sources/LagoonServer/Mail/MailProvider.swift`、`Mail/MailProviderFactory.swift`、`Mail/ProviderPresets.swift`、`Sync/SyncEngine.swift`、`Gmail/GmailProvider.swift`
- Delete: `Sources/LagoonServer/Gmail/GmailPoller.swift`
- Modify: `Sources/LagoonServer/App.swift:52-57,79-113`
- Test: `Tests/LagoonServerTests/GmailProviderTests.swift`（由 `GmailPollerTests.swift` 改名与移植）、`Tests/LagoonServerTests/StubMailProvider.swift`、`Tests/LagoonServerTests/SyncEngineTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `Account/SyncHealth/MailSyncState`、`AccountStore.updateSyncState/updateHealth`、`MessageStore.upsert/deleteAll`、`GmailClient/GmailTokenService`。
- Produces:

```swift
public struct RemoteHeader: Sendable, Equatable {
    public var remoteId: String
    public var threadId: String
    public var fromAddress: String
    public var fromName: String?
    public var subject: String?
    public var snippet: String?
    public var receivedAt: Date
    public var isRead: Bool
    public var listUnsubscribe: Bool
    public var messageIdHeader: String?
    public var inReplyTo: String?
    public var references: String?
    public init(remoteId: String, threadId: String, fromAddress: String, fromName: String? = nil,
                subject: String? = nil, snippet: String? = nil, receivedAt: Date, isRead: Bool,
                listUnsubscribe: Bool = false, messageIdHeader: String? = nil,
                inReplyTo: String? = nil, references: String? = nil)
}

public struct MailChangeSet: Sendable {
    public var upserts: [RemoteHeader]
    public var resetRequired: Bool
    public var cursor: MailSyncState
}

public struct OutboundMessage: Sendable {
    public var fromEmail: String
    public var fromName: String?
    public var to: String
    public var subject: String
    public var body: String
    public var inReplyTo: String?
    public var references: String?
    public init(fromEmail: String, fromName: String?, to: String, subject: String,
                body: String, inReplyTo: String?, references: String?)
}

public enum MailError: Error, Equatable {
    case authFailed
    case unreachable(String)
    case protocolError(String)
    case messageGone
    case archiveUnavailable
    case notConfigured(String)
    public var logLabel: String   // "auth-failed" | "unreachable" | …
}

public protocol MailProvider: Sendable {
    var kind: MailProviderKind { get }
    func capabilities() async -> MailCapabilities
    func pullChanges(after cursor: MailSyncState, waitUpTo: Duration) async throws -> MailChangeSet
    func fetchBody(remoteId: String) async throws -> String
    func fetchRawHeaderValues(remoteId: String) async throws -> [String: String]
    func setRead(remoteId: String, isRead: Bool) async throws
    func archive(remoteId: String) async throws
    func unarchive(remoteId: String) async throws
    func send(_ outbound: OutboundMessage) async throws -> String?
    func probe() async throws
}

public enum MailProviderFactory {
    public static func make(account: Account, client: GmailClient, tokens: GmailTokenService,
                            db: PostgresConnection, logger: Logger) -> (any MailProvider)?
}

public actor SyncEngine {
    public init(db: PostgresConnection, logger: Logger,
                providers: @escaping @Sendable (Account) -> (any MailProvider)?)
    public func start()                       // 后台循环任务
    public func stop()
    public func tickOnce() async              // 测试入口：拉一轮活跃账号
}
```

- [ ] **Step 1: 写 `MailProvider.swift` + `ProviderPresets.swift`**

`ProviderPresets`：
```swift
public struct IMAPPreset: Sendable, Equatable {
    public let imapHost: String
    public let imapPort: Int      // 恒 993
    public let smtpHost: String
    public let smtpPort: Int      // 恒 465
}

public enum ProviderPresets {
    public static func imap(for kind: MailProviderKind) -> IMAPPreset? {
        switch kind {
        case .qq: return IMAPPreset(imapHost: "imap.qq.com", imapPort: 993,
                                    smtpHost: "smtp.qq.com", smtpPort: 465)
        case .gmail: return nil   // Gmail 走 REST，不提供 IMAP preset
        }
    }
}
```

- [ ] **Step 2: 写 `GmailProvider.swift`（GmailPoller 逻辑移植）**

`pullChanges(after:waitUpTo:)`：循环 `min(waitUpTo, 30s)` 轮询；每轮调用既有 `syncMessages` 逻辑（`listMessageRefs(maxResults:50)` → 并发 8 抓 metadata → 组装 `RemoteHeader`），有变化立即返回，否则 sleep 30s 直到 `waitUpTo` 耗尽返回空 `upserts` + 同一 cursor（cursor = `MailSyncState(historyId: account.syncState.historyId)`）。
`fetchBody`：`client.getMessage(format:.full)` → `GmailBodyExtractor.plainText`；404 → `MailError.messageGone`。
`setRead`：`client.modify(add:["UNREAD"]/remove:)` 语义对齐 ActionsRoutes 现状（`isRead=true` → remove `UNREAD`）。
`archive`：`client.modify(remove:["INBOX"])`；`unarchive`：`modify(add:["INBOX"])`。
`send`：`client.sendMessage(...)`（GmailClient.swift:177 既有方法，Task 11 接路由）。
`probe`：`client.getProfile()` 成功即通过，401 → `.authFailed`。
`capabilities()`：`MailCapabilities(archiveFolder: true, idle: false, move: true, serverSnippet: true)`。
Gmail 的 `RemoteHeader.threadId` 取 `raw.threadId`，`snippet` 取 `raw.snippet`，`messageIdHeader/inReplyTo/references` 从 metadata headers 提取（`Message-ID`/`In-Reply-To`/`References`，取不到置 nil）。
**注意**：Gmail 的 `GmailPoller.header(from:)` / `parseFromHeader` / `hasListUnsubscribe` 三个 static 函数整体搬进 `GmailProvider`，`FromHeaderTests` 相应改 `@testable` 目标。

- [ ] **Step 3: 写 `SyncEngine.swift`**

```swift
public actor SyncEngine {
    private let db: PostgresConnection
    private let logger: Logger
    private let providers: @Sendable (Account) -> (any MailProvider)?
    private var loop: Task<Void, Never>?
    private var consecutiveFailures = 0
    private var currentAccountId: UUID?

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tickOnce()
            }
        }
    }

    public func stop() { loop?.cancel(); loop = nil }

    /// 一轮：取活跃账号 → 拉变化 → 落库 → 推进游标 → 写健康。
    /// 失败按 §3.4：认证失败停止重试 60s；其余指数退避 1→2→…→300s（±20% jitter）。
    public func tickOnce() async {
        do {
            guard let account = try await AccountStore.active(db: db) else {
                try await Task.sleep(for: .seconds(5)); return
            }
            currentAccountId = account.id
            guard let provider = providers(account) else {
                try await AccountStore.updateHealth(accountId: account.id,
                    health: SyncHealth(status: .error, lastSyncAt: nil, lastError: "no-provider"), db: db)
                try await Task.sleep(for: .seconds(60)); return
            }
            let changes = try await provider.pullChanges(after: account.syncState, waitUpTo: .seconds(300))
            try await apply(changes, to: account)
            consecutiveFailures = 0
        } catch is CancellationError {
            return
        } catch let error as MailError where error == .authFailed {
            await markAuthFailure()
        } catch {
            await markFailure(error)
        }
    }

    private func apply(_ changes: MailChangeSet, to account: Account) async throws {
        if changes.resetRequired {
            try await MessageStore.deleteAll(accountId: account.id, db: db)
            try await AccountStore.updateSyncState(accountId: account.id,
                syncState: MailSyncState(uidValidity: changes.cursor.uidValidity,
                                         lastUid: changes.cursor.lastUid,
                                         archiveFolder: changes.cursor.archiveFolder), db: db)
            logger.warning("sync.uidValidityReset", metadata: ["account": .string(account.email)])
        }
        for header in changes.upserts {
            try await MessageStore.upsert(Self.message(from: header, accountId: account.id),
                                          listUnsubscribe: header.listUnsubscribe, db: db)
        }
        try await AccountStore.updateSyncState(accountId: account.id, syncState: changes.cursor, db: db)
        try await AccountStore.updateHealth(accountId: account.id,
            health: SyncHealth(status: .ok, lastSyncAt: Date(), lastError: nil), db: db)
        if !changes.upserts.isEmpty {
            logger.info("sync.applied", metadata: ["account": .string(account.email),
                                                   "count": .string("\(changes.upserts.count)")])
        }
    }

    static func message(from h: RemoteHeader, accountId: UUID) -> MessageHeader {
        MessageHeader(id: UUID(), accountId: accountId, remoteId: h.remoteId, threadId: h.threadId,
                      fromAddress: h.fromAddress, fromName: h.fromName, subject: h.subject,
                      snippet: h.snippet, receivedAt: h.receivedAt, isRead: h.isRead,
                      isArchived: false, messageIdHeader: h.messageIdHeader,
                      inReplyTo: h.inReplyTo, references: h.references)
    }

    private func markAuthFailure() async {
        if let id = currentAccountId {
            try? await AccountStore.updateHealth(accountId: id,
                health: SyncHealth(status: .needsReconnect, lastSyncAt: nil, lastError: "auth-failed"), db: db)
        }
        try? await Task.sleep(for: .seconds(60))
    }

    private func markFailure(_ error: Error) async {
        consecutiveFailures += 1
        if let id = currentAccountId {
            try? await AccountStore.updateHealth(accountId: id,
                health: SyncHealth(status: consecutiveFailures >= 3 ? .degraded : .error,
                                   lastSyncAt: nil, lastError: "\(error)"), db: db)
        }
        let base = min(300.0, pow(2.0, Double(consecutiveFailures - 1)))
        let jitter = base * 0.2 * Double.random(in: -1...1)
        try? await Task.sleep(for: .seconds(max(1, base + jitter)))
    }
}
```
`max` 用于退避；`pow/random` 直接 `Foundation`。

- [ ] **Step 4: 改 `App.swift` 接线**

```swift
let syncEngine = SyncEngine(db: db, logger: logger) { account in
    MailProviderFactory.make(account: account, client: gmailClient, tokens: tokens, db: db, logger: logger)
}
try await AccountStore.reconcileActive(db: db)
...
OAuthRoutes.register(on: router, db: db, oauth: google, poller: syncEngine, logger: logger)  // 参数名沿用；仅用于 OAuth 完成后立刻拉一轮
...
Task { await syncEngine.start() }
```
（`OAuthRoutes` 里 `poller.tick()` 调用改为 `await syncEngine.tickOnce()`；接口签名保持 `poller:` 会让读者困惑——重命名为 `sync:` 并同步改 `OAuthRoutes.swift` 与 `RouteTests`。）

- [ ] **Step 5: 移植测试**

- `git mv Tests/LagoonServerTests/GmailPollerTests.swift Tests/LagoonServerTests/GmailProviderTests.swift`，把 `makePoller(db:)` 改为 `GmailProvider(account:client:tokens:logger:)` 并在每个用例里先 `try await provider.pullChanges(after: .init(), waitUpTo: .milliseconds(1))`（等价 tick 一次）——断言内容全部保留（refresh 次数、401 重试、并发抓取、header 落库）。
- 新 `StubMailProvider`：脚本化 `[MailChangeSet]` + `fetchBody` 返回值 + 可注入 `MailError`。
- 新 `SyncEngineTests`：覆盖 (a) 成功落库 + 游标推进 + health=ok；(b) `resetRequired` → 先 `deleteAll` 再落新数据 + 游标重置；(c) `.authFailed` → status=needsReconnect；(d) 一般错误 → consecutiveFailures 累加、status 由 error→degraded。

Run: `swift test --filter 'GmailProviderTests|SyncEngineTests' 2>&1 | tail -15`
Expected: PASS。

- [ ] **Step 6: 全量自检 + Commit**

Run: `bash scripts/run-all-tests.sh`
Expected: `ALL CHECKS PASSED`。

```bash
git add -A && git commit -m "feat(imap): MailProvider 接缝 + GmailProvider + SyncEngine（pullChanges 统一轮询）"
```

---

### Task 3: `IMAPResponseParser`（纯函数，TDD）

**Files:**
- Create: `Sources/LagoonServer/IMAP/IMAPResponseParser.swift`
- Test: `Tests/LagoonServerTests/IMAPResponseParserTests.swift`

**Interfaces:**
- Produces:

```swift
public struct IMAPResponse: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case tagged(String, IMAPStatus), untagged, continuation }
    public var kind: Kind
    public var atoms: [String]              // 行内以空格切分的原子（引号串作为单个原子，已去引号）
    public var literal: Data?               // {N} 后的字面量
    public var raw: String
}
public enum IMAPStatus: String, Sendable { case ok = "OK", no = "NO", bad = "BAD" }

public enum IMAPResponseParser {
    /// 解析一行（不含 CRLF）+ 可选字面量。返回 nil 表示空行/纯空白。
    public static func parse(line: String, literal: Data? = nil) -> IMAPResponse?
    /// 从行首读取 `{N}` 长度声明（含 `{N+}` 非同步形式）。
    public static func literalLength(in line: String) -> Int?
    /// 把 `(A B C)` 括号列表拆成原子数组（保留嵌套为单个原子字符串）。
    public static func parenthesized(_ line: String) -> [String]?
}
```
`parse` 对 tagged 行（`A0003 OK FETCH completed`）识别 tag + status；对 `* 12 EXISTS` → untagged；对 `+ Ready for literal` → continuation。引号/反斜杠转义按 RFC 3501 quoted-string 处理。

- [ ] **Step 1: 写失败测试**（覆盖：tagged OK/NO/BAD、untagged EXISTS、continuation、quoted string 带转义、`{123}` 与 `{123+}`、括号列表、非 ASCII raw 透传、空行 nil）

关键用例：
```swift
func test_taggedOk_capturesTagAndStatus() {
    let r = IMAPResponseParser.parse(line: "A0004 OK FETCH completed")
    XCTAssertEqual(r?.kind, .tagged("A0004", .ok))
}
func test_literalLength_acceptsNonSynchronizingForm() {
    XCTAssertEqual(IMAPResponseParser.literalLength(in: "* 1 FETCH (BODY[TEXT] {256+}"), 256)
    XCTAssertEqual(IMAPResponseParser.literalLength(in: "A2 NO"), nil)
}
func test_quotedString_unescapesBackslashAndQuote() {
    let r = IMAPResponseParser.parse(line: #"* LIST (\HasNoChildren) "/" "Sent \"Box\"""#)
    XCTAssertEqual(r?.atoms, ["*", "LIST", #"(\HasNoChildren)"#, "/", #"Sent "Box""#])
}
```
Run: `swift test --filter IMAPResponseParserTests` → FAIL（类型不存在）。

- [ ] **Step 2: 实现**（逐字符扫描：先切 tag/`*`/`+`，再切分隔空白，遇到 `"` 进入 quoted-string 模式，遇到 `{`..`}` 解析长度并挂起等字面量；`parenthesized` 按深度计数切分）。
- [ ] **Step 3: Run 测试 → PASS。**
- [ ] **Step 4: Commit** `git add -A && git commit -m "feat(imap): IMAPResponseParser（tagged/untagged/literal/quoted-string）"`

---

### Task 4: `StreamTransport` + `IMAPConnection`（分帧 + TLS + 命令串行）

**Files:**
- Create: `Sources/LagoonServer/Networking/StreamTransport.swift`、`Networking/NIOSSLStreamTransport.swift`、`IMAP/IMAPConnection.swift`
- Test: `Tests/LagoonServerTests/ScriptedTransport.swift`、`Tests/LagoonServerTests/IMAPConnectionTests.swift`

**Interfaces:**
- Produces:

```swift
/// 行式字节流（IMAP/SMTP 共用）。测试注入脚本替身，生产用 NIOSSL。
public protocol StreamTransport: Sendable {
    func connect(host: String, port: Int) async throws
    func write(_ bytes: Data) async throws
    /// 读一行，去掉结尾 CRLF；连接关闭时抛 StreamTransportError.closed。
    func readLine() async throws -> String
    /// 精确读 count 字节（字面量用）。
    func readExactly(_ count: Int) async throws -> Data
    func close() async
}
public enum StreamTransportError: Error, Equatable { case closed, notConnected, timedOut }

public actor IMAPConnection {
    public init(transport: any StreamTransport, logger: Logger)
    public func connect(host: String, port: Int) async throws          // TCP+TLS+greeting
    /// 发送命令并收集到该 tag 的完整响应（自动处理 `{N}` 字面量、continuation）。
    public func execute(_ command: String) async throws -> [IMAPResponse]
    /// 进入/退出 IDLE（waitUpTo 内等待 untagged 事件；超时自身发 DONE）。
    public func idle(waitUpTo: Duration) async throws -> [IMAPResponse]
    public func close() async
}
```
`execute` 生成 tag `A%04d` 自增；写 `\(tag) \(command)\r\n`；读到 `.tagged(tag, .bad/.no)` 抛 `MailError.protocolError(...)`（认证相关 NO 文本含 `AUTHENTICATIONFAILED` 时抛 `.authFailed`）；读到 `+ ` continuation 且有未完成字面量时，补写剩余命令或裸 CRLF。

- [ ] **Step 1: 写 `ScriptedTransport`**（actor；`enqueue(_ line: String)` / `enqueueLiteral(_ data: Data)`；记录 `writes: [Data]`；`readLine` 依脚本出队，耗尽后按 `closeAfterScript` 抛 `.closed` 或阻塞到 `enqueue`）。
- [ ] **Step 2: 写失败测试**（`IMAPConnectionTests`）：(a) execute 精确写出 `A0001 CAPABILITY\r\n` 并解析 tagged OK；(b) 字面量：脚本给 `* 1 FETCH (BODY[TEXT] {5}` + 5 字节 + `)`，断言 `literal == Data("hello")`；(c) `NO [AUTHENTICATIONFAILED]` → `MailError.authFailed`；(d) `BAD` → `.protocolError`；(e) `readExactly` 超时 → `.timedOut`（用 100ms 超时）。
- [ ] **Step 3: 实现 `IMAPConnection`**（`withThrowingTaskGroup`/`Task` + `Task.sleep` 做读超时；所有 `execute/idle` 串行由 actor 隔离天然保证）。
- [ ] **Step 4: 实现 `NIOSSLStreamTransport`**

关键约束（写在代码里）：
```swift
// 仅 993/465；implicit TLS；完整证书校验（默认 TLSConfiguration.forClient()）。
let tls = TLSConfiguration.forClient()
let bootstrap = ClientBootstrap(group: group)
    .connectTimeout(.seconds(10))
guard port == 993 || port == 465 else { throw MailError.notConfigured("port \(port) not allowed") }
// SNI: tlsServerHostname = host；握手成功后 handler 维护行缓冲（ByteToMessageDecoder）
```
按行切分（`\r\n`）与 `readExactly` 通过 `NIOAsyncChannel<ByteBuffer, Never>` + `AsyncSequence` 消费；实现细节自由，但**必须**：连超时 10s、行/字面量读超时 30s（IDLE 用调用方传入的时长）、关闭时 `channel.close()`。

Run: `swift test --filter IMAPConnectionTests` → PASS。

- [ ] **Step 5: Commit** `git add -A && git commit -m "feat(imap): StreamTransport + IMAPConnection（NIO/NIOSSL 993，命令串行，字面量分帧）"`

---

### Task 5: `IMAPClient`（语义命令层）

**Files:**
- Create: `Sources/LagoonServer/IMAP/IMAPClient.swift`
- Test: `Tests/LagoonServerTests/IMAPClientTests.swift`

**Interfaces:**
- Consumes: `IMAPConnection.execute/idle/connect`。
- Produces:

```swift
public struct IMAPMailbox: Equatable, Sendable {
    public var name: String            // 服务端原样（含 "Sent Messages" 这类）
    public var attributes: [String]    // ["\\HasNoChildren", "\\Archive", ...]
}
public struct IMAPSelected: Equatable, Sendable {
    public var exists: Int
    public var uidValidity: Int64
    public var uidNext: Int64
}
public struct IMAPFetchedHeader: Equatable, Sendable {
    public var uid: Int64
    public var flags: [String]
    public var internalDate: Date?
    public var rawHeaders: [String: String]   // 键统一小写
}
public struct IMAPFetchedText: Equatable, Sendable {
    public var uid: Int64
    public var snippet: Data?          // BODY.PEEK[TEXT]<0.256> 的原始字节（可能编码）
}

public actor IMAPClient {
    public init(connection: IMAPConnection, logger: Logger)
    public func connect(host: String, port: Int) async throws                       // 含 greeting
    public func capability() async throws -> Set<String>
    public func login(username: String, authCode: String) async throws              // AUTHENTICATE PLAIN → 回退 LOGIN
    public func sendID() async throws                                               // 能力含 ID 时调用
    public func listMailboxes() async throws -> [IMAPMailbox]
    public func select(_ mailbox: String) async throws -> IMAPSelected
    /// fromUid..* 的头；fields 默认 [FROM,SUBJECT,DATE,MESSAGE-ID,IN-REPLY-TO,REFERENCES,LIST-UNSUBSCRIBE]
    public func fetchHeaders(fromUid: Int64, fields: [String]) async throws -> [IMAPFetchedHeader]
    /// last Uid 区间 flags 回扫（用于已读态）
    public func fetchFlags(fromUid: Int64, toUid: Int64) async throws -> [(uid: Int64, flags: [String])]
    public func fetchTextSnippet(uid: Int64, octets: Int = 256) async throws -> [IMAPFetchedText]
    public func fetchFullBody(uid: Int64) async throws -> Data                      // 空结果 → MailError.messageGone
    public func store(uid: Int64, add: [String], remove: [String]) async throws
    public func move(uid: Int64, to mailbox: String) async throws                   // 无 MOVE 能力时抛 .protocolError
    public func copy(uid: Int64, to mailbox: String) async throws
    public func createMailbox(_ name: String) async throws
    public func logout() async
}
```

- [ ] **Step 1: 写失败测试**（脚本化一份真实 QQ 会话 transcript；用例：AUTHENTICATE PLAIN 失败回退 LOGIN；`LIST` 解析出 `\Archive`；`SELECT` 解析 `UIDVALIDITY 42 / UIDNEXT 100 / 12 EXISTS`；`fetchHeaders` 发出 `UID FETCH 13:* (UID FLAGS INTERNALDATE BODY.PEEK[HEADER.FIELDS (FROM SUBJECT...)])` 且断言**命令里不含裸 `BODY[`**；`fetchFullBody` 空结果 → `.messageGone`；`move` 在能力缺 MOVE 时（客户端记录的能力集合）→ `.protocolError`）。
- [ ] **Step 2: 实现**（`capability()` 结果缓存进 actor 属性 `capabilities: Set<String>`；`login` 用 `AUTHENTICATE PLAIN` + SASL-IR（`AUTHENTICATE PLAIN <base64>`）；header 解析：把 `BODY[HEADER.FIELDS ...]` 字面量按 `\r\n` 切、`Name: value` 折叠续行）。
- [ ] **Step 3: Run → PASS。**
- [ ] **Step 4: Commit** `git add -A && git commit -m "feat(imap): IMAPClient（LOGIN/ID/LIST/SELECT/FETCH/IDLE/MOVE 语义层）"`

---

### Task 6: `MIMEParser` + `HTMLText` 抽取

**Files:**
- Create: `Sources/LagoonServer/IMAP/MIMEParser.swift`、`Sources/LagoonServer/Mail/HTMLText.swift`
- Create: `Tests/LagoonServerTests/Fixtures/mime/rfc2047-gbk.eml`、`multipart-alternative.eml`、`base64-qp.eml`、`nested-mixed.eml`（真实感 fixture，含 CRLF、折行头、GBK base64 主题）
- Modify: `Sources/LagoonServer/Gmail/GmailBodyExtractor.swift`（把 `stripHTML/decodeHTMLEntities/collapseWhitespace` 三个函数搬去 `HTMLText`，原处改为转发调用）
- Test: `Tests/LagoonServerTests/MIMEParserTests.swift`

**Interfaces:**
- Produces:

```swift
public enum HTMLText {
    public static func strip(_ html: String) -> String        // 原 GmailBodyExtractor.stripHTML
    public static func decodeEntities(_ value: String) -> String
    public static func collapseWhitespace(_ value: String) -> String
}

public enum MIMEParser {
    /// RFC5322 头解码（RFC2047 B/Q、GB 系字符集、折行续行）。键统一小写。
    public static func decodeHeaders(_ raw: Data) -> [String: String]
    /// 从完整 RFC822 消息抽出可读纯文本正文（永不抛错，最差返回 ""）。
    public static func plainText(from message: Data) -> String
    /// RFC2047 单词解码（供 IMAPClient 头部复用）。
    public static func decodeRFC2047(_ value: String) -> String
    static func decodeQuotedPrintable(_ data: Data) -> Data
    static func decodeCharset(_ data: Data, charset: String?) -> String   // gb2312/gbk/gb18030/utf-8/iso-8859-1
}
```
`decodeCharset` 用 `CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x0632))`（GB18030，覆盖 GBK/GB2312 子集）与 `String.Encoding(rawValue:)` 组合，失败回退 `.isoLatin1`，再失败用 `String(decoding:as:UTF8.self)`。

- [ ] **Step 1: 写 fixture 与失败测试**

用例（每个 fixture 一条）：
```swift
func test_rfc2047_gbkSubject_decodesToChinese() throws {
    let raw = try fixture("rfc2047-gbk")
    let headers = MIMEParser.decodeHeaders(raw)
    XCTAssertEqual(headers["subject"], "项目周报：本周进度")
    XCTAssertEqual(headers["from"], "张三 <zhangsan@qq.com>")
}
func test_multipartAlternative_prefersPlainTextOverHTML() throws {
    let text = MIMEParser.plainText(from: try fixture("multipart-alternative"))
    XCTAssertTrue(text.contains("纯文本版本"))
    XCTAssertFalse(text.contains("<p>"))
}
func test_multipartAlternative_htmlOnly_fallsBackToStrippedText() throws { /* 断言 HTML 被 strip 成纯文本 */}
func test_base64QuotedPrintable_decodesBothParts() throws
func test_nestedMixed_findsInnermostText() throws
func test_malformed_truncatedMime_returnsPartialTextWithoutThrowing() throws
func test_charset_gb2312_mapsToGB18030Decoder() {
    XCTAssertEqual(MIMEParser.decodeCharset(Data([0xD6, 0xD0, 0xCE, 0xC4]), charset: "gb2312"), "中文")
}
```
Run: `swift test --filter MIMEParserTests` → FAIL。

- [ ] **Step 2: 实现**（结构：先按空行切头/体 → 头解码；体按 `Content-Type` 的 `boundary` 递归；`Content-Transfer-Encoding` 分支 base64/QP/identity；叶子取 `text/plain` 优先，其次 `text/html` → `HTMLText.strip`；`message/rfc822` 递归一层；解析失败路径全部 `return ""` 或部分文本，不抛）。
- [ ] **Step 3: 搬迁 `HTMLText`** 并让 `GmailBodyExtractor` 转发；Run `swift test --filter 'MIMEParserTests|GmailBodyExtractorTests'` → 全 PASS（证明搬迁无回归）。
- [ ] **Step 4: Commit** `git add -A && git commit -m "feat(imap): MIMEParser（RFC2047/multipart/base64/QP/GB 字符集）+ HTMLText 抽取"`

---

### Task 7: `IMAPProvider`（MailProvider 实现）

**Files:**
- Create: `Sources/LagoonServer/IMAP/IMAPProvider.swift`
- Modify: `Sources/LagoonServer/Mail/MailProviderFactory.swift`（接上 `.qq`）
- Test: `Tests/LagoonServerTests/IMAPProviderTests.swift`（用 `ScriptedTransport` 驱动 `IMAPClient`）

**Interfaces:**
- Consumes: Task 3–6 全部；`CredentialVault.read`；`ProviderPresets.imap(for:)`。
- Produces: `IMAPProvider(account:db:logger:transportFactory:)`，`transportFactory: @Sendable () -> any StreamTransport`（测试注入 `ScriptedTransport`）。

- [ ] **Step 1: 写失败测试**（关键行为，脚本 transcript 驱动）：
  - (a) `probe()`：连 → 认证 → `LIST` → `SELECT INBOX` 全 OK 不抛；认证 NO → `.authFailed`；
  - (b) `capabilities()`：`LIST` 无 `\Archive` 但 `CREATE "Archive"` 成功 → `archiveFolder == true` 且 `syncState.archiveFolder == "Archive"`；`CREATE` 也 NO → `false`；
  - (c) `pullChanges` 首轮：无 `lastUid` → 发出 `UID FETCH <max(1,uidNext-500)>:*`，解析出 2 封 → `upserts.count == 2`、`cursor.lastUid == 最大值`、`isRead` 来自 `\Seen`；
  - (d) `pullChanges` 二轮：`lastUid=5` → 命令为 `UID FETCH 6:*`；无新邮件 → `upserts == []` 且游标不变；
  - (e) `UIDVALIDITY` 变化 → `resetRequired == true`；
  - (f) `archive(uid:)` → 发出 `UID MOVE 7 "Archive"`；`unarchive` → `UID MOVE 7 "INBOX"`；
  - (g) `setRead(uid:true)` → `UID STORE 7 +FLAGS (\Seen)`；
  - (h) `fetchBody` 空 → `.messageGone`。
- [ ] **Step 2: 实现**

要点：单连接惰性建立（`ensureConnected()`：复用仍活连接，断开则重连；每次 `execute` 失败时标记连接失效）；`pullChanges` 流程严格按 spec §3.2 五步；`threadId` 取 `references` 首项 → `messageIdHeader` → `"uid:\(uid)"`；`snippet` 仅在 `capabilities.serverSnippet` 且返回非 base64/QP 时截取（判定：字节在 0x20–0x7E/UTF-8 可解且无 `=` 行尾特征）；`from` 用 `MIMEParser.decodeRFC2047` + 复用 `GmailProvider.parseFromHeader` 的等价实现（把它提为 `Mail/FromHeader.swift` 的 `static func parse(_:) -> (String, String?)`，GmailProvider 与 IMAPProvider 共用，`FromHeaderTests` 改指新位置）。
- [ ] **Step 3: Run `swift test --filter IMAPProviderTests` → PASS。**
- [ ] **Step 4: Commit** `git add -A && git commit -m "feat(imap): IMAPProvider（UIDNEXT 增量 / IDLE / 文件夹角色 / 归档 MOVE）"`

---

### Task 8: 账户写入路径 + 服务端 provider 分发 + 活跃账号

**Files:**
- Modify: `Sources/LagoonServer/Routes/AccountsRoutes.swift`、`MessageRoutes.swift`、`ActionsRoutes.swift`、`DraftRoutes.swift`、`OAuthRoutes.swift`、`App.swift`
- Modify: `Sources/LagoonKit/ConnectedAccount.swift`（若 Task 1 未含默认值处理）
- Test: `Tests/LagoonServerTests/RouteTests.swift`（追加）、`Tests/LagoonServerTests/AccountStoreTests.swift`（追加 active/health）

**Interfaces:**
- Consumes: `MailProviderFactory`、`SyncEngine`、`CredentialVault`、`AccountStore.setActive/delete/reconcileActive`。
- Produces（HTTP 契约）:
  - `POST /api/accounts/imap` → 201 `ConnectedAccount`（`id` 为 DB 中的权威行 id）；400 `missing-field`、401 `imap-auth-failed`、502 `imap-unreachable`、409 `account-exists`（已存在且健康 → 409 提示切换；已存在但不健康 → 用新授权码就地重认证并返回同一 id，probe 失败则 401/502 且原行不动）
  - `GET /api/accounts` → `[ConnectedAccount]`（含 isActive/syncHealth/capabilities）
  - `POST /api/accounts/{id}/activate` → 204 `{ok}`；404 `unknown-account`
  - `DELETE /api/accounts/{id}` → 204
  - `GET /api/messages/{remoteId}/body` → 410 `message-gone` / 401 `provider-auth-failed` / 502 `provider-unreachable`

- [ ] **Step 1: 写失败测试**（RouteTests 追加）：
  - `POST /api/accounts/imap` 缺字段 → 400；用注入的假 provider（工厂注入点：`AccountsRoutes.register(on:db:logger:makeProvider:)`，默认走 `MailProviderFactory`）stub `probe` 抛 `.authFailed` → 401；成功 → 201 + `isActive == true` + `GET /api/accounts` 里 capabilities 回显；
  - `POST /api/accounts/{id}/activate` 切换后 `AccountStore.active` 指向新账号且旧账号 `isActive == false`；
  - `DELETE /api/accounts/{id}` → 204，随后 `GET /api/accounts` 不含该 id；
  - body 路由：假 provider 抛 `.messageGone` → 410；正常 → 200 `{"text":...,"isHTML":false}`（沿用现有 `MessageBody` 形状）。
- [ ] **Step 2: 实现 AccountsRoutes**（新增三端点；IMAP 接入流程 = 构造 `Account(id: UUID(), provider: .qq, oauthUser: email, email: email, credentials: nil, isActive: false)` → `IMAPProvider.probe()` → 通过后 `CredentialVault.seal(.imap(username:email, authCode: code))` → `AccountStore.upsert` → `setActive` → `updateCapabilities`（probe 阶段解析出的能力 + archiveFolder 名写入 sync_state）→ 201。**授权码只出现在请求体与 `CredentialVault` 之间，不写日志**）。
- [ ] **Step 3: 实现路由分发**（body/read/archive/unsubscribe 的远端写、undo 的 unarchive 全部改为 `MailProviderFactory.make(account:…)` 后调用协议方法；`archive` 前检查 `account.capabilities.archiveFolder == false` → 409 `archive-unavailable` 且不改本地；`DraftRoutes.choose` 中 `pushToGmail` 仅在 `account.provider == .gmail` 时执行）。
- [ ] **Step 4: `App.swift` 注册新路由 + `SyncEngine.start()` 已在 Task 2 接好；补 `reconcileActive` 启动调用与 `DELETE` 后的引擎切换（`SyncEngine.accountChanged()`：取消当前循环、下轮重新取活跃账号）。**
- [ ] **Step 5: Run `bash scripts/run-all-tests.sh` → 全绿。**
- [ ] **Step 6: Commit** `git add -A && git commit -m "feat(imap): QQ 接入端点 + activate/DELETE + 路由 provider 分发（body/read/archive/undo）"`

---

### Task 9: 客户端接入与账号目录

**Files:**
- Create: `Sources/Lagoon/Views/ConnectView.swift`（替代并删除 `ConnectGmailView.swift`）、`Sources/Lagoon/Models/DirectoryStore.swift`
- Modify: `Sources/Lagoon/Views/RootView.swift`、`Sources/Lagoon/Services/APIClient.swift`、`Sources/Lagoon/Localization/L10n.swift`（新增文案）
- Test: `Tests/LagoonTests/APIClientTests.swift`（追加）

**Interfaces:**
- Produces（APIClient 新方法）:
```swift
public func connectQQ(email: String, authCode: String) async throws -> ConnectedAccount
public func activateAccount(id: UUID) async throws
public func deleteAccount(id: UUID) async throws
```
- `DirectoryStore`（`@MainActor final class DirectoryStore: ObservableObject`）：`@Published var accounts: [ConnectedAccount]`、`var active: ConnectedAccount?`、`func refresh() async`（30s 轮询由 RootView `.task` 驱动）。

- [ ] **Step 1: APIClient 追加方法 + 测试**（`APIClientTests` 用 `URLProtocolStub` 断言 `POST /api/accounts/imap` 的 JSON body 含 `provider/email/authCode`、路径与解码；401 时抛 `APIError.badStatus`）。
- [ ] **Step 2: `DirectoryStore` + `RootView` 账号菜单**（工具栏加 `Menu`：每行显示 email + 状态点（🟢/🟡/🔴 用 `Circle().fill`），点击非活跃项 → `activateAccount` + `refresh`；菜单底部“添加账号” → `accounts.clear()` 回到 ConnectView；`.task` 每 30s `refresh()`）。
- [ ] **Step 3: `ConnectView`**（顶部 `Picker`（segmented）：Gmail / QQ；Gmail 分支 = 原 ConnectGmailView 逻辑原样搬入；QQ 分支 = `TextField`(邮箱) + `SecureField`(授权码) + 提交按钮 + 获取授权码指引文案；提交调用 `connectQQ`，成功后 `accounts.set(accountId:)`；错误按 401/502 映射文案）。
- [ ] **Step 4: 健康横幅**（RootView 顶部：`active?.syncHealth.status != .ok` 时显示一行 banner，`needsReconnect` → 红 + “重新连接”按钮直达 ConnectView；`degraded`/`error` → 黄 + lastError 摘要）。
- [ ] **Step 5: 文案**（`L10n` 增 `connectQQTitle/qqEmailPlaceholder/qqAuthCodePlaceholder/qqHelp/activate/addAccount/reconnect/healthDegraded/healthNeedsReconnect/archiveUnavailable` 的中英双语；`LocalizationTests` 断言双语键齐全）。
- [ ] **Step 6: Run `swift test --filter 'APIClientTests|LocalizationTests'` → PASS；`swift build` 通过。**
- [ ] **Step 7: Commit** `git add -A && git commit -m "feat(client): ConnectView（Gmail/QQ 分段）+ 账号目录/切换菜单 + 同步健康横幅"`

---

### Task 10: `MIMEBuilder` + `SMTPClient`

**Files:**
- Create: `Sources/LagoonServer/IMAP/MIMEBuilder.swift`、`Sources/LagoonServer/IMAP/SMTPClient.swift`
- Test: `Tests/LagoonServerTests/MIMEBuilderTests.swift`、`SMTPClientTests.swift`

**Interfaces:**
- Consumes: `StreamTransport`（Task 4）。
- Produces:
```swift
public enum MIMEBuilder {
    /// 生成 RFC5322 回复消息（CRLF 行、base64 正文、RFC2047 主题）。
    public static func reply(_ outbound: OutboundMessage, messageId: String) -> Data
}
public actor SMTPClient {
    public init(transport: any StreamTransport, logger: Logger)
    public func send(_ outbound: OutboundMessage, host: String, port: Int,
                     username: String, authCode: String) async throws -> String?  // 返回 Message-ID
}
```
- [ ] **Step 1: 写失败测试**：`MIMEBuilderTests`（非 ASCII 主题 → `=?UTF-8?B?…?=`；`Re:` 前缀去重；`In-Reply-To`/`References` 透传；正文 base64 且行宽 ≤ 76；`Date`/`Message-ID` 存在且格式合法）；`SMTPClientTests`（脚本化 220/235/250/354/250/221：断言命令序列 `EHLO→AUTH PLAIN <b64>→MAIL FROM→RCPT TO→DATA→<body>→.→QUIT`；535 → `.authFailed`；DATA 阶段 554 → `.protocolError` 不重试；`DATA` 前 421 → 重试一次后仍失败 → `.unreachable`）。
- [ ] **Step 2: 实现**（`AUTH PLAIN` 用 `base64(\0username\0authCode)`；`Content-Type: text/plain; charset=UTF-8` + `Content-Transfer-Encoding: base64`；`<CRLF>.<CRLF>` 结束；正文中的行首 `.` 做 dot-stuffing）。
- [ ] **Step 3: Run `swift test --filter 'MIMEBuilderTests|SMTPClientTests'` → PASS。**
- [ ] **Step 4: Commit** `git add -A && git commit -m "feat(imap): MIMEBuilder + SMTPClient（465 implicit TLS，AUTH PLAIN，DATA 前重试一次）"`

---

### Task 11: 发送端点 + ComposerSheet（服务端 + 客户端闭环）

**Files:**
- Modify: `Sources/LagoonServer/Routes/MessageRoutes.swift`（新增 send 路由 + 分发）、`Sources/LagoonKit/Action.swift`（`ActionKind.send`）、`Sources/LagoonServer/Storage/AIActionStore.swift`（kind 支持）、`Sources/LagoonServer/IMAP/IMAPProvider.swift`（`send` 实现：SMTPClient + preset）
- Create: `Sources/Lagoon/Views/ComposerSheet.swift`
- Modify: `Sources/Lagoon/Views/MessageDetailView.swift`（回复按钮）、`Sources/Lagoon/Services/APIClient.swift` + `ClientResponses.swift`（`SendResponse`）
- Test: `Tests/LagoonServerTests/RouteTests.swift`（send 用例）、`Tests/LagoonTests/APIClientTests.swift`（send 用例）

**Interfaces:**
- Produces:
```swift
// 服务端
public struct SendResponse: Codable, Sendable { public let ok: Bool; public let providerMessageId: String? }
// POST /api/messages/{remoteId}/send?accountId=  body {"body":"..."}
//   200 SendResponse | 400 malformed | 404 unknown-message | 401 smtp-auth-failed
//   | 502 smtp-send-failed | 503 provider-unavailable
// 客户端
public func sendReply(remoteId: String, accountId: UUID, body: String) async throws -> SendResponse
```
- [ ] **Step 1: 写失败测试**（假 provider 的 `send` 被调用一次且 `OutboundMessage.to/subject/inReplyTo` 来自本地 `message_headers`；成功后 `ai_actions` 出现 `kind=send` 行且 undo 接口对该行返回 400 `not-undoable`；SMTP 失败 → 502 且**不**写审计行……审计行记录尝试还是成功？**决定：仅在成功时写审计行**，失败只在日志）。
- [ ] **Step 2: 实现服务端**（`MessageStore.find(remoteId:)` 取 subject/from/messageIdHeader/inReplyTo/references → `OutboundMessage(fromEmail: account.email, fromName: nil, to: header.fromAddress, subject: "Re: …"（去重）, body: …, inReplyTo: …, references: …)` → `provider.send` → 审计行 → 200）。
- [ ] **Step 3: `IMAPProvider.send`**（`CredentialVault.read` → `.imap(username, authCode)`；`SMTPClient.send(outbound, host: preset.smtpHost, port: 465, username:, authCode:)`；返回 `<!…@lagoon>` 本地生成的 Message-ID）。
- [ ] **Step 4: `GmailProvider.send`**（`MIMEBuilder.reply` → base64url → `GmailClient.sendMessage`）。
- [ ] **Step 5: 客户端 `ComposerSheet`**（`To`/`Subject` 只读回显，`TextEditor` 正文，`⌘↩` 发送（`keyboardShortcut(.return, modifiers: .command)`），发送中禁用、失败保留正文 + 红字，成功 `dismiss` + toast）；`MessageDetailView` 工具栏加“回复”按钮打开 sheet（对 `capabilities` 无要求——发送对所有 provider 可用）。
- [ ] **Step 6: Run `swift test --filter 'RouteTests|APIClientTests'` → PASS；`swift build` 通过。**
- [ ] **Step 7: Commit** `git add -A && git commit -m "feat(send): POST /api/messages/{remoteId}/send（SMTP/ Gmail 分发）+ ComposerSheet ⌘↩"`

---

### Task 12: 归档能力门控（客户端）+ 撤销回归 + 文档 + 冒烟

**Files:**
- Modify: `Sources/Lagoon/Views/MessageDetailView.swift`、`BriefingFeedView.swift`（归档按钮按 `DirectoryStore.active?.capabilities.archiveFolder` 禁用 + 说明 tooltip）
- Create: `docs/superpowers/m1-5-smoke.md`
- Modify: `docs/使用说明.md`（QQ 接入步骤、008 破坏性变更、排障条目）、`README.md`（能力矩阵）

- [ ] **Step 1: 客户端归档门控**（`archiveUnavailable` 文案；禁用态 `.help(...)`；`undueAction` 不门控）。
- [ ] **Step 2: 写 `m1-5-smoke.md`**（格式对齐 `m0-smoke.md`）：已自动验证表（跑 `scripts/run-all-tests.sh` 填结果）、NOT verified（真实 QQ 账号清单：授权码接入 / 收件箱同步 / GBK 正文 / 归档文件夹实测结果 / SMTP 已发送是否自动保存 / IDLE 延迟）、14 天浸泡记录表（每日：新邮件同步、回复发送、归档撤销）。
- [ ] **Step 3: 更新 `使用说明.md`**：新增「QQ 邮箱接入（5 分钟）」章节（获取授权码路径、客户端操作步骤）、缓存破坏性变更条目（旧 Gmail 需重连）、排障新增（授权码错误 / 网络不可达 / 归档不可用 / 同步状态点含义）。
- [ ] **Step 4: 全量验证**

Run:
```bash
bash scripts/run-all-tests.sh
swift build 2>&1 | tail -3
```
Expected: `ALL CHECKS PASSED`；build 无 warning 新增（至少无 error）。

- [ ] **Step 5: 真实账号冒烟（需要创始人操作，记录进 m1-5-smoke.md）**：启动 server + client → QQ 接入 → 观察 `GET /api/accounts` 的 `syncHealth.status == "ok"` 与 `lastSyncAt` → 打开一封 GBK 邮件 → 归档 + ⌘Z 撤销 → 回复发送 → QQ Web 核对已发送 → 拔网 60s 观察 degraded/恢复。
- [ ] **Step 6: Commit** `git add -A && git commit -m "docs(imap): QQ 使用说明 + M1.5 冒烟清单；feat(client): 归档能力门控"`

---

## Self-Review

- **Spec coverage:** §1.2 协议 → Task 2；§1.3 布局 → File Structure + Tasks 2/4/5/6/7/10；§2.1 迁移 → Task 1 Step 1；§2.2 remoteId → Task 1 Step 3；§2.3 凭据 blob → Task 1 Step 6；§2.4 游标契约 → Task 2 Step 3；§2.5 单活跃 → Task 1 Step 7 + Task 8；§2.6 破坏性声明 → Task 12 Step 3；§3.1 生命周期 → Task 5；§3.2 增量算法 → Task 7；§3.3 IDLE → Task 4/5/7；§3.4 退避状态机 → Task 2 Step 3；§3.5 健康上浮 → Task 1（列）+ Task 8（API）+ Task 9（UI）；§3.6 MIME → Task 6；§3.7 正文 → Task 8 Step 3；§4.1 SMTP → Task 10；§4.2 MIMEBuilder → Task 10；§4.3 归档/撤销 → Task 7/8/12；§4.4 API 表 → Task 8（+Task 11 send）；§4.5 客户端 → Task 9/11/12；§4.6 接入流程 → Task 8 Step 2；§5.1 错误表 → 各任务错误分支 + Task 8 映射；§5.2 安全 → Global Constraints + Task 4/10 端口限制；§5.3 测试 6 项 → Tasks 3–11 + Task 12 Step 4；§5.4 DoD → Task 12。
- **Placeholder scan:** 无 TBD/TODO；所有代码步骤给出确切函数名、SQL、命令与断言。
- **Type consistency:** `MailProviderKind`（枚举）与 `MailProvider`（协议）在 Task 1/2 中定型后全计划引用一致；`MailSyncState`/`MailCapabilities`/`SyncHealth` 字段在 Task 1 定义、Task 2/7/8 使用；`remoteId` 唯一命名（无遗留 `gmailId`）；`StreamTransport` 在 Task 4 定义、Task 10 复用。
