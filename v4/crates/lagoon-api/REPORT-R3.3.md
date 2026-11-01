# REPORT-R3.3 —— 账号生命周期 + provider 缝

> 范围：`v4/crates/lagoon-api/`。目标：把 R3.2 的可写 store 接到 HTTP，完成账号的连接/选择/删除，并把 provider 定义成一个可替换的缝。
> 约束遵守：只写本 crate；测试零外联（本机回环 + 临时文件）；未改 lagoon-mail / shell / v1。

## 1. 交付物

| 文件 | 说明 |
|---|---|
| `src/token.rs` | `AccessTokenCipher` 的 Rust 实现：**裸** AES-256-GCM combined（12B nonce‖ct‖16B tag，无 `lgb1:`），key=`LAGOON_TOKEN_KEY`；`ImapCredentials` 的 JSON 形状与 v3 `AccountCredentials` 一致 |
| `src/provider/mod.rs` | `ProviderFactory` / `MailProvider` / `ProbeOutcome` / `ProviderError`；生产默认 `NoProviderFactory`（返回 None → 503），lagoon-mail 适配层留 `TODO(R3.4)`，未复制任何协议代码 |
| `src/provider/fake.rs` | `FakeProviderFactory`：把成功/认证失败/不可达/未配置四种结局脚本化，并记录实际探测用的凭据 |
| `src/http/routes_r3.rs` | `POST /api/accounts/imap`、`POST /api/accounts/{id}/activate`、`DELETE /api/accounts/{id}` |
| `src/store/write.rs` | 新增 `update_credentials` / `update_health` / `set_active` / `reconcile_active` |
| `src/store/accounts.rs` | `find_by_oauth_user`、`sync_state_json` |
| `src/config.rs` | 新增可选 `LAGOON_TOKEN_KEY`（格式错拒绝启动；缺失时账号写路由拒绝封存） |
| `src/http/mod.rs` | `AppState` 增加 `token_key` 与 `provider_factory`，写连接按需打开 |
| `tests/r3_accounts.rs`（6 条） | 覆盖全部状态码、三态能力、重认证、失败不动行、激活/删除级联 |
| `scripts/token-tool.swift` + `examples/token_tool.rs` | 跨实现互解工具（CryptoKit ↔ Rust） |
| `scripts/verify-r3.3.sh` | 一键证明：双向互解 + v3 使用 Rust 写的账号 + 负向对照 |

## 2. 凭据封存：逐字节同格式

v3 的 `AccessTokenCipher` 是 **裸** `AES.GCM.SealedBox.combined`：nonce 12 字节 + 密文 + 16 字节 tag，直接存 BLOB，**没有** `lgb1:` 前缀、不是 base64。key 是 `LAGOON_TOKEN_KEY`（base64 的 32 字节），与 body key 是两把钥匙。明文是：

```json
{"kind":"imap","username":"…","authCode":"…"}
```

Rust 实现要点：
- `TokenKey::seal` 生成 12 字节随机 nonce，输出 `nonce‖ct‖tag`；
- `TokenKey::open` 先检查 `len >= 28`，切分 nonce 后交给 AES-GCM；
- 与 `BodyKey` 完全分离：单测 `the_body_key_is_not_the_token_key` 断言一个产出 `lgb1:`、另一个不产出。

**跨实现测试**（`token.rs::opens_a_blob_produced_by_cryptokit`）：把 CryptoKit 现场生成的 blob（base64）作为常量，Rust 解开并断言等于原始 JSON；另由 `verify-r3.3.sh` 做双向验证（见 §4）。

## 3. 路由与状态矩阵

| 请求 | 状态码 | 说明 |
|---|---|---|
| `POST /api/accounts/imap` 空 body | 400 `missing-field` | **实测修正**：v3 的 `collectBody` 对空 body 成功返回 0 字节，是解码失败 → missing-field；`missing-body` 只用于读取 body 流出错 |
| `POST /api/accounts/imap` 缺字段/空值/provider≠qq | 400 `missing-field` | email/authCode 先 trim 再判空（剪贴板换行） |
| 已存在且 `syncHealth==ok` | 409 `account-exists` | **探测之前**返回，不建 provider |
| 探测认证失败 | 401 `imap-auth-failed` | |
| 探测不可达/协议错 | 502 `imap-unreachable` | |
| 无 provider（NoProviderFactory） | 503 `provider-not-configured` | |
| 探测成功（新账号） | 201 `ConnectedAccount` | 写凭据/能力/sync_state，并 `setActive` |
| 探测成功（既有但非 ok） | 201 同一 id | 只换凭据/能力/archiveFolder，健康恢复 `ok`、`lastError=nil`；**探测失败则整行不动** |
| `POST /api/accounts/{id}/activate` | 204 / 404 | 非法 uuid 也是 404（v3 语义） |
| `DELETE /api/accounts/{id}` | 204 / 404 | 外键级联；删后 `reconcileActive` 提升最近更新的账号 |

