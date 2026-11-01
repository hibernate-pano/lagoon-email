# REPORT-R2 —— 纯本地只读端点铺满（R2 验收证据）

> 范围：`v4/crates/lagoon-api`，**只读**（`SQLITE_OPEN_READ_ONLY` + `PRAGMA query_only=ON`），不迁移、不写库、不连 IMAP、不调模型。
> 判据：`v4/scripts/contract-check.sh <url> <token>` 全绿 + 与 v3.2.0 边车同库逐字段 diff。

## 1. 交付物

| 文件 | 说明 |
|---|---|
| `src/http/routes_r2.rs`（约 1000 行） | R2 的 24 个处理函数与状态码顺序 |
| `src/wire_r2.rs` | R2 的全部 wire 类型；`monthUSD`/`capUSD` 保留 v3 属性拼写，整数 double 输出 `2` 而非 `2.0` |
| `src/briefing.rs` | 简报启发式分组 + 用户覆盖（pinned > 消息级 > 发件人级 > 分类器） |
| `src/store/{advice,actions,briefing,drafts,notices,reminders,senders,stacks,usage,search}.rs` | 只读 SQL 层（新增 10 个模块） |
| `src/config.rs` | 新增 `LAGOON_BUDGET_USD_PER_MONTH`（默认 0） |
| `scripts/contract-check-r2.sh` | 复制 v3 迁移出的 schema → harness seed（同一 body key）→ 起本服务 → 官方 contract-check |
| `scripts/diff-vs-v3.sh` | 扩到**全部可回放 fixtures**（48 条），search 两条记为 EXPLAINED |
| `tests/r2_paths.rs`（5 条） | 不依赖 python 的 R2 数据路径测试 |
| `tests/contract_replay.rs` | 用 harness 的 seed 回放 48 条 fixtures（含 2 条 contract_expected） |

## 2. 端点与语义要点

| 端点 | 关键语义（与 v3 对齐的坑） |
|---|---|
| `GET /api/briefing` | 30 天窗口 + 未读积压；`omittedCount`/`backlogCount` 为 0 时**省略键**；分组顺序 pinned > list-unsubscribe > 订阅发件人 > 自己发的 > 已回复 > 已读且超 7 天 > needs-reply |
| `GET /api/advice` | `decision` 默认 `pending`，`any`=全部，其他非法值 400 `malformed-decision`；`ORDER BY created_at DESC, id DESC` |
| `GET /api/advice/accepted-stats` | 前 5 条；计数降序 → 无 category 优先 → category → action |
| `GET /api/stacks` | **不校验账号**（v3 也不校验）：未知 id → 200 空列表 |
| `GET /api/senders` | `limit` 默认 60 clamp 1..300；`q` trim 后为空视为未传；发件人排行按 total DESC, latest DESC |
| `GET /api/sent` | 无 provider：**200** + `refreshedFromServer:0` + `staleReason:"not-configured"`（不是 503） |
| `GET /api/time-saved` | 今天/本周按**本地日历**；`byDay` 每个事件都会建条目（pin 也留 0 分钟日）；分钟数保留 1 位小数 |
| `GET /api/usage` | 月键 `yyyy-MM` 用**本地时区**；`monthUSD`/`capUSD`（大写 USD）；`costTrackingAvailable:false` |
| `GET /api/actions` | `before` 非法 → 400 `malformed-before`，查不到 → 400 `unknown-before`；`limit` 默认 100 clamp 1..500；keyset 分页 |
| `GET /api/reminders` | `includeDismissed` 仅 `== "true"` 才生效；未知账号 404 |
| `GET /api/export/index` | 全部表头旧→新 + `totalCount/deletedCount/sentCount` |
| `GET /api/search` | 见第 3 节；`accountId` 缺失/空/非法 → 400；`q` 空 → 200 空结果 |
| `GET /api/messages/{id}/drafts` | 封存整数组解封；解不开 → 500 `draft-unreadable`（不静默丢行） |
| `GET /api/messages/{id}/summary`、`/inline-images`、`/raw.eml`、`POST /draft` | 400 → 404 → **503 `provider-not-configured`** |
| `POST /api/messages/{id}/archive` | 400 → 404 → **409 `archive-unavailable`**（能力闸门先于 provider） |

