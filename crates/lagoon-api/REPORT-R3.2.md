# REPORT-R3.2 —— v3 迁移链的 Rust 等价实现 + 可写 store

> 范围：`v4/crates/lagoon-api/`。目标不是“能写”，而是**证明等价**：
> Rust 建的库对 v3.2.0 必须与 v3 自己建的库逐字节一致。
>
> 约束遵守：只写本 crate；测试零外联（全部临时文件 + 本机回环）；未改 v1 / shell / lagoon-mail。

## 1. 交付物

| 文件 | 说明 |
|---|---|
| `src/migrations.rs`（433 行，生成） | 11 条迁移的 SQL 原文（48 条语句），由 `scripts/gen-migrations.py` 从 `Sources/LagoonKit/LagoonDatabase.swift` 生成 |
| `src/store/migrate.rs` | 迁移引擎：GRDB 记录表、每迁移一个事务、三个数据步骤（账号 id 修复、正文封存、草稿封存） |
| `src/store/write.rs` | 可写 store：账号 / 表头 / 封存正文 / pin / capabilities / sync_state / 审计 / 草稿 |
| `src/db.rs` | `open_writable`（服务本身仍只读打开，只有 `--migrate` 走写连接） |
| `src/main.rs` | `--migrate` 模式：建库/升级到 lagoon-v10 后退出，不绑定端口 |
| `examples/fake_account.rs` | 用可写 API 写一个假账号，供 v3 打开验证 |
| `scripts/verify-r3.2.sh` | 一键证明：Rust 库 vs v3 库 dump diff + v3 打开 Rust 库跑 `/api/accounts` |
| `tests/migrations.rs`（5 条） | golden schema 对比、幂等、可写路径回读、v6 封存、folder role 合并 |
| `tests/golden/v3-schema.json` | 真 v3.2.0 空库的 sqlite_master + grdb_migrations 快照（30 对象 / 11 条记录） |

## 2. 迁移实现的关键决定

**2.1 DDL 不手抄，生成。**
SQLite 把 `CREATE` 语句的**原文**存进 `sqlite_master`（连注释和缩进都保留）。手抄 220 行 DDL 迟早会差一个空格，而那就是 schema 差异。所以：

```text
Sources/LagoonKit/LagoonDatabase.swift  →  scripts/gen-migrations.py  →  src/migrations.rs
```

生成器做三件容易做错的事：
1. 按 Swift 多行字符串的规则（以结束 `"""` 的缩进为基准）反缩进；
2. **只按真正的语句结尾分号切分**——DDL 注释里有一个分号（“is not in the predicate; the archived view…”），朴素 split 会切坏语句（第一次运行就因此报了 `near "is_archived": syntax error`）；
3. 用 Rust raw string 原样输出，不转义、不折叠空白。

**2.2 GRDB 记录表必须是 GRDB 的形状。**
v3 判断“已迁移到 v10”读的是 `grdb_migrations(identifier)`。Rust 用同一条 `CREATE TABLE` 建它，并按注册顺序写入 11 个 identifier。实测 v3 打开 Rust 库后没有要求任何迁移（见 §3.2）。

**2.3 三个数据步骤也移植了，不是只跑 DDL。**
- `lagoon-v5b`：账号 id 从 TEXT 编码改回 16 字节 BLOB（父行 + 8 张子表一起改；会导致 `(account_id, remote_id)` 冲突的行跳过，与 v3 一样不删数据）。
- `lagoon-v6`：把仍是明文的 `message_bodies.body_cipher/body_html_cipher` 与 `message_headers.snippet_cipher` 封成 `lgb1:`；**没有 body key 时 fail-closed**（删正文缓存、清 snippet），与 v3 一致。
- `lagoon-v9`：草稿 variants 若还是明文 JSON 数组，整组封存；无 key 时删除（可再生成）。

**2.4 事务边界。**
每条迁移 = 一个事务：DDL + 数据改写 + `grdb_migrations` 行要么全落、要么全不落。第二次 `--migrate` 是 no-op（`already_present = 11`）。

## 3. 验证证据（真实输出）

### 3.1 构建与测试

```text
$ cd v4/crates && cargo build --offline
warning 行数: 0

$ cargo test --offline
unittests src/lib.rs        test result: ok. 39 passed; 0 failed
tests/contract_replay.rs    test result: ok. 1 passed; 0 failed     # 48/48 契约仍全绿
tests/dev_store.rs          test result: ok. 1 passed; 0 failed     # (c) Rust 仍能读 v3 的库
tests/migrations.rs         test result: ok. 5 passed; 0 failed     # R3.2 新增
tests/r2_paths.rs           test result: ok. 5 passed; 0 failed
tests/read_paths.rs         test result: ok. 7 passed; 0 failed
合计 58 条，0 失败。
```