**与真 v3 的对拍**（同一份 seed、两边各起进程，2026-10-29）：

```text
v3:   empty body        -> 400 {"error":"missing-field"}
      missing field     -> 400 {"error":"missing-field"}
      activate unknown  -> 404 {"error":"unknown-account"}
      delete unknown    -> 404 {"error":"unknown-account"}
rust: empty body        -> 400 {"error":"missing-field"}
      missing field     -> 400 {"error":"missing-field"}
      activate unknown  -> 404 {"error":"unknown-account"}
      delete unknown    -> 404 {"error":"unknown-account"}
```

注：`existing healthy` 一项没能在真 v3 上复现 409 —— v3 启动后先跑同步，seed 账号的不可用凭据让它落到 `needsReconnect`，于是 POST 走的是重认证分支并 401；Rust 的只读副本没有同步循环，行仍是 `ok`，所以 409。**分支顺序两边一致**（健康检查先于探测），fixture 若需要 409 应由 scouter 用“ok 且未跑同步”的库抓。

## 4. 验证证据（真实输出）

### 4.1 构建与测试

```text
$ cargo build -p lagoon-api --offline     → 0 warning
$ cargo test  -p lagoon-api --offline
unittests src/lib.rs        test result: ok. 42 passed
tests/contract_replay.rs    test result: ok. 1 passed      # 48/48 契约不受影响
tests/dev_store.rs          test result: ok. 1 passed
tests/migrations.rs         test result: ok. 5 passed
tests/r2_paths.rs           test result: ok. 5 passed
tests/r3_accounts.rs        test result: ok. 6 passed      # R3.3 新增
tests/read_paths.rs         test result: ok. 7 passed
合计 67 条，0 失败。
```

### 4.2 `bash v4/crates/lagoon-api/scripts/verify-r3.3.sh`

```text
== (1a) CryptoKit opens a blob sealed by this crate
   ok: {"kind":"imap","username":"cross@example.invalid","authCode":"cross-code"}
== (1b) this crate opens a blob sealed by CryptoKit
   ok: {"kind":"imap","username":"cross@example.invalid","authCode":"cross-code"}
== (2) v3 opens a store written by this crate and uses its account
   account id: bba76e8c-…
   v3 sees the account: syncHealth=needsReconnect
   ok: v3 decrypted the credentials (no not-configured in its log)
== (3) negative control: a garbage credential blob is 'not-configured'
   ok: the control reports not-configured, so check (2) is meaningful
PASS: credential cipher interoperates both ways, and v3 uses a Rust-written account
```

第 3 步是这次验证的关键设计：v3 在凭据解不开时同样会把账号标 `needsReconnect`，只看状态码无法区分“解开了但 IMAP 连不上”和“根本没解开”。负向对照证明日志标签不同，因此第 2 步的通过是真实的。

## 5. 能力探测与三态

- `ProbeOutcome.capabilities: Option<MailCapabilities>`：`None` = 协商未完成，**不落库**（保留旧值）；`Some` 才写。
- `MailCapabilities` 的 `archiveFolder/uidplus/sentFolder/trashFolder` 是 `Option<bool>`，序列化时 `None` 缺键（三态）；`idle/move/serverSnippet` 是普通 bool。
- `archiveFolder()` 解析出的远端文件夹名合并进 `sync_state.archiveFolder`（保留既有 cursor 字段）。
- 测试 `connect_creates_the_account_and_seals_its_credentials` 断言 `archiveFolder=true, sentFolder=false, trashFolder 缺键`。

## 6. 已知边界与下一步

1. **真实 provider 未接入**：`NoProviderFactory` 恒返回 None；`lagoon-mail` 的适配层是 R3.4，接线点就是 `AppState::with_provider_factory`。没有复制任何 IMAP 代码。
2. **写连接每请求打开一次**：R3.3 写流量只有账号操作，先按需开；R3.4 若写路由变多再换池。
3. **契约 fixtures 暂无账号路由条目**：`fixtures.json` 仍 51 条（无 `accounts.imap.*`）。400/409/404 的语义已用真 v3 手工对拍并写进本报告；建议 scouter 补 `accounts.imap.missing-field`、`accounts.imap.account-exists`（需要“ok 且未同步”的库）。
4. **删除后的 provider 释放**：v3 有 `releaseProvider` 回调关闭 IMAP 会话；R3.3 没有真实 provider，等 R3.4 接线时一起接。
5. **`LAGOON_TOKEN_KEY` 缺失**：读接口不受影响；连接账号返回 500 `internal-error` 并拒绝写入明文凭据（fail-closed）。
