# lagoon-api —— v4 Rust 后端（R1 只读切片 + R2 本地只读铺满）

> v4 的产品是 **Rust 外壳 + Rust 后端 + Web 前端，发布物无 Swift**。
> R1 做了只读垂直切片（5 组端点），R2 把**不需要 IMAP、不需要模型**的只读端点全部铺满（共 24 组）。
> 全程**只读**：不写库、不迁移、不连 IMAP、不调 AI；v3.2.0 只作为参考实现与开发期对照。

## 1. 它是什么、不是什么

| 是 | 不是 |
|---|---|
| 一个真能跑起来的 axum 服务，读 v3 建的 SQLite | 不是 v3 的替代品（56 个 `/api/*` 里只做了 5 组只读） |
| 响应形状、状态码、错误码逐字对齐 `v4/recon/server-contract.md` | 不做写路径 / 同步 / IMAP / SMTP / AI |
| 用 v3 自己的密文（`lgb1:` AES-256-GCM）解正文与摘要 | 不持有、不读取凭据密钥（`lagoon.tokenKey`） |
| SQLite 只读连接 + 启动期 schema 探针（fail-closed） | 不迁移、不建库、不创建缺失的文件 |

端点（其余路径一律 v3 同款**空体 404**，不是 JSON 信封）：

### R1：只读垂直切片

| 方法 路径 | 说明 |
|---|---|
| `GET /healthz` | 纯文本 `ok`；唯一免鉴权路径（精确匹配） |
| `GET /api/accounts` | `ConnectedAccount[]`，按 email 排序 |
| `GET /api/messages` | `SyncResponse`；`accountId` + `limit/sender/archived/deleted/pinned/unread/stackId` |
| `GET /api/messages/{remoteId}/body` | `MessageBody`（命中 `message_bodies` 缓存即返回；未命中 → 503） |
| `GET /api/folder-counts` | 侧边栏六个计数（live/unread/archived/pinned/deleted/sent） |

### R2：纯本地只读（不需要 IMAP，不需要模型）

| 方法 路径 | 说明 | 参数 |
|---|---|---|
| `GET /api/briefing` | 简报流：30 天窗口 + 未读积压，含分组与原因码 | `accountId` `limit` |
| `GET /api/advice` | AI 建议队列 | `accountId` `decision=pending/accepted/dismissed/any` `limit` |
| `GET /api/advice/accepted-stats` | 用户接受过的建议统计（前 5） | `accountId` |
| `GET /api/stacks` | 聚合规则 + 各自命中数 | `accountId` |
| `GET /api/senders` | 发件人排行 | `accountId` `limit` `q` |
| `GET /api/sent` | 已发送本地列表（刷新失败 → 200 + `staleReason`） | `accountId` `limit` |
| `GET /api/store-notices` | 本地存储一次性通知 | — |
| `GET /api/time-saved` | 节省时间（今天/本周 + 按天） | `accountId` |
| `GET /api/usage` | 本月 AI 用量与预算 | — |
| `GET /api/ai-status` | AI 降级信号 | — |
| `GET /api/actions` | 审计日志（keyset 分页） | `accountId` `since` `before` `limit` |
| `GET /api/reminders` | 提醒（默认只返回未完成） | `accountId` `includeDismissed` |
| `GET /api/export/index` | 导出索引（全部表头，旧→新） | `accountId` |
| `GET /api/search` | 两段式搜索：列 + 结构化 AI 判定 + 封存正文（预算 1000） | `accountId`=`<uuid>`/`all` `q` `sender` `since` |
| `GET /api/messages/{remoteId}/drafts` | 已存回复草稿（`lgb1:` 封存） | `accountId` |
| `GET /api/messages/{remoteId}/summary` | AI 摘要（R2 无 provider → 503） | `accountId` |
| `GET /api/messages/{remoteId}/inline-images` | 内联图（R2 → 503） | `accountId` |
| `GET /api/messages/{remoteId}/raw.eml` | 原始邮件（R2 → 503） | `accountId` |
| `POST /api/messages/{remoteId}/archive` | 能力闸门（不可归档 → 409；R2 无 provider → 503） | `accountId` |
| `POST /api/messages/{remoteId}/draft` | 生成草稿（R2 → 503） | `accountId` |
### R3.2：自建库（与 v3 逐字节等价）