### 3.2 一键等价证明（`bash v4/crates/lagoon-api/scripts/verify-r3.2.sh`）

```text
== creating the Rust store
/tmp/.../rust.sqlite: applied 11 migration(s): lagoon-v1, lagoon-v2, lagoon-v3, lagoon-v4,
                     lagoon-v5, lagoon-v5b, lagoon-v6, lagoon-v7, lagoon-v8, lagoon-v9, lagoon-v10

== writing a fake account through the writable store
   account id: 11111111-1111-4111-8111-111111111111

== (a) sqlite_master + grdb_migrations diff
sqlite_master: 30 objects identical (14 tables, 16 indexes)
grdb_migrations: 11 identifiers identical (lagoon-v1 ... lagoon-v10)

== (b) v3 opens the Rust store and answers /api/accounts
v3 sees the Rust-written account: email=fake-r3-account@example.invalid syncHealth=needsReconnect

PASS: schema identical, migrations identical, v3 accepts the Rust store and attempts a sync
```

说明：
- 30 个对象 = v3 建库真实对象数（41 减去 11 个 `sqlite_autoindex_*` 隐式索引，任务允许规范化）；
- `syncHealth=needsReconnect` 正是“**一次同步尝试**”的证据：假账号的凭据不可用，v3 的同步循环真的跑到了 IMAP 并失败，而不是把账号当成不存在；
- `/api/accounts` 能列出 Rust 写的账号，说明 v3 不仅“打开了文件”，而且把 schema、迁移记录、账号行都当成了自己的。

### 3.3 反向兼容（c）

`tests/dev_store.rs` 仍然直接打开 v3 边车真实迁移过的 `v4/.dev/data/lagoon.sqlite`（只读）并服务 `/api/accounts`、`/api/messages` 等——见 3.1 的 `test result: ok. 1 passed`。

### 3.4 可写路径（单测覆盖，未接 HTTP）

`tests/migrations.rs::write_paths_round_trip_through_the_read_store` 一条用例串起全部写 API，并用**只读层回读**证明写出来的东西正是读接口要的样子：

```text
upsert_account（同 provider+oauth_user 二次 upsert 保留原 id，邮箱被更新）
set_account_active(true)
set_folder_role("archiveFolder", true) → capabilities.archiveFolder == true
set_folder_role("archiveFolder", None)  → 恢复未探测（None）
update_sync_state(cursor, needsReconnect, lastSyncAt, lastSyncError)
upsert_header（snippet 已封存）→ messages::find 读回 subject
save_body（正文/HTML 封存）→ bodies::find + BodyKey.open == 原文
set_pinned(true/false) → briefing::pinned_ids 跟随
record_action + record_undo → actions::page 只显示 undo（v3 的“撤销替换原动作”语义）
save_draft（整数组封存）→ drafts::list 读回 ["one","two"]
delete_account → message_headers/message_bodies/draft_replies/ai_actions/message_pins 全部级联清零
```

## 4. 已知边界（R3.2 有意为之）

1. **HTTP 写路由尚未暴露**：可写 store 是库函数，R3.3 再接 `POST /api/messages/*` 等路由。任务要求“先以单测覆盖（不急着接 HTTP）”，已照办。
2. **迁移的数据修复只在单测与真实旧库上验证**：`lagoon-v5b` 的冲突跳过策略与 v3 相同（跳过而不是删除），日志里没有单独计数（v3 会打 warning）；R3.4 可补可观测性。
3. **`--migrate` 是显式模式**：正常服务启动仍然 `SQLITE_OPEN_READ_ONLY` + `PRAGMA query_only`，不会误写生产库。
4. **WAL**：`open_writable` 设 `journal_mode=WAL`（v3 同款）。对比 dump 时 sqlite3 会读 WAL，两边一致。
5. **`draft_replies` 是 append-only**：没有 `(account_id, remote_id)` 唯一约束，所以保存草稿是 INSERT 而不是 upsert（写错会直接报 constraint 错，单测跑出来过）。

## 5. 下一步

- **R3.3**：把 `store::write` 接到 HTTP 写路由（archive/read/pin/delete/reply），补 3 条 `r2_skip` fixtures 的断言。
- **R3.4**：IMAP/SMTP；`upsert_header`/`save_body` 直接复用。
- **R3.5**：外壳 `--backend rust|swift` 切换；Rust 建库后可直接让 v3 读（本任务已证明），便于灰度期双跑。