## 3. `search` 重写（不复制 v3 的 500 缺陷）

v3.2.0 的 `/api/search` 在 pass-B 的 `scanSQL` 里引用 `a.category` / `a.action`，但那条语句只 `JOIN message_bodies`：SQLite 直接报 `no such column: a.category`，整个端点恒 500（fixtures 里 `search.contract` 的 `defect_evidence` 记录了这个事实）。

本实现两段都 `LEFT JOIN advice a ON a.account_id = m.account_id AND a.remote_id = m.remote_id`：

1. **pass A（便宜臂）**：subject / from_name / from_address / advice.category / advice.action 做 `LIKE ... ESCAPE`；
2. **pass B（封存臂）**：对未命中的行，按 `received_at DESC, id DESC` 分批（200/批，预算 1000）解封 `snippet_cipher` 与 `message_bodies.body_cipher/body_html_cipher` 做大小写折叠包含；预算用尽计入 `bodyScanSkipped`；
3. 合并去重后按 `(received_at DESC, id DESC)` 取前 100，`totalCount` 是命中总数，`truncated = totalCount > 返回数`。

实测（同一份 seed，两边各起一个进程）：

```text
v3   GET /api/search?accountId=1111...&q=fixture   -> 500 {"error":"internal-error"}
rust GET /api/search?accountId=1111...&q=fixture   -> 200 {"results":[3 条],"query":"fixture","totalCount":3,
                                                        "truncated":false,"bodyScanSkipped":0,"bodyScanLimit":1000}
```

## 4. 验证证据（真实输出）

### 4.1 构建与测试

```text
$ cd v4/crates && cargo build --offline
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 3.01s      # 0 warning

$ cargo test --offline
running 36 tests  ... test result: ok. 36 passed; 0 failed      # 单元测试
running 1 test    ... test result: ok. 1 passed                 # contract_replay：48 条 fixtures
running 1 test    ... test result: ok. 1 passed                 # dev_store：真 v3 库冒烟（只读）
running 5 tests   ... test result: ok. 5 passed                 # r2_paths：R2 数据路径
running 7 tests   ... test result: ok. 7 passed                 # read_paths：R1 只读路径
```

### 4.2 官方契约脚本对 Rust 实例（48/48）

```text
$ bash v4/crates/lagoon-api/scripts/contract-check-r2.sh
seed: {"accounts": 2, "advice": 2, "ai_actions": 2, "draft_replies": 1, "message_bodies": 1,
       "message_headers": 5, "message_pins": 1, "reminders": 2, "stack_rules": 2, "store_notices": 1}
contract-check: replaying against http://127.0.0.1:58064 (no seeding; the instance must be fresh)
SKIP  read.mark-read (write-path: Rust R2 is READ_ONLY; assert with LAGOON_CONTRACT_INCLUDE_WRITE=1)
SKIP  read.recorded (write-path: ...)
SKIP  pin.set (write-path: ...)
48/48 fixtures match (3 skipped)
```

即：官方 `v4/scripts/contract-check.sh <url> <token>` 对 Rust 实例 **48/48 全绿**；3 条写路径按 fixtures 里的 `r2_skip` 跳过（R3 才实现，`LAGOON_CONTRACT_INCLUDE_WRITE=1` 可临时断言）。

### 4.3 与 v3 边车同库 diff（46 SAME + 2 EXPLAINED + 0 DIFF）