Rust 现在能**自己建库**：11 条迁移逐条来自 `Sources/LagoonKit/LagoonDatabase.swift`（`src/migrations.rs` 由 `scripts/gen-migrations.py` 生成，不手抄），并维护 GRDB 的 `grdb_migrations` 记录，v3.2.0 打开后认为“已迁移到 lagoon-v10”。

```bash
# 建库 / 升级到 lagoon-v10（不绑定端口）
cargo run -p lagoon-api -- --migrate --db /tmp/new.sqlite

# 证明：Rust 库 vs v3 库 dump 一致 + v3 能打开 Rust 库
bash v4/crates/lagoon-api/scripts/verify-r3.2.sh
```

可写 store（`src/store/write.rs`）已具备：账号 upsert/激活/删除、表头 upsert、正文封存写入、pin、capabilities/folder role、sync_state、`ai_actions` 审计（含 undo）、草稿封存写入。R3.3 起账号相关写路由已接 HTTP。
### R3.3：账号生命周期（provider 缝）

| 方法 路径 | 说明 |
|---|---|
| `POST /api/accounts/imap` | 连接/重认证一个邮箱：400 `missing-field`、409 `account-exists`、401 `imap-auth-failed`、502 `imap-unreachable`、503 `provider-not-configured`、201 `ConnectedAccount` |
| `POST /api/accounts/{id}/activate` | 选择当前账号（204 / 404） |
| `DELETE /api/accounts/{id}` | 删除账号并级联（204 / 404） |

凭据用 **裸 AES-GCM combined**（12B nonce‖ct‖16B tag，无 `lgb1:` 前缀）封存，key = `LAGOON_TOKEN_KEY`（base64 32B）。provider 边界是 `ProviderFactory`/`MailProvider`；生产默认 `NoProviderFactory` → 503，真实 `lagoon-mail` 适配层是 R3.4 的 TODO。

```bash
# 跨实现（CryptoKit ↔ Rust）+ v3 使用 Rust 写的账号（含负向对照）
bash v4/crates/lagoon-api/scripts/verify-r3.3.sh
```
### R3.4a：同步引擎（FakeProvider 驱动）

| 方法 路径 | 说明 |
|---|---|
| `POST /api/sync` | 触发每账号一轮同步，立即 204（不等完成） |

语义对齐 v3 `SyncEngine.swift`：每账号独立 cursor（`uidValidity`+`lastUid`）、UIDVALIDITY 变化 → 只清 live 行后全量重同步、退避 `min(300, 2^(n-1))`±20% 且 ≥3 次转 `degraded`、认证失败停车 `needsReconnect`、账号隔离、单写者（apply 段串行）。同步只拿 `MailProvider` 的 probe+pull，没有写邮箱的动词。真实 IMAP 是 R3.4b。

```bash
# 同步引擎测试（脚本化 provider，无网络）
cargo test -p lagoon-api --offline --test r3_sync
```
## 生产 provider（R3.4b-1）

- **默认后端**：`LAGOON_MAIL_PROVIDER` 未设置或 `none` → 不安装 provider（`NoProviderFactory`，契约测试永不联网）；`production` → `LagoonMailFactory::production()`（lagoon-mail 的隐式 TLS 993/465 + 平台信任库）。其他值拒绝启动。
- **凭据生命周期**：`LAGOON_TOKEN_KEY`（base64 32B）→ `token.rs` 裸 AES-GCM 解出 authCode → `ProviderCredentials`。解不开或缺失 → `503 provider-not-configured`；凭据只在内存与封存列中存在，绝不写明文、绝不日志。
- **失败分类**：IMAP 认证失败 → `401 imap-auth-failed`；DNS/TCP/TLS/超时 → `502 imap-unreachable`；无 provider/凭据不可用 → `503 provider-not-configured`。
- **成员填充**：R3.4b-2b 起 `pull_changes` 在同一条会话上调用 lagoon-mail 的 `remote_membership()` 填 inbox/archived/trashed；每轮 1 条连接。任一集合为 `None`（未知）时不删任何本地行，reset 轮不填。

