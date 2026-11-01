# R1 报告：Rust 只读后端（lagoon-api）与 v3 的逐字段一致性

> 交付物：`v4/crates/lagoon-api`（+ `v4/crates/Cargo.toml` workspace）
> 结论：**能起、能读、形状对**。`cargo build` / `cargo test` 全绿；18 条 golden fixtures 回放 18/18；
> 与真 v3 边车在同一份合成库上逐字段 diff **18/18 一致**；五组端点各有 curl 转录（见 §5）。

## 1. 做了什么

- 新 crate `v4/crates/lagoon-api`（axum 0.8.9 + tokio + rusqlite 0.41 bundled + aes-gcm **=0.10.3** + sha2/subtle），**只读**。
- 5 组端点：`/healthz`、`/api/accounts`、`/api/messages`（含 7 个 query 参数）、`/api/messages/{remoteId}/body`、`/api/folder-counts`。
- 传输层照抄 v3：Host 守卫 → Bearer 鉴权（SHA-256 定长比较）→ 路由；未知路由**空体 404**。
- 存储层照抄 v3 的 SQL（`filterSQL` / `recent` / `count` / `unreadCount` / `pinnedCount` / `sentCount` / `deletedCount` / `BodyStore.get` / `listStackRule`）。
- 密文：`lgb1:` + base64(12B nonce ‖ ct ‖ 16B tag)，AES-256-GCM 无 AAD —— 与 v3 `BodyCipher` 同一格式；测试用 **CryptoKit 生成的密文**当向量。
- 只读保证：`SQLITE_OPEN_READ_ONLY` + `PRAGMA query_only`；启动期 schema 探针，缺 v3.2.0 已知迁移就**拒绝启动**。
- 未做（时间盒内明确不做）：写库、迁移、IMAP、SMTP、AI、其余 51 个端点。

## 2. 验收 1：构建与测试

```text
$ cd v4/crates && cargo build --offline
    Finished `dev` profile [unoptimized + debuginfo] target(s)
    0 warnings

$ cargo test --offline
running 26 tests   (src 内单测)
test result: ok. 26 passed; 0 failed
running 1 test     (tests/contract_replay.rs)
test r1_endpoints_match_the_golden_fixtures ... ok
running 1 test     (tests/dev_store.rs)
test serves_the_v3_sidecar_store_read_only ... ok
running 7 tests    (tests/read_paths.rs)
test result: ok. 7 passed; 0 failed
```

共 **35 条**。其中：

| 测试 | 覆盖点 |
|---|---|
| `crypto::tests`（6） | CryptoKit 密文 3 例可解、篡改/错 key/坏信封被拒、每次 seal 新 nonce、Unicode 往返 |
| `timefmt::tests`（5） | `yyyy-MM-dd HH:mm:ss.SSS` ↔ ISO-8601 秒级**截断**、毫秒仅用于排序、ISO 回退、闰日 |
| `uuid::tests`（3） | 只认 Foundation 认可的 8-4-4-4-12；32 位无连字符/花括号/urn/尾空格全部拒绝 |
| `config::tests`（6） | `--db` > `LAGOON_DB_PATH` > `LAGOON_V4_DATA_DIR`；未知参数拒绝启动；非回环无 token 拒绝；通配绑定不扩白名单；端口回退；Host 归一化 |
| `http::query` / `http::guard`（5） | form 解码、`%zz` 原样保留、重复 key 取最后、`//healthz` 必须被门禁、错 token 与无 token 同一 401 |
| `tests/contract_replay.rs` | 18 条 golden fixtures，真实 HTTP，逐字段 diff（含 Content-Type / body_kind） |
| `tests/read_paths.rs`（7） | 缓存正文（Swift 封存）→ 200；摘要解密进列表；`/body` 400/404/503 矩阵；聚合规则 keyword 过滤 + unknown-stack 404 + 非法 stackId 被忽略；`provider='gmail'` → 500；只读句柄写失败/缺库/非 Lagoon 库/旧库全部拒绝；Host 与鉴权 |
| `tests/dev_store.rs` | 打开 v3 边车真实迁移过的 `v4/.dev/data/lagoon.sqlite`（只读），起服务并断言 5 组端点；迁移链含 `lagoon-v10` |

## 3. 验收 2：18 条 golden fixtures 回放（Rust 端）

`tests/contract_replay.rs` 直接读 `v4/tests/contract/fixtures/fixtures.json`（v3 真实响应的抓取件），
只回放 R1 的 18 条；规范化规则与 `v4/scripts/contract-check.sh` 完全一致（只按 key 名替换 wall-clock 时间戳）：

