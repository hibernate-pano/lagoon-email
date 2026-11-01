# REPORT-R3.4b-2b —— 成员集合并入 pull 会话（4 条连接 → 1 条）

> 状态：完成。只写 `v4/crates/lagoon-api/`；IMAP 全部留在 lagoon-mail。

## 1. 改动

`src/provider/lagoon_mail.rs` 的 `pull_changes`：

- 删除旧的 `membership(folder)` / `discover_roles_in(...)` 实现（它们每轮额外开 3 条连接，每条都重新 LOGIN）。
- 改为在**同一条已登录会话**上、`provider.pull_changes(...)` 之后直接调用
  `provider.remote_membership()`（lagoon-mail 的 API；内部 LIST/SELECT/UID SEARCH ALL/Message-ID 映射都在 lagoon-mail）。
- 映射：`RemoteMembership::inbox_remote_ids()` / `archived_remote_ids()` / `trashed_remote_ids()` → 适配层 `MailChangeSet` 的同名集合。
- `reset_required` 轮不调用 remote_membership：UID 空间已换代，旧成员集合没有意义，全部保持 `None`（未知）。
- 任一目录返回 `None`（不存在/无权限/超预算/失败）就保持 `None`：引擎只在三个集合都 `Some` 时才推导删除，未知不删任何本地行（v3 语义）。
- 适配层现在不再出现任何 `ImapClient::select` / `UID SEARCH` 调用；`grep 'ImapClient' src/provider/lagoon_mail.rs` 为空。

## 2. 连接数证明（脚本化传输的 connect_count）

`tests/r3_provider.rs::pull_changes_fills_membership_on_the_same_session`：

```text
test result: ok. 9 passed; 0 failed
...
assert_eq!(transport.connect_count(), 1, "one login per round");
```

- 改动前：一轮 = pull 1 条 + INBOX/archive/trash 各 1 条 = **4 条连接**；
- 改动后：pull + remote_membership 全在同一条会话 = **1 条连接**（断言通过）。
- 另有 `a_reset_round_skips_membership_and_keeps_one_connection`：reset 轮同样只开 1 条连接，且三个集合都是 `None`。

## 3. 验证证据（真实输出）

```text
$ cargo build -p lagoon-api --offline      → 0 warning
$ cargo test  -p lagoon-api --offline      → 85 passed, 0 failed
  （44 单测 + 53 条契约回放 1 + dev_store 1 + migrations 5 + r2_paths 5
    + r3_accounts 6 + r3_provider 9 + r3_sync 7 + read_paths 7）
$ bash v4/crates/lagoon-api/scripts/contract-check-r2.sh
53/53 fixtures match (3 skipped)
```

r3_provider 现有 9 条：
```text
probe_negotiates_capabilities_through_the_adapter
probe_maps_auth_failure_and_unreachable
pull_changes_maps_cursor_and_upserts
pull_changes_maps_reset_required
pull_changes_fills_membership_on_the_same_session     # 本轮新增
a_reset_round_skips_membership_and_keeps_one_connection # 本轮新增
http_connect_returns_201_on_success_and_401_on_auth_failure
http_connect_returns_502_when_unreachable
http_connect_returns_503_when_no_provider_is_configured
```

## 4. 边界

1. 脚本化用例目前只把 INBOX 的成员写进会话脚本，archive/trash 在该用例里因脚本结束而返回 None（同一 API 路径，真实会话会正常填充）；真实邮箱只在用户授权后手动验。
2. 成员失败一律 `None`，不会让整轮失败（`remote_membership` 内部吞掉文件夹级失败并按三态返回）。
3. 引擎的删行条件仍是“三个集合都已知”，见 `src/sync/mod.rs` 的 apply：未知集合不删行。