```bash
# 默认（无 provider）
cargo run -p lagoon-api -- --db /tmp/store.sqlite

# 真实后端（会连 imap.qq.com；只在用户授权后手动使用）
LAGOON_MAIL_PROVIDER=production LAGOON_TOKEN_KEY=... LAGOON_BODY_KEY=... \
  cargo run -p lagoon-api -- --db /tmp/store.sqlite
```

## 2. 快速开始

```bash
# 1) 开发库：v3 边车创建（R1 只读它，绝不写入）
bash v4/scripts/sidecar-dev.sh start      # 已有可跳过

# 2) 从开发期密钥文件取 bodyKey（只做变量赋值，不打印值；文件本身 0600 + gitignore）
KEYS=v4/.dev/keys.json
export LAGOON_BODY_KEY=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["bodyKey"])' "$KEYS")
export LAGOON_API_TOKEN=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["apiToken"])' "$KEYS")

# 3) 起 Rust 后端（默认读 v4/.dev/data/lagoon.sqlite）
cd v4/crates && cargo run -p lagoon-api -- --port 18099

# 4) 验证
curl -sS http://127.0.0.1:18099/healthz
curl -sS -H "Authorization: Bearer $LAGOON_API_TOKEN" \
     "http://127.0.0.1:18099/api/accounts"
```

密钥只从环境变量读，**不从 argv 读**：argv 会被 `ps` 看到。`--db/--host/--port` 可以写在命令行上。

### 配置

| 项 | 默认 | 来源（优先级从高到低） |
|---|---|---|
| 数据库 | `v4/.dev/data/lagoon.sqlite`（编译期相对本 crate） | `--db` > `LAGOON_DB_PATH` > `$LAGOON_V4_DATA_DIR/lagoon.sqlite` |
| 绑定地址 | `127.0.0.1` | `--host` > `LAGOON_SERVER_HOST` |
| 端口 | `8080` | `--port` > `LAGOON_SERVER_PORT`（`0` = 随机端口，日志打印**真实**端口） |
| 鉴权 | 关（无 token） | `LAGOON_API_TOKEN`；非回环绑定**必须**配 token，否则拒绝启动 |
| body 密钥 | 无默认，**必填** | `LAGOON_BODY_KEY`（base64 32 字节）；缺失/格式错拒绝启动 |

启动日志（stderr，一行一条，字段风格沿用 v3 的 swift-log）：

```text
2026-10-29T06:00:00Z info lagoon_api : starting host=127.0.0.1 port=18099 db=/... auth=true
2026-10-29T06:00:00Z info lagoon_api : listening port=18099
```

## 3. 契约对齐（逐条）

| 项 | 做法 | 证据 |
|---|---|---|
| Content-Type | JSON 统一 `application/json; charset=utf-8`；`/healthz` 为 `text/plain; charset=utf-8` | 18/18 golden fixtures |
| 错误信封 | 只有 `{"error":"<code>"}`，上游原文永不回传 | 同上 |
| 未知路由 | 空体 404、无 Content-Type | `unknown-route*` fixtures |
| 401 / 403 | 401 `api-unauthorized`（缺 token 与错 token 相同）；403 `forbidden-host` | `auth.*` / `host.forbidden` |
| Host 守卫 | 白名单 `127.0.0.1/localhost/::1`；配 token 时并入绑定地址（通配绑定不并入）；端口与 IPv6 括号归一化 | `config::normalize_host` + 单测 |
| 中间件顺序 | Host → 鉴权 → 路由 | `http::guard` |
| 鉴权常量时间 | 两侧先 SHA-256 再定长比较（v3 `APIAuthMiddleware.timingSafeEqual`） | `http::guard::timing_safe_eq` |
| 日期 | 库里 TEXT `yyyy-MM-dd HH:mm:ss.SSS`；线上 ISO-8601 **秒级截断**（`.999` → `:00Z`） | Swift 探针 + `timefmt` 单测 |
| 可空字段 | nil 编码为**缺键**而不是 `null`（“缺省即未知”是 v3 §2 的语义） | fixtures 逐字段 |
| UUID | 只接受 Foundation 认的 8-4-4-4-12 形式（大小写不限），32 位无连字符/花括号/urn 一律 nil | Swift 探针 + `uuid` 单测 |
| 列表语义 | 置顶是独立 lens（忽略 archived/deleted）；sent/deleted 忽略 archived；inbox/archive 追加 `is_sent = FALSE` | `store::messages::MessageFilter` |
| `totalCount` | 忽略 LIMIT 的计数（客户端据此说“还有 N 条”） | fixtures `messages.list.limit` |
| 账号存在性 | `/api/messages` **不查**账号（未知 UUID → 200 空列表）；`/folder-counts` 与 `/body` **要查**（404） | `m1-checklist.md` §1 + `unknown-account` |
| 封存格式 | `lgb1:` + base64(12B nonce ‖ ciphertext ‖ 16B tag)，AES-256-GCM，无 AAD | 与 CryptoKit 互操作向量（`crypto` 单测） |