```text
r1_endpoints_match_the_golden_fixtures ... ok
18/18 一致
```

覆盖：healthz、accounts.list、auth.missing-token、auth.bad-token、host.forbidden、messages.list、
messages.list.{limit,archived,pinned,unread,sender,malformed-account,missing-account}、folder-counts、
body.provider-unconfigured、unknown-account、unknown-route、unknown-route.v2。

## 4. 验收 3：与真 v3 边车逐字段 diff（18/18）

`bash v4/crates/lagoon-api/scripts/diff-vs-v3.sh`：三阶段 —— ① v3 迁移出 schema；② `harness.py seed` 造合成库，
再让 v3 跑一轮同步把账号停在 `needsReconnect`（seed 的凭据是 48 个 0 字节，打不开），**快照成两份相同的库**；
③ 一份给 v3、一份给 Rust，两个进程对同一份数据作答，逐请求 diff。

```text
== phase A: apply the v3 migrations to a throwaway store
   migrated to: lagoon-v1,lagoon-v2,lagoon-v3,lagoon-v4,lagoon-v5,lagoon-v5b,lagoon-v6,lagoon-v7,lagoon-v8,lagoon-v9,lagoon-v10
== phase B: seed it, let v3 park its sync loop, snapshot the settled store
seed: {"accounts": 1, "message_headers": 3, "message_pins": 1}
   sync loop parked at needsReconnect; payload stable
== phase C: v3 on one copy, lagoon-api on the other

fixture                                v3     rust   verdict
healthz                                200    200    SAME
accounts.list                          200    200    SAME
auth.missing-token                     401    401    SAME
auth.bad-token                         401    401    SAME
host.forbidden                         403    403    SAME
messages.list                          200    200    SAME
messages.list.limit                    200    200    SAME
messages.list.archived                 200    200    SAME
messages.list.pinned                   200    200    SAME
messages.list.unread                   200    200    SAME
messages.list.sender                   200    200    SAME
messages.list.malformed-account        400    400    SAME
messages.list.missing-account          400    400    SAME
folder-counts                          200    200    SAME
body.provider-unconfigured             503    503    SAME
unknown-account                        404    404    SAME
unknown-route                          404    404    SAME
unknown-route.v2                       404    404    SAME

18/18 fixtures identical (timestamps normalised)
```

> 第一次跑的时候 `accounts.list` 是 DIFF：v3 的同步循环在我们取快照**之后**又写了一次健康状态，两个进程读的就不是同一份数据了。
> 改为“先让 v3 停在 `needsReconnect`，再快照两份”之后 18/18 全绿。这类差异说明的是快照时机，不是实现。

## 5. 验收 4：五组端点的 curl 转录（同一份库，v3 vs Rust）

> 说明：`fromName` 是真人名，终端转录里被工具脱敏成占位符；两边**同一字段同一值**。
> 两边的 JSON key 顺序不同是 v3 的已知现象（Foundation `JSONEncoder` 未开 `.sortedKeys`），逐字段比较不看顺序。

### 5.1 `GET /healthz`（免鉴权）

```text
----- v3   GET /healthz
ok
[HTTP 200 | text/plain; charset=utf-8]

----- rust GET /healthz
ok
[HTTP 200 | text/plain; charset=utf-8]
```

### 5.2 `GET /api/accounts`（Bearer）

```text
----- v3
[{"provider":"qq","email":"contract-fixture@example.invalid",
  "syncHealth":{"status":"needsReconnect","lastError":"not-configured"},
  "id":"11111111-1111-4111-8111-111111111111","unreadCount":1,"isActive":true,
  "capabilities":{"archiveFolder":false,"trashFolder":false,"serverSnippet":false,"uidplus":false,
                   "idle":false,"sentFolder":false,"move":false}}]
[HTTP 200 | application/json; charset=utf-8]

----- rust
[{"id":"11111111-1111-4111-8111-111111111111","provider":"qq",
  "email":"contract-fixture@example.invalid","isActive":true,"unreadCount":1,
  "syncHealth":{"status":"needsReconnect","lastError":"not-configured"},
  "capabilities":{"archiveFolder":false,"idle":false,"move":false,"serverSnippet":false,
                   "uidplus":false,"sentFolder":false,"trashFolder":false}}]
[HTTP 200 | application/json; charset=utf-8]
```

（`capabilities` 是把库里的 JSON 解成 `MailCapabilities` 再编码：`Option<bool>` 为 nil 的键省略，其余原样；因此与 v3 逐字段相等。）

### 5.3 `GET /api/messages?accountId=…`

