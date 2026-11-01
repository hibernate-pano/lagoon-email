# REPORT-R3.4a —— 同步引擎主体（FakeProvider 驱动）

> 范围：`v4/crates/lagoon-api/`。语义照 v3 `Sources/LagoonServer/Sync/SyncEngine.swift`；真实 IMAP 留 R3.4b。
> 约束遵守：只写本 crate；零外联；未改 lagoon-mail / shell / v1。

## 1. 交付物

| 文件 | 说明 |
|---|---|
| `src/sync/mod.rs` | `SyncCursor`（uidValidity/lastUid 的读写与合并）、`SyncEngine`（单轮语义、退避、单写者）、`SyncSupervisor`（每账号循环 + 立即触发） |
| `src/provider/mod.rs` | 新增 `RemoteHeader`、`MailChangeSet`、`MailProvider::pull_changes`（同步只读面：只有 probe + pull，没有任何写动词） |
| `src/provider/fake.rs` | `FakeProviderFactory::scripted(rounds)`：每轮弹一个脚本结果，并记录实际收到的 cursor |
| `src/store/write.rs` | `credentials`、`delete_live_rows`、`reconcile_inbox`（逐条对齐 v3 MessageStore） |
| `src/http/routes_r3.rs` | `POST /api/sync` → 立即 204，后台触发每账号一轮 |
| `src/http/mod.rs` | `AppState.sync`；`with_provider_factory` 同步重建 supervisor |
| `src/main.rs` | 启动时 `start_all()`（无 provider 的账号不起循环） |
| `tests/r3_sync.rs`（7 条） | 首次 10 → 增量 2、UIDVALIDITY 重置、退避/降级、认证停车、双账号隔离与并发、header-only 列表、POST /api/sync 204 |

## 2. 与 v3 的语义对应

| v3 | Rust |
|---|---|
| 每账号一个 `AccountSyncLoop`，每轮重读账号行 | `SyncEngine::round(account_id)` 每轮重新 `accounts::find` + 读 `sync_state` |
| cursor = `uidValidity` + `lastUid`，持久化在 `accounts.sync_state` | `SyncCursor` 只合并这两个键，保留 `sentFolder`/`archiveFolder`/`historyFloorUid` 等其它键 |
| `resetRequired` → `deleteLiveRows`（只删 live：`is_archived=0 AND is_deleted=0 AND is_sent=0`）再全量 upsert | `write::delete_live_rows` + 逐条 `upsert_header`；归档/垃圾箱行不动 |
| `reconcileInbox(keeping/archived/trashed/removing)`：就地改标或只删“确认已消失”的行 | `write::reconcile_inbox`，语义逐条相同（位置未知的行保留） |
| 失败退避：`min(300, 2^(n-1))` ±20% 抖动，≥3 次转 `degraded` | `backoff_seconds(consecutive)`，单测断言 1s/2s/4s 区间与上限 360s |
| `authFailed`/`notConfigured` → `needsReconnect` 并停车 | `Parked(NeedsReconnect)`，health `needsReconnect` + label |
| 每账号独立 loop，互不阻塞 | supervisor 每账号一个 task；并发 round 测试证明互不干扰 |
| 单写者（每个 loop 一个连接，写串行） | 引擎内 `tokio::sync::Mutex` 覆盖 apply 段（wipe→upsert→cursor 一步不插队） |
| `POST /api/sync` = requestImmediateSync，不等待 | 204 先返回，`trigger_all()` 在后台 spawn |

## 3. 验证证据（真实输出）

### 3.1 构建与测试

```text
$ cargo build -p lagoon-api --offline     → 0 warning
$ cargo test  -p lagoon-api --offline     → 74 passed, 0 failed
   42 单测 + 48 契约回放 1 + dev_store 1 + migrations 5 + r2_paths 5
   + r3_accounts 6 + r3_sync 7 + read_paths 7
```

R3.4a 的 7 条同步测试：
```text
test first_batch_then_incremental_resumes_from_the_cursor ... ok
test uidvalidity_change_resets_live_rows_without_duplicates ... ok
test transient_failures_back_off_and_escalate_to_degraded ... ok
test an_auth_failure_parks_the_account ... ok
test accounts_are_isolated_and_concurrent_rounds_apply_cleanly ... ok
test a_header_only_account_appears_in_the_account_and_message_lists ... ok
test post_api_sync_answers_204_without_waiting ... ok
```

### 3.2 契约

```text
$ bash v4/crates/lagoon-api/scripts/contract-check-r2.sh
SKIP  read.mark-read / read.recorded / pin.set  (r2_skip：写路径)
48/48 fixtures match (3 skipped)
```

### 3.3 回归脚本

```text
$ bash v4/crates/lagoon-api/scripts/verify-r3.2.sh
sqlite_master: 30 objects identical (14 tables, 16 indexes)
grdb_migrations: 11 identifiers identical (lagoon-v1 ... lagoon-v10)
PASS: schema identical, migrations identical, v3 accepts the Rust store and attempts a sync

$ bash v4/crates/lagoon-api/scripts/verify-r3.3.sh
PASS: credential cipher interoperates both ways, and v3 uses a Rust-written account
```

## 4. 顺带修掉的两个环境问题（都不是 R3.4a 代码差异）

1. **dev 库不再是空库**：`v4/.dev/data/lagoon.sqlite` 现在有 2 个账号、5 条 header、2 个 pin（其它任务的 sidecar 跑过）。`contract-check-r2.sh` 原来用 SQLite backup 整库复制 schema 源，会把数据也拷进去、再被 harness seed 叠加，导致 15 条 fixtures 红（多余 pin/header）。修复：改为**只复制 schema**（sqlite_master 的 CREATE + `grdb_migrations` 的 identifier 行）。
2. **harness.py 比 fixtures.json 新**：15:09 时 scouter 在 seed 里加入了第三个账号 `contract-fixture-c`（为后续 fixtures 准备），而 fixtures.json 仍是 51 条、seed 只认 A/B，导致 `accounts.list` 期望 2 条、实际 3 条。修复：本地契约回放与 `contract-check-r2.sh` 在 seed 后按 fixtures 的 seed 块**裁掉未列出的账号**（级联删除其数据），使“fixtures 文件是本次回放的唯一判据”。修后 48/48 恢复。

两条都记在这里，避免下一个人再踩。

## 5. 已知边界与下一步

1. **真实 provider 未接**：`NoProviderFactory` 下 `start_all()` 不启动任何循环（否则会把只读部署的 health 改写成 no-provider）；接 lagoon-mail 时用 `AppState::with_provider_factory`，循环自动出现。
2. **POST /api/sync 只触发一轮**：v3 是重启所有 loop；R3.4a 以“每账号跑一轮”等价（循环本身在 start_all 里），避免测试里的长驻任务不确定性。
3. **写连接仍按需打开**：同步 round 每轮打开一个写连接；R3.4b 若同步频率上来再换池。
4. **Sent 文件夹扫描**：只实现 `replied_message_ids` 的落库（`send` + `sentFolder` 标记），没有实现 v3 的 Sent UID cursors（R3.4b 接 IMAP 时一起）。
5. **日志**：`sync.applied / sync.reset / sync.failed / sync.needsReconnect / sync.accountMissing` 与 v3 同名，方便对照。