## 4. 模块

| 文件 | 职责 |
|---|---|
| `src/main.rs` | 解析参数/环境 → 开库 → 绑定 → serve；优雅退出 |
| `src/config.rs` | 环境与参数优先级、绑定安全拒绝、Host 白名单 |
| `src/db.rs` | 只读连接池（4 条）+ schema 探针 + 列解码 |
| `src/store/*` | 复刻 `MessageStore` / `AccountStore` / `BodyStore` / `StackStore` 的 SQL |
| `src/wire.rs` | `LagoonKit` 共享 wire 类型（字段与 casing 逐字复刻） |
| `src/crypto.rs` | `lgb1:` 信封的 open/seal |
| `src/timefmt.rs` | v3 存储日期 ↔ ISO-8601 |
| `src/uuid.rs` | Swift 兼容的严格 UUID 解析 |
| `src/http/*` | axum 路由、Host/鉴权中间件、错误信封、查询串解析 |
| `src/telemetry.rs` | stderr 上的最小 tracing Subscriber（见 §7） |

## 5. 只读与安全

- 每条连接都是 `SQLITE_OPEN_READ_ONLY`，并额外 `PRAGMA query_only = ON`；测试里有一条用例专门证明写会失败。
- 启动时探针 6 张表 / 关键列 + `grdb_migrations`：**缺 v3.2.0 已知迁移就拒绝启动**（“未知版本 fail-closed”），比自己读空表更早暴露问题。
- 不读 `accounts.credentials`（连列都不 SELECT）：只读进程既不需要、也不该碰那把钥匙。
- 不建库：文件不存在直接报错，不会创建 0 字节 SQLite。
- 密钥只从环境读、日志与 Debug 都脱敏（`BodyKey(<redacted 32 bytes>)`）。
- 非回环绑定必须有 `LAGOON_API_TOKEN`，否则拒绝启动（照抄 v3 `ServerConfig.startupRefusal`）。

## 6. 测试与验证

```bash
cd v4/crates
cargo test --offline                        # 36 单测 + 48 契约回放 + 7 只读路径 + 5 R2 数据路径 + 1 真 v3 库冒烟

# 用官方脚本回放契约（48/48，3 条写路径默认 SKIP）
bash lagoon-api/scripts/contract-check-r2.sh

# 与真 v3 边车同库逐字段 diff（46 SAME + 2 EXPLAINED + 0 DIFF）
bash lagoon-api/scripts/diff-vs-v3.sh
```