```text
----- v3
{"messages":[
  {"fromAddress":"alice.fixture@example.invalid","id":"22222222-2222-4222-8222-222222222223",
   "remoteId":"fixture-msg-3","isSent":false,"accountId":"11111111-1111-4111-8111-111111111111",
   "threadId":"fixture-thread-3","subject":"Contract fixture three (unread)","isArchived":false,
   "messageIdHeader":"<fixture-3@example.invalid>","isPinned":false,"isRead":false,"isDeleted":false,
   "fromName":"<redacted-person>","receivedAt":"2025-01-03T09:00:00Z"},
  {"fromAddress":"alice.fixture@example.invalid","id":"22222222-2222-4222-8222-222222222221",
   "remoteId":"fixture-msg-1","isSent":false,"accountId":"11111111-1111-4111-8111-111111111111",
   "threadId":"fixture-thread-1","subject":"Contract fixture one","isArchived":false,
   "messageIdHeader":"<fixture-1@example.invalid>","isPinned":false,"isRead":true,"isDeleted":false,
   "fromName":"<redacted-person>","receivedAt":"2025-01-01T09:00:00Z"}],
 "cursor":{"totalUnread":1,"lastFetchedAt":"<wall-clock>","accountId":"11111111-1111-4111-8111-111111111111"},
 "totalCount":2}
[HTTP 200 | application/json; charset=utf-8]

----- rust
{"cursor":{"accountId":"11111111-1111-4111-8111-111111111111","lastFetchedAt":"<wall-clock>","totalUnread":1},
 "messages":[
  {"id":"22222222-2222-4222-8222-222222222223","accountId":"11111111-1111-4111-8111-111111111111",
   "remoteId":"fixture-msg-3","threadId":"fixture-thread-3","fromAddress":"alice.fixture@example.invalid",
   "fromName":"<redacted-person>","subject":"Contract fixture three (unread)","receivedAt":"2025-01-03T09:00:00Z",
   "isRead":false,"isArchived":false,"isDeleted":false,"isPinned":false,"isSent":false,
   "messageIdHeader":"<fixture-3@example.invalid>"},
  {"id":"22222222-2222-4222-8222-222222222221","accountId":"11111111-1111-4111-8111-111111111111",
   "remoteId":"fixture-msg-1","threadId":"fixture-thread-1","fromAddress":"alice.fixture@example.invalid",
   "fromName":"<redacted-person>","subject":"Contract fixture one","receivedAt":"2025-01-01T09:00:00Z",
   "isRead":true,"isArchived":false,"isDeleted":false,"isPinned":false,"isSent":false,
   "messageIdHeader":"<fixture-1@example.invalid>"}],
 "totalCount":2}
[HTTP 200 | application/json; charset=utf-8]
```

> `lastFetchedAt` 是 server 端的 now()，两边各取一次；diff 脚本按 key 名归一化为 `<timestamp>` 后比较。
> `snippet` 两边都缺键（seed 的摘要是空），`inReplyTo`/`references` 在 msg-1/3 缺键 —— 与 fixtures 一致。

### 5.4 `GET /api/folder-counts?accountId=…`

```text
----- v3
{"counts":[{"id":"live","count":2},{"id":"unread","count":1},{"id":"archived","count":1},
           {"id":"pinned","count":1},{"id":"deleted","count":0},{"id":"sent","count":0}]}
[HTTP 200 | application/json; charset=utf-8]

----- rust
{"counts":[{"id":"live","count":2},{"id":"unread","count":1},{"id":"archived","count":1},
           {"id":"pinned","count":1},{"id":"deleted","count":0},{"id":"sent","count":0}]}
[HTTP 200 | application/json; charset=utf-8]
```

### 5.5 `GET /api/messages/fixture-msg-1/body?accountId=…`（缓存未命中）

```text
----- v3    {"error":"provider-not-configured"}   [HTTP 503 | application/json; charset=utf-8]
----- rust  {"error":"provider-not-configured"}   [HTTP 503 | application/json; charset=utf-8]
```

缓存**命中**的 200 形状由 `tests/read_paths.rs` 覆盖：用 CryptoKit 生成的 `lgb1:` 密文写进 `message_bodies`，
断言 `text` / `subject` / `fromAddress` / `fromName` / `receivedAt` / `attachments` / `hasMore` / `to` / `cc`，
并断言 `toAddress` 是**缺键**（v3 在这条路径上永远传 nil）。

### 5.6 真机冒烟：直接读 v3 边车建的 `v4/.dev/data/lagoon.sqlite`

