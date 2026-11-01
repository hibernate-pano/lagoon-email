# REPORT-R3.4b-1 —— 接线策略 + lagoon-mail 适配层测试

> 状态：**完成**。范围 `v4/crates/lagoon-api/`；未改 lagoon-mail / shell / v1。
> 本轮只做“接线 + 适配层测试”，成员填充（每轮 3 条连接）按 lead 安排留给 R3.4b-2，未实现。

## 1. 交付物

| 文件 | 说明 |
|---|---|
| `src/provider/lagoon_mail.rs` | 生产适配层：`LagoonMailFactory::production()` 用 lagoon-mail 的 `TlsTransport`（隐式 TLS 993/465 + 平台信任库，证书验证在 lagoon-mail）；`with_transport()` 供脚本化测试注入 |
| `src/main.rs` | `LAGOON_MAIL_PROVIDER` 开关：缺省/空 = `none`（`NoProviderFactory`，契约测试永不联网）；`production` = 安装真实适配层；其他值拒绝启动 |
| `tests/support/scripted_transport.rs` | 从 lagoon-mail 的 `tests/support/mod.rs` 抄来的测试脚手架（ScriptedTransport + imap_session_script/select_script），只作测试用 |
| `tests/r3_provider.rs`（7 条） | probe 三态能力、AuthFailed/Unreachable 映射、pull cursor/upsert/reset 映射、HTTP 201/401/502/503 矩阵 |

## 2. 接线语义

- `AppState::new` 默认仍是 `NoProviderFactory`（**读面/契约测试永不联网**）。
- 只有 `main` 读 `LAGOON_MAIL_PROVIDER`：
  - 未设置或 `none` → 不安装 provider；`start_all()` 不启动任何同步循环；
  - `production` → `state.with_provider_factory(Arc::new(LagoonMailFactory::production()))`，同步循环随之上线；
  - 其他 → 启动失败：`unknown LAGOON_MAIL_PROVIDER="bogus": use none or production`（实测）。
- 适配层不复制任何协议代码：TLS、IMAP 命令、charset、角色发现都在 lagoon-mail；这里只做错误码映射（AuthFailed→401、NotConfigured→503、Unreachable→502、其余→Protocol）、能力三态转换、cursor 映射。

## 3. 验证证据（真实输出）

```text
$ cargo build -p lagoon-api --offline
warning 行数: 0

$ cargo test -p lagoon-api --offline
unittests src/lib.rs        test result: ok. 44 passed
tests/contract_replay.rs    test result: ok. 1 passed      # 53/53 fixtures
tests/dev_store.rs          test result: ok. 1 passed
tests/migrations.rs         test result: ok. 5 passed
tests/r2_paths.rs           test result: ok. 5 passed
tests/r3_accounts.rs        test result: ok. 6 passed
tests/r3_provider.rs        test result: ok. 7 passed      # 本轮新增
tests/r3_sync.rs            test result: ok. 7 passed
tests/read_paths.rs         test result: ok. 7 passed
合计 83 passed, 0 failed

$ bash v4/crates/lagoon-api/scripts/contract-check-r2.sh
53/53 fixtures match (3 skipped)
```

R3.4b-1 的 7 条用例：
```text
test probe_negotiates_capabilities_through_the_adapter ... ok
test probe_maps_auth_failure_and_unreachable ... ok
test pull_changes_maps_cursor_and_upserts ... ok
test pull_changes_maps_reset_required ... ok
test http_connect_returns_201_on_success_and_401_on_auth_failure ... ok
test http_connect_returns_502_when_unreachable ... ok
test http_connect_returns_503_when_no_provider_is_configured ... ok
```

脚本化对话全部来自 lagoon-mail 的 ScriptedTransport：probe 脚本 = 问候 + AUTHENTICATE + CAPABILITY + LIST + SELECT；401 = `NO [AUTHENTICATIONFAILED]`；502 = transport 读失败（Io）；pull = SELECT(UIDVALIDITY 7/UIDNEXT 20) + UID FETCH 头部 literal，断言 `last_uid=19`、reset 轮 `uid_validity=99`、`upserts[0].subject=Hello`。

## 4. 契约环境修正（顺带）

- `contract-check-r2.sh` 的 seed 后裁剪账号现在识别 `accountIdC`（fixtures v3 的 seed 有 A/B/C 三个账号）；并且启动 Rust 实例时补 `LAGOON_TOKEN_KEY`（账号写路由需要）。
- 修后 **53/53** 全绿；`accounts.imap.exists` 的 pre-hook `restore-account-c-ok` 由 harness 执行，Rust 回放已通过。

## 5. 已知边界

1. **成员填充未实现**（按计划留 R3.4b-2）：`pull_changes` 的 `inbox/archived/trashed/removed` 都是 `None`，未知不删任何行；适配层里 `membership()/discover_roles_in()` 已备好但未接线（标了 TODO 与 dead_code 说明）。
2. **生产默认仍是 none**：要真实连 QQ 必须显式 `LAGOON_MAIL_PROVIDER=production`；这是为了契约/CI 永不联网。
3. **NotConfigured 的线级用例**：通过适配层单测（`error_kinds_map_to_the_provider_codes`）覆盖；脚本化 503 用例使用 `NoProviderFactory`，两种 503 路径都有断言。
4. **SMTP** 不在本轮（lagoon-mail 有 SmtpClient，等写路径/发送路由再接）。