| 测试文件 | 覆盖 |
|---|---|
| 源码内 `#[cfg(test)]`（36 条） | 日期/UUID/密文（含 CryptoKit 互操作向量）/查询串/Token 比较/配置优先级/简报分组与覆盖/搜索大小写折叠/审计 payload 解码/双精度编码 |
| `tests/contract_replay.rs` | 用 harness 的 seed 建库，回放 `fixtures.json` 里 **48 条可回放 fixtures**（含 2 条 `contract_expected` 的 search 200）；3 条写路径按 `r2_skip` 跳过 |
| `tests/read_paths.rs`（7 条） | R1 的缓存正文/摘要/`/body` 状态码矩阵/聚合筛选/只读句柄/Host 鉴权 |
| `tests/r2_paths.rs`（5 条） | R2 的数据路径：advice 队列与统计、stacks/reminders/notices、drafts（封存）与 actions 分页、time-saved/usage、搜索的封存正文与结构化判定、provider 闸门与 409 能力闸门 |
| `tests/dev_store.rs` | 打开 v3 边车真实迁移过的 `v4/.dev/data/lagoon.sqlite`（只读）并起服务；文件不存在时打印 skip |
| `scripts/contract-check-r2.sh` | 复制 v3 迁移出的 schema → harness seed（同一 body key）→ 起本服务 → `v4/scripts/contract-check.sh <url> <token>` |
| `scripts/diff-vs-v3.sh` | 两进程读同一份合成库，逐字段 diff 全部可回放 fixtures；search 的两条记为 EXPLAINED |
| `tests/migrations.rs`（5 条） | R3.2：Rust 建库 vs `tests/golden/v3-schema.json`（真 v3 空库快照）逐对象对比、迁移幂等、可写路径回读、v6 正文封存、folder role 合并 |
| `scripts/verify-r3.2.sh` | 起 Rust 建库 → 写假账号 → 起 v3 打开该库 → dump diff + `/api/accounts` + 一次同步尝试 |
| `tests/r3_accounts.rs`（6 条） | R3.3：连接状态矩阵、三态能力、重认证原地更新/失败不动行、激活切换、删除级联与 promote |
| `scripts/verify-r3.3.sh` | CryptoKit ↔ Rust 凭据双向互解；v3 使用 Rust 写的账号；垃圾凭据负向对照 |
| `tests/r3_sync.rs`（7 条） | R3.4a：首轮/增量、UIDVALIDITY 重置、退避与 degraded、认证停车、账号隔离并发、header-only、POST /api/sync 204 |

契约回放用的是**同一份** golden fixtures、同一套规范化规则（只按 key 名替换 wall-clock 时间戳，含 `byDay.date`），所以 Rust 端与 `v4/scripts/contract-check.sh` 打 Swift 边车是同一个判据。

### 契约脚本对 Rust 实例的实测输出

```text
bash v4/crates/lagoon-api/scripts/contract-check-r2.sh
seed: {accounts: 2, advice: 2, ai_actions: 2, draft_replies: 1, message_bodies: 1,
       message_headers: 5, message_pins: 1, reminders: 2, stack_rules: 2, store_notices: 1}
SKIP  read.mark-read (write-path: Rust R2 is READ_ONLY; assert with LAGOON_CONTRACT_INCLUDE_WRITE=1)
SKIP  read.recorded (write-path: ...)
SKIP  pin.set (write-path: ...)
48/48 fixtures match (3 skipped)
```

## 7. 依赖与离线构建

版本是按契约钉死的，不是“最新版”：`axum 0.8.9`、`tokio 1.54`、`rusqlite 0.41`(bundled)、`aes-gcm **=0.10.3**`（cipher spike 与 CryptoKit 对过的那一版）、`base64 0.22`、`serde/serde_json`、`sha2`、`subtle`、`tracing`。

本机只用 Homebrew rustc（**无 rustup**），registry 缓存里没有 `tracing-subscriber`，所以 `src/telemetry.rs` 自己实现了 60 行的 `Subscriber`：只做一件事——把事件写到 stderr。后续把 `tracing-subscriber` 加进缓存后，删掉这个文件、在 `main` 里换成它的初始化即可，业务代码里的 `tracing::*!` 不需要改。

构建：`cargo build --offline`（离线可过；有网时 `cargo build` 等价）。`Cargo.lock` 入库。

## 8. 已知边界（有意为之）

**R1 只读切片**