```text
$ bash v4/crates/lagoon-api/scripts/diff-vs-v3.sh
seed: {accounts: 2, advice: 2, ...}
   sync loop parked at needsReconnect; payload stable
fixture                                  v3     rust   verdict
healthz                                  200    200    SAME
accounts.list                            200    200    SAME
auth.missing-token                       401    401    SAME
auth.bad-token                           401    401    SAME
host.forbidden                           403    403    SAME
messages.list / .limit / .archived / .pinned / .unread / .sender / .malformed-account / .b
folder-counts                            200    200    SAME
senders / senders.data                   200    200    SAME
export.index                             200    200    SAME
advice.list / .data / .all / accepted-stats  200 200  SAME
stacks.list / .data                      200    200    SAME
reminders.list / .data / .with-dismissed 200    200    SAME
time-saved / time-saved.data             200    200    SAME
actions.list.data                        200    200    SAME
usage / ai-status / store-notices / briefing  200 200  SAME
body.provider-unconfigured               503    503    SAME
body.cached                              200    200    SAME
summary / draft.generate / inline-images / raw-eml  503 503 SAME
drafts.list.data                         200    200    SAME
sent.stale                               200    200    SAME
archive.capability-gate                  409    409    SAME
unknown-account / unknown-route / unknown-route.v2  404 404 SAME
search.contract                          500    200    EXPLAINED
search.contract.sealed-body              500    200    EXPLAINED

46/48 identical, 2 explained by a documented v3 defect, 0 different
```

### 4.4 关键响应逐字节抽样（v3 vs rust）

```text
GET /api/briefing?accountId=1111...
v3  : {"items":[{"group":"needsReply","message":{..."remoteId":"fixture-msg-3"...},"reasonCode":"needs-reply"}],"backlogCount":1}
rust: {"items":[{"message":{..."remoteId":"fixture-msg-3"...},"group":"needsReply","reasonCode":"needs-reply"}],"backlogCount":1}
      （键序不同，逐字段相同；omittedCount 在 0 时两侧都缺键）

GET /api/messages/fixture-b-msg-1/body?accountId=3333...
v3  : {"text":"Contract fixture body: sealedneedle appears here.","to":["contract-fixture-b@example.invalid"],"html":"<p>..."}
rust: 同一份明文（同一把 body key 解同一行 lgb1: 封存）

GET /api/time-saved?accountId=3333...
v3  : {"today":{"minutesSaved":2,"draftsSent":1,"unsubscribed":0,"messagesHandled":1,"byDay":[]},
       "week":{"minutesSaved":2,...,"byDay":[{"minutesSaved":2,"messagesHandled":1,"date":"2026-10-28T16:00:00Z"}]}}
rust: 逐字段相同（byDay.date 是本地零点→UTC，两侧同一时区同一值）
```

## 5. 已知差异与边界（都不影响验收）

1. **3 条写路径未实现**（`read.mark-read` / `read.recorded` / `pin.set`）：R2 只读，fixtures 用 `r2_skip` 标注，官方脚本默认 SKIP 并打印原因。
2. **`/api/briefing` 不做 v3 的“清理 30 天前 dismissed 建议”写操作**：只影响历史行保留，不影响响应形状。
3. **`/summary`、`/draft`、`/inline-images`、`/raw.eml` 恒 503 `provider-not-configured`**：这是 fixtures 钉的形状（v3 的 AI 网关对象即使未配置也存在，先撞 provider 闸门）；`ai-not-configured` 等分支要等 R4 有模型才可达。
4. **`/api/usage` 的 `costTrackingAvailable` 恒 false**：无价目表；`capUSD` 读 `LAGOON_BUDGET_USD_PER_MONTH`（默认 0）。
5. **`search` 的两个参数语义按契约**：`sender` 原样透传（空串会匹配空发件人，与 v3 一致）；`since` 解析失败忽略。
6. **契约回放依赖 python3**：seed 复用 `v4/tests/contract/harness.py`（与 fixtures 同源），缺 python3 时该测试打印 skip 而不是失败；`tests/r2_paths.rs` 提供不依赖 python 的等价覆盖。

## 6. 下一步建议

1. **R3**：IMAP/SMTP + 写路径（归档/删除/回复/撤销/置顶），先落 `ai_actions` 审计与撤销存储层；届时把 3 条 `r2_skip` fixtures 纳入断言。
2. **R3 顺手补**：`lagoon_cipher_contains` 不需要下推，但 `/api/search` 可以加 `sender` 的集成用例（现在只有单元级覆盖）。
3. **外壳**：按 ADR 0002 加 `--backend rust|swift`（默认 rust），让 Web 前端切到 Rust 后端做端到端验收。
4. **性能观察点**：`/api/briefing` 的 backlog 与 `/api/search` 的封存臂都走 `received_at` 倒序 LIMIT，v3 的索引已覆盖；R3 引入同步写后需要重新量一次。