```text
$ LAGOON_BODY_KEY=<dev keys.json 的 bodyKey> LAGOON_API_TOKEN=<apiToken> \
  cargo run -p lagoon-api -- --port 0
2026-10-29T06:04:38Z info lagoon_api : schema verified applied=11
2026-10-29T06:04:38Z info lagoon_api : starting host=127.0.0.1 port=0 db=<repo>/v4/.dev/data/lagoon.sqlite auth=true
2026-10-29T06:04:38Z info lagoon_api : listening port=52242

healthz  200 text/plain; charset=utf-8   (body: ok)
accounts 200 application/json            (开发库为空 → [])
无 token                    → 401 {"error":"api-unauthorized"}
Host: evil.example          → 403 {"error":"forbidden-host"}
GET /api/nope（带 token）    → 404 空体，bytes=0，无 Content-Type
```

这一段用的是 v3 边车迁移出来的**真库**（`grdb_migrations` 11 条全在）：BLOB UUID、TEXT 日期、`capabilities` JSON 都能读。
边车此刻仍在运行，两边各自只读同一个 WAL 库——R1 的读连接不会影响它。

## 6. Oracle 是怎么确定的（不靠猜）

1. **端点/字段/状态码**：`v4/recon/server-contract.md` §2/§3/§7 + 逐个读 v3 源码（`SyncRoutes`、`MessageRoutes`、`FolderCountsRoutes`、`MessageStore.filterSQL/recent/count/decode`、`AccountStore`、`BodyStore`、`APIAuth`、`HostGuard`、`RouteSupport`、`StoredDate`、`BodyCipher`）。
2. **Swift 行为探针**（临时脚本，未入库）确认了三件容易“看起来对”的事：
   - `UUID(uuidString:)` **只**接受 8-4-4-4-12（大小写不限），32 位无连字符、花括号、`urn:`、尾随空格全部 nil；
   - `JSONEncoder(.iso8601)` 对 `.999` / `.500` 都输出 `:00Z`（**截断**，不是四舍五入），`23:59:59.900` → `:59Z`；
   - 合成 `Encodable` 对 nil optional 输出**缺键**，不是 `null`。
3. **Golden fixtures**：`v4/tests/contract/fixtures/fixtures.json`（v3 真实响应）既当 Rust 回放的断言，也当 live diff 的请求清单。
4. **CryptoKit 互操作向量**：`v4/spike/cipher-interop/interop-transcript.log` 里 Swift 产出的 3 个 `lgb1:` 信封，Rust 单测直接解——不是自封自解。

## 7. 与 v3 的已知差异 / 边界

| # | 差异 | 为什么 |
|---|---|---|
| 1 | `/body` 未命中缓存固定 503 `provider-not-configured` | R1 没有 IMAP provider；这正是 v3 在“provider 构造不出来”时给的码，同库同答案 |
| 2 | 其余 51 个 `/api/*` 端点 404（空体） | R1 只有只读切片；与 v3 未知路由同形，前端按“协议错误”处理 |
| 3 | 默认 DB 路径是编译期路径 | 开发期便利；发布期由外壳显式传 `--db`。仓库搬家后重新 build 即修正 |
| 4 | 缺少 HTTP/2 `:authority` 支持 | R1 只监听明文 HTTP/1.1；v3 同样是 HTTP/1.1 本地服务 |
| 5 | 未知**新**迁移只 WARN 不拒绝 | 列探针已覆盖 R1 真正读的东西；用版本号一刀切会在 v3 加迁移时误伤。**缺**任一已知迁移仍然拒绝启动 |
| 6 | 未注册 `lagoon_cipher_contains` / `lagoon_cipher_seal` | R1 无搜索端点；注册等于提前做 R3 |
| 7 | `LAGOON_BODY_KEY` 必填（v3 亦然） | 缺 key 会让摘要静默变空、正文全 503 —— 拒绝启动优于安静降级 |

## 8. 阻塞 / 需要 Lead 决策

1. **无**阻塞：验收项全部达成（build / test / fixtures / live diff / curl 证据 / README）。
2. 建议在 M1 的 `docs/ipc-contract.md` 登记一件事：**外壳的 `api` 代理在 R1 阶段只能打到这 5 组只读端点**；前端对其它路径会收到空体 404，应按“服务端未实现该端点”呈现，而不是业务错误。
3. 建议 R2 范围先定为“剩余纯本地只读端点”（advice/briefing/search/stacks/reminders/senders/time-saved/export），并给 `/body` 加“可注入只读 provider”的测试缝，才能把 200 的 body fixture 补进 `v4/tests/contract/fixtures/`。

## 9. 怎么复现

```bash
cd v4/crates
cargo build --offline && cargo test --offline
bash lagoon-api/scripts/diff-vs-v3.sh          # 需要 .build/release/LagoonServerCLI
```

运行方式见 [README.md](README.md)。