1. **`/body` 未命中缓存 → 503 `provider-not-configured`**。R2 仍然没有 IMAP provider；v3 在“provider 构造不出来”时给的就是这个码，所以同一份库上两边答案一致。真实取值要等 R3（mail）落地。
2. **其余端点返回空体 404**（与 v3 的未知路由同形）：写路径（归档/删除/回复/置顶/已读）全部留到 R3。
3. **默认库路径是编译期路径**（本 crate 的 `../../.dev/data/lagoon.sqlite`）。发布期由外壳显式传 `--db`/`LAGOON_DB_PATH`；仓库搬家后重新 `cargo build` 即可。
4. **`LAGOON_BODY_KEY` 必填**：缺了它，列表里每一条摘要都会静默变空、正文全部 503——那正是 v3 `BodyKeyGuard` 要防的“安静的降级”，所以这里选择拒绝启动。
5. **Host 守卫**：缺 `Host` 头直接 403（v3 亦然）；只支持明文 HTTP/1.1，不认 HTTP/2 的 `:authority`。
6. **schema 探针的版本策略**：已知 11 条迁移缺任何一条 → 拒绝；出现未知的**新**迁移 → 打 WARN 但继续（只要读到的列都在）。列探针比版本号更贴近真实约束。
7. **不注册 v3 的 SQL 函数**（`lagoon_cipher_contains` / `lagoon_cipher_seal`）：搜索在 Rust 里做，不把密文比较下推给 SQLite。

**R2 本地只读**

8. **`search` 的写法与 v3 不同（这是本任务的明确要求）**：v3.2.0 的 pass-B 在只 JOIN `message_bodies` 的 SQL 里引用 `a.category`/`a.action`，必然 500；这里让两段都 `LEFT JOIN advice`，返回契约规定的 200 `SearchResponse`。fixtures 里两条 `contract_expected` 就是它。
9. **`/summary`、`/draft`、`/inline-images`、`/raw.eml` 固定 503 `provider-not-configured`**：R2 无 provider 也无模型。fixtures 钉的就是这个形状（v3 的 AI 网关对象即使未配置也存在，所以它先撞到 provider 闸门）；等 R3 有 provider、R4 有 AI 之后，`ai-not-configured` / `ai-credit-exhausted` / `ai-budget-exceeded` 这些分支才会出现。
10. **`/api/briefing` 不做 v3 的“清理 30 天前 dismissed 建议”写操作**：R2 没有写路径，这是唯一被省掉的一步；它只影响历史建议行的保留，不影响本次响应。
11. **`/api/stacks` 不校验账号是否存在**（v3 也不校验）：未知但格式正确的 id 得到 200 空列表，而不是 404；`/api/advice`、`/api/reminders`、`/api/sent`、`/api/senders`、`/api/export/index` 则校验并给 404。
12. **`/api/usage` 的 `costTrackingAvailable` 恒为 false**（无模型价目表），`capUSD` 来自 `LAGOON_BUDGET_USD_PER_MONTH`（默认 0）。
13. **`/api/time-saved` 依赖本地时区**：今天/本周按 `chrono::Local` 的日历边界，与 v3 的 `Calendar.current` 同义；跨时区读同一份库会看到不同分桶，这与 v3 一致。
14. **草稿解不开 → 500 `draft-unreadable`**（整份列表失败而不是静默丢一条），因为“有 3 条草稿、其中 1 条坏了”不能显示成“有 2 条”。
15. **写路径的 3 条 fixtures 带 `r2_skip`**：官方 `contract-check.sh` 默认 SKIP 并打印原因；`LAGOON_CONTRACT_INCLUDE_WRITE=1` 才会断言（在 R3 之前必然红，这是预期）。

## 9. 下一步

- **R3**：IMAP/SMTP（读、同步、发送）＋写路径（归档/删除/回复/撤销/置顶）。写之前先落 `ai_actions` 审计与撤销的存储层（与 v3 同形），否则 undo 语义无法对齐。
- **R4**：AI（摘要/建议/草稿）。届时 `/summary`、`/draft`、`/api/ai-status`、`/api/usage` 的真实分支才有意义。
- 外壳：R2 完成后按 ADR 0002 增加 `--backend rust|swift` 开关（默认 rust）。
