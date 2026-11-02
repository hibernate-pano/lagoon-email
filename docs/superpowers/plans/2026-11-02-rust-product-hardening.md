# Lagoon Rust 产品加固与补全 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 Rust 版 Lagoon 从「测试全绿但产品不可用」修到「三条核心承诺真的成立」：能读信、能撤销、能持续同步；同时把造好没插上的能力接上、把安全洞堵上、把工程卫生的闸门立起来。

**Architecture:** 后端保持 `crates/lagoon-api`（axum + rusqlite）+ `crates/lagoon-mail`（IMAP/SMTP/MIME）两层，`ProviderFactory` 是唯一的协议缝。三个 P0 各自只动一个文件：撤销逆操作在 `http/routes_r5.rs`、同步循环生命周期在 `sync/mod.rs`、正文惰性抓取在 `provider/mod.rs` + `http/routes.rs`。能力接线（IDLE、手动同步、错误码字典）只改适配层与前端，不动协议层。安全修复在 `shell/`（端口分配改为后端自绑）与 `http/guard.rs`。

**Tech Stack:** Rust 2021 / axum 0.8 / rusqlite 0.41 / tokio 1.54 / Tauri 2 / React 19 + TypeScript 5.9 + Vite 7。

**Spec:** 本文件即 spec。设计尺子见 `docs/V1.0-产品定义与验收标准.md`（v3 时代，需在 Task 12 重写）。

---

## Global Constraints

1. **契约先行。** 端点形状变化 = 先改 `docs/api-contract.md` + `tests/contract/fixtures/fixtures.json`，再改实现。本计划**不新增端点、不改端点形状**，只改端点内部行为，因此不动 fixture。
2. **测试零外联。** 所有协议测试走注入式假传输；`LAGOON_MAIL_PROVIDER` 缺省为 `none`，CI 永不联网。
3. **只读宪法。** 同步路径用无写方法的 trait 表达；写 trait（`MailWriteProvider`）只从动作路由可达。新增的正文 trait 属于**读**，不破坏该宪法。
4. **错误不回显上游文本。** provider 错误一律映射成固定错误码（`api-unauthorized` / `provider-unreachable` / `provider-not-configured` 等）。
5. **鉴权 fail-closed。** 除 `/healthz` 精确匹配外，所有 `/api/*` 必须校验 token。
6. **密钥不落盘于明文以外的位置。** 授权码只以裸 AES-GCM blob 存 `accounts.credentials`。
7. **变异验证。** 每个 P0 的回归测试写完后，必须故意改坏实现确认测试变红，再逐字节还原。
8. **不碰用户真实数据。** 所有验证在临时库/临时端口进行；`~/Library/Application Support/Lagoon-v4/lagoon.sqlite` 只读不改。

## Review Focus

以下五类输入/状况最可能咬人，每条由指定 Task 的测试钉住：

1. **授权码过期后用户重新连接** → 必须恢复同步，且状态不能说谎。→ Task 2
2. **归档 / 删除之后按 ⌘Z** → 远端和本地都必须真的回退，且接口不能回 200 骗人。→ Task 1
3. **邮件正文从未被抓取过**（真实库现状：413 header / 0 body）→ 打开邮件必须能拿到正文并落库缓存。→ Task 3
4. **服务端没有 IDLE 能力**（部分服务器） → 必须退回轮询而不是卡死。→ Task 4
5. **provider 不可用 / 凭据解不开 / 账号不存在** → 正文路由必须分别给出 503 / 503 / 404，不能退化成 500。→ Task 3

---

## File Structure

**本计划新建**

| 文件 | 职责 |
|---|---|
| `crates/lagoon-api/tests/r3_bodies.rs` | 正文惰性抓取的路由级测试（缓存命中 / 缓存未命中抓取 / provider 缺失 / 账号不存在） |
| `crates/lagoon-api/tests/r3_reconnect.rs` | 账号 park → 重新认证 → 同步循环恢复的测试 |
| `web/src/core/__tests__/errors.test.ts` | 错误码字典与后端路由的一致性测试（vitest） |
| `web/src/core/__tests__/selection.test.ts` | `targetIds` 选择模型的纯逻辑测试（vitest） |
| `web/vitest.config.ts` | 前端测试运行器配置（node 环境，jsdom 不需要） |
| `docs/superpowers/plans/2026-11-02-rust-product-hardening.md` | 本文件 |

**本计划修改**

| 文件 | 改动 |
|---|---|
| `crates/lagoon-api/src/http/routes_r5.rs` | 撤销走逆操作；删掉 `BulkBody` 死结构 |
| `crates/lagoon-api/src/sync/mod.rs` | 任务结束移除 handle；`start_one` 清理已结束 handle；`start_all`/`start_one` 抽公共循环 |
| `crates/lagoon-api/src/provider/mod.rs` | 新增 `MailBody` / `MailBodyProvider` / `BodyFuture`；`ProviderFactory::make_body` |
| `crates/lagoon-api/src/provider/fake.rs` | 假正文 provider + 脚本化正文 |
| `crates/lagoon-api/src/provider/lagoon_mail.rs` | 真实正文 provider；`pull_changes` 传 `IDLE_BUDGET` |
| `crates/lagoon-api/src/http/routes.rs` | 正文路由缓存未命中时惰性抓取并落库 |
| `crates/lagoon-api/src/http/mod.rs` | `AppState::body_provider` 辅助方法 |
| `crates/lagoon-api/src/http/guard.rs` | token 缺失时 fail-closed |
| `crates/lagoon-api/src/config.rs` | 缺 token 时非 loopback 拒绝启动（已有），loopback 也拒绝 |
| `shell/src/port.rs` | 删掉自由端口 TOCTOU：改为后端自绑 `--port 0` + 读 stdout |
| `shell/src/sidecar.rs` | 从后端 stdout 解析实际端口后再握手 |
| `shell/tauri.conf.json` | 加 CSP |
| `web/src/core/errors.ts` | 错误码字典以 Rust 路由为唯一事实源重写 |
| `web/src/core/writes.ts` | 同步错误码表 |
| `web/src/App.tsx` | 键盘游标可见 + ⌘⌫ 保护 + 空态 + 手动同步入口 |
| `web/src/screens/MessageList.tsx` | 消费 `cursor` prop |
| `web/src/screens/BriefingFeed.tsx` | 接收 `cursor` prop |
| `web/src/ui/MailRow.tsx` | cursor 高亮类 + roving tabindex |
| `web/src/styles/app.css` | `.cursor` 样式 |
| `web/package.json` | 加 `test` 脚本 + vitest 依赖 |
| `.github/workflows/ci.yml` | 加 clippy 闸门 + 前端测试 |
| `README.md` | 按单版本事实重写 |
| `.env.example` | 按代码真实读取的环境变量重写 |
| `docs/V1.0-产品定义与验收标准.md` | 按 Rust 产品重写 |
| `docs/` | v3 时代文档移入 `docs/archive/v3/`；新增 `docs/README.md` 索引 |

---

## Iteration 1 — P0 正确性

### Task 1: 撤销走真正的逆操作

**Files:**
- Modify: `crates/lagoon-api/src/http/routes_r5.rs:770-786`（`undo_one` 的 verb 映射）
- Modify: `crates/lagoon-api/src/http/routes_r5.rs:495-503`（删掉死结构 `BulkBody`）
- Test: `crates/lagoon-api/tests/r3_actions.rs`

**Interfaces:**
- Consumes: `WriteVerb::inverse(self) -> WriteVerb`（已存在于 `routes_r5.rs:227`）、`WriteVerb::remote(&self, &dyn MailWriteProvider, &str)`、`WriteVerb::local(&self, &Connection, Uuid, &str)`
- Produces: 无新接口。撤销行为改为：`"archive"` → `Unarchive`、`"delete"` → `Restore`、`"markRead"` → `SetRead(previousIsRead)`、`"pin"` → `SetPinned(false)`、`"unpin"` → `SetPinned(true)`

- [x] **Step 1: 写会红的测试**

在 `crates/lagoon-api/tests/r3_actions.rs` 新增两个测试。测试用 `prepare_account(&server, &all_caps_allowed())` 准备账号，用 `flag(&server, "is_archived", REMOTE)` 读标志，用 `factory.write_calls().all()` 读远端动词序列。

```rust
#[tokio::test]
async fn undo_of_an_archive_unarchives_locally_and_remotely() {
    let factory = Arc::new(FakeProviderFactory::new(FakeOutcome::succeeds()));
    let (server, _fixtures) = TestServer::spawn_with_provider("r3-actions-undo-archive", factory.clone()).await;
    prepare_account(&server, &all_caps_allowed());
    let client = http::client();

    let observed = post(&client, &server, &format!("/api/messages/{REMOTE}/archive?accountId={ACCOUNT_A}"), None).await;
    assert_eq!(observed.status, 200, "{:?}", observed.body);
    let action_id = observed.body["actionId"].as_i64().expect("actionId");
    assert_eq!(flag(&server, "is_archived", REMOTE), Some(true));

    let observed = post(&client, &server, &format!("/api/actions/{action_id}/undo?accountId={ACCOUNT_A}"), None).await;
    assert_eq!(observed.status, 200, "{:?}", observed.body);
    assert_eq!(observed.body["undone"], json!(action_id));

    // The message comes back - locally AND on the server.
    assert_eq!(flag(&server, "is_archived", REMOTE), Some(false));
    let calls = factory.write_calls().all();
    assert_eq!(calls, vec![("archive".to_owned(), REMOTE.to_owned()), ("unarchive".to_owned(), REMOTE.to_owned())]);
}
```

第二个测试同构，用 `/api/messages/{REMOTE}/delete` + `is_deleted` + 期望动词 `restore_from_trash`，测试名 `undo_of_a_delete_restores_locally_and_remotely`。

- [x] **Step 2: 跑测试确认它变红**

Run: `cargo test --manifest-path crates/Cargo.toml -p lagoon-api --test r3_actions -- --nocapture`
Expected: FAIL —— `is_archived` 实际是 `Some(true)`，远端动词序列是 `[archive, archive]`。

- [x] **Step 3: 实现逆操作**

在 `routes_r5.rs` 的 `undo_one` 里，把 verb 映射改成逆操作。`markRead` 必须继续用 payload 里的 `previousIsRead`（不能用 `inverse()`，因为那是布尔取反而不是恢复旧值）：

```rust
let verb = match action.kind.as_str() {
    "archive" => WriteVerb::Archive.inverse(),
    "delete" => WriteVerb::Trash.inverse(),
    "markRead" => WriteVerb::SetRead(
        payload.get("previousIsRead")
            .and_then(|value| value.as_str())
            .map(|raw| raw == "true")
            .unwrap_or(false),
    ),
    "pin" => WriteVerb::SetPinned(false),
    "unpin" => WriteVerb::SetPinned(true),
    _ => return UndoOutcome::NotUndoable,
};
```

同时删掉 `routes_r5.rs` 里从未被使用的 `BulkBody` 结构体（`parse_bulk` 自己解析 JSON，不用它）。

- [x] **Step 4: 跑测试确认它变绿**

Run: `cargo test --manifest-path crates/Cargo.toml -p lagoon-api --test r3_actions`
Expected: PASS（既有 5 个测试 + 新增 2 个）。

- [x] **Step 5: 变异验证**

把 `"archive" => WriteVerb::Archive.inverse()` 临时改回 `WriteVerb::Archive`，跑 Step 4 的命令，确认 `undo_of_an_archive_unarchives_locally_and_remotely` 变红，然后逐字节还原（`git diff` 应只显示计划内的改动）。

- [x] **Step 6: 提交**

```bash
git add crates/lagoon-api/src/http/routes_r5.rs crates/lagoon-api/tests/r3_actions.rs
git commit -m "fix(undo): 撤销归档/删除走真正的逆操作 —— 之前回 200 但什么都没撤"
```

---

### Task 2: 账号 park 后重新认证要能恢复同步

**Files:**
- Modify: `crates/lagoon-api/src/sync/mod.rs:414-482`（`start_one` / `start_all`）
- Test: `crates/lagoon-api/tests/r3_reconnect.rs`（新建）

**Interfaces:**
- Consumes: `SyncEngine::round(Uuid) -> RoundOutcome`、`RoundOutcome::Parked(_)`
- Produces: `SyncSupervisor::start_one(&self, account_id: Uuid)` 行为变更——账号没有**正在运行**的循环时一定启动一个；`start_all` 与 `start_one` 共用同一个循环体。

- [x] **Step 1: 写会红的测试**

新建 `crates/lagoon-api/tests/r3_reconnect.rs`：

```rust
//! A parked account must come back to life when the user re-authenticates.

mod support;

use std::sync::Arc;
use std::time::Duration;

use serde_json::{json, Value};

use lagoon_api::provider::fake::{FakeOutcome, FakeProviderFactory};
use lagoon_api::provider::{MailChangeSet, ProviderError};

use support::http;
use support::server::TestServer;

#[tokio::test]
async fn re_authenticating_a_parked_account_restarts_its_sync_loop() {
    let factory = Arc::new(FakeProviderFactory::new(FakeOutcome::succeeds()));
    // Round 1 fails auth -> the account parks and the loop ends.
    // Round 2 would succeed if the loop ever restarted.
    factory.pull_rounds(vec![
        Err(ProviderError::AuthFailed),
        Ok(MailChangeSet::default()),
        Ok(MailChangeSet::default()),
    ]);
    let (server, _fixtures) = TestServer::spawn_with_provider("r3-reconnect", factory.clone()).await;
    let client = http::client();
    let auth = server.auth_headers();

    let body = json!({"provider": "qq", "email": "reconnect@example.invalid", "authCode": "code-1"});
    let observed = http::request_with_body(&client, "POST", &format!("{}/api/accounts/imap", server.base_url), &auth, body.to_string().as_bytes()).await;
    assert_eq!(observed.status, 201, "{:?}", observed.body);

    // The first round fails auth and the loop ends.
    wait_for_rounds(&factory, 1).await;
    assert_eq!(factory.cursors().len(), 1);

    // The user re-authenticates.
    let body = json!({"provider": "qq", "email": "reconnect@example.invalid", "authCode": "code-2"});
    let observed = http::request_with_body(&client, "POST", &format!("{}/api/accounts/imap", server.base_url), &auth, body.to_string().as_bytes()).await;
    assert_eq!(observed.status, 201, "{:?}", observed.body);

    // A second round runs: the loop restarted.
    wait_for_rounds(&factory, 2).await;
    assert!(factory.cursors().len() >= 2, "the sync loop never restarted after re-auth");
}

async fn wait_for_rounds(factory: &FakeProviderFactory, at_least: usize) {
    for _ in 0..100 {
        if factory.cursors().len() >= at_least {
            return;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}
```

- [x] **Step 2: 跑测试确认它变红**

Run: `cargo test --manifest-path crates/Cargo.toml -p lagoon-api --test r3_reconnect -- --nocapture`
Expected: FAIL —— `the sync loop never restarted after re-auth`，只跑了 1 轮。

- [x] **Step 3: 实现**

改 `sync/mod.rs`：

1. 抽出公共循环体，两处共用：

```rust
/// The loop body, shared by start_one and start_all.
async fn run_loop(engine: Arc<SyncEngine>, account_id: Uuid) {
    loop {
        match engine.round(account_id).await {
            RoundOutcome::Parked(_) | RoundOutcome::NotFound => break,
            RoundOutcome::Failed { backoff_seconds, .. } => {
                tokio::time::sleep(std::time::Duration::from_secs_f64(backoff_seconds)).await;
            }
            _ => tokio::time::sleep(IDLE_WAIT).await,
        }
    }
}
```

2. `start_one` 的守卫从「map 里有这个 key」换成「这个 key 对应的任务还活着」：

```rust
pub async fn start_one(&self, account_id: Uuid) {
    if !self.engine.has_provider(account_id) {
        return;
    }
    let mut tasks = self.tasks.lock().await;
    if tasks.get(&account_id).is_some_and(|task| !task.is_finished()) {
        return;
    }
    let engine = Arc::clone(&self.engine);
    let task = tokio::spawn(run_loop(engine, account_id));
    tasks.insert(account_id, task);
}
```

3. `start_all` 也用 `run_loop`，并同样跳过已结束的 handle。

- [x] **Step 4: 跑测试确认它变绿**

Run: `cargo test --manifest-path crates/Cargo.toml -p lagoon-api --test r3_reconnect`
Expected: PASS。

- [x] **Step 5: 变异验证**

把 `!task.is_finished()` 改成 `true`（即恢复旧行为），跑 Step 4 的命令，确认测试变红，然后还原。

- [x] **Step 6: 跑全量后端测试确认没有回归**

Run: `cargo test --manifest-path crates/Cargo.toml`
Expected: 全部 PASS，且 `r3_accounts` 里的 connect 测试仍然绿（`start_one` 现在会被调用两次也不会重复起循环）。

- [x] **Step 7: 提交**

```bash
git add crates/lagoon-api/src/sync/mod.rs crates/lagoon-api/tests/r3_reconnect.rs
git commit -m "fix(sync): 账号 park 后重新认证能恢复同步 —— 之前循环死了但状态说 ok"
```

---

### Task 3: 邮件正文惰性抓取接线

**Files:**
- Modify: `crates/lagoon-api/src/provider/mod.rs`（新增正文 trait 与工厂方法）
- Modify: `crates/lagoon-api/src/provider/fake.rs`（假正文 provider）
- Modify: `crates/lagoon-api/src/provider/lagoon_mail.rs`（真实正文 provider）
- Modify: `crates/lagoon-api/src/http/mod.rs`（`AppState::body_provider`）
- Modify: `crates/lagoon-api/src/http/routes.rs:207-283`（正文路由）
- Test: `crates/lagoon-api/tests/r3_bodies.rs`（新建）

**Interfaces:**
- Consumes: `lagoon_mail::imap::provider::ImapProvider::fetch_body(&mut self, &str) -> Result<ParsedMessage, MailError>`；`store::write::save_body(&Connection, &NewBody<'_>, &BodyKey)`；`crate::wire::Attachment`
- Produces:
  - `crate::provider::MailBody { text: String, html: Option<String>, has_more: bool, attachments: Vec<crate::wire::Attachment>, to: Vec<String>, cc: Vec<String> }`
  - `crate::provider::BodyFuture<'a> = Pin<Box<dyn Future<Output = Result<MailBody, ProviderError>> + Send + 'a>>`
  - `trait MailBodyProvider: Send + Sync { fn fetch_body(&self, remote_id: &str) -> BodyFuture<'_>; }`
  - `ProviderFactory::make_body(&self, credentials: &ImapCredentials) -> Option<Arc<dyn MailBodyProvider>>`（默认 `None`）
  - `FakeProviderFactory::body_script(&self, bodies: Vec<Result<MailBody, ProviderError>>) -> &Self`

- [ ] **Step 1: 写会红的测试**

新建 `crates/lagoon-api/tests/r3_bodies.rs`。四个场景：

```rust
//! The body route must fetch a body it does not have, cache it, and answer.

mod support;

use std::sync::Arc;

use serde_json::{json, Value};

use lagoon_api::provider::fake::{FakeOutcome, FakeProviderFactory};
use lagoon_api::provider::{MailBody, ProviderError};
use lagoon_api::token::ImapCredentials;

use support::http;
use support::server::{open_read_write, token_key, TestServer};
```

测试体（逐条写出来）：

1. `a_body_the_store_does_not_have_is_fetched_cached_and_answered`
   - 账号用 `prepare_account` 写进可解开的凭据
   - `factory.body_script(vec![Ok(MailBody { text: "hello body".into(), html: None, has_more: false, attachments: vec![], to: vec![], cc: vec![] })])`
   - 第一次 GET `/api/messages/{REMOTE}/body?accountId={ACCOUNT_A}` → **200**，`body["text"] == "hello body"`
   - 第二次 GET → 仍然 200，且 `factory` 的取数脚本只被消费一次（第二次走缓存）
   - 直接查库：`SELECT count(*) FROM message_bodies` → 1
2. `a_body_fetch_failure_answers_502_and_caches_nothing`
   - 脚本 `Err(ProviderError::Unreachable("boom".into()))` → **502** `provider-unreachable`
   - `SELECT count(*) FROM message_bodies` → 0
3. `an_account_without_readable_credentials_answers_503`
   - 不调用 `prepare_account`（凭据解不开）→ **503** `provider-not-configured`
4. `an_unknown_account_answers_404`
   - 未知 accountId → **404** `unknown-account`

- [ ] **Step 2: 跑测试确认它变红**

Run: `cargo test --manifest-path crates/Cargo.toml -p lagoon-api --test r3_bodies -- --nocapture`
Expected: 编译失败（`MailBody` 还不存在）→ 这就是变红。

- [ ] **Step 3: 实现 provider 缝**

`provider/mod.rs` 新增：

```rust
/// One fetched body, in the shape the store and the wire want.
#[derive(Debug, Clone, Default)]
pub struct MailBody {
    pub text: String,
    pub html: Option<String>,
    pub has_more: bool,
    pub attachments: Vec<crate::wire::Attachment>,
    pub to: Vec<String>,
    pub cc: Vec<String>,
}

pub type BodyFuture<'a> =
    Pin<Box<dyn Future<Output = Result<MailBody, ProviderError>> + Send + 'a>>;

/// The read-only body surface. Separate from MailProvider so a body fetch
/// can never be mistaken for a sync round.
pub trait MailBodyProvider: Send + Sync {
    fn fetch_body(&self, remote_id: &str) -> BodyFuture<'_>;
}
```

`ProviderFactory` 新增默认实现：

```rust
/// The body half. Default None: a build without mail support answers
/// 503 provider-not-configured on the body route.
fn make_body(&self, credentials: &ImapCredentials) -> Option<Arc<dyn MailBodyProvider>> {
    let _ = credentials;
    None
}
```

`fake.rs`：`FakeBodyProvider` 持一份 `VecDeque<Result<MailBody, ProviderError>>` 脚本，`fetch_body` 弹一个；脚本空时返回 `Err(ProviderError::NotConfigured("fake body script exhausted"))`。`FakeProviderFactory` 加 `body_script` 与 `body_calls` 计数。

`lagoon_mail.rs`：`LagoonMailBody` 持 `Arc<Transport>` + `ProviderCredentials` + `ProviderPreset`；`fetch_body` 用 `spawn_blocking` 起 `ImapProvider::new(preset, credentials, transport)`，调 `provider.fetch_body(remote_id)`，把 `ParsedMessage` 转成 `MailBody`（`ParsedAttachment` → `wire::Attachment`，`disposition` 映射 `AttachmentDisposition::Inline → wire::Disposition::Inline`，其余 → `Attachment`）。`LagoonMailFactory::make_body` 返回 `Some(Arc::new(LagoonMailBody { ... }))`。

- [ ] **Step 4: 实现路由惰性抓取**

`http/mod.rs` 给 `AppState` 加：

```rust
/// The body provider for one account, built from its stored credentials.
/// None means "no body can be fetched" - the 503 path.
pub async fn body_provider(&self, account_id: Uuid) -> Option<Arc<dyn crate::provider::MailBodyProvider>> {
    let Some(token_key) = self.token_key.as_ref() else { return None; };
    let blob = self.db.read(move |connection| crate::store::write::credentials(connection, account_id)).await.ok().flatten()?;
    let credentials = ImapCredentials::open(token_key, &blob).ok()?;
    self.provider_factory.make_body(&credentials)
}
```

`http/routes.rs` 的 `message_body` 改成三段：

1. **读**（现有逻辑不变）：账号不存在 → 404；header 不存在 → 保持现状 503；body 已缓存 → 现有路径返回。
2. **抓取**：body 未缓存且 header 存在 → `state.body_provider(account_id).await`；`None` → 503 `provider-not-configured`；`Some(provider)` → `provider.fetch_body(&remote_id).await`：
   - `Err(ProviderError::AuthFailed)` → 401 `provider-auth-failed`
   - `Err(ProviderError::Unreachable(_))` → 502 `provider-unreachable`
   - `Err(ProviderError::NotConfigured(_))` → 503 `provider-not-configured`
   - `Err(ProviderError::Protocol(_))` → 502 `provider-unreachable`
   - `Ok(body)` → 继续
3. **落库并回答**：用 `state.write_connection()` 开一条可写连接，调 `store::write::save_body(&connection, &NewBody { account_id, remote_id: &remote_id, text: &body.text, html: body.html.as_deref(), has_more: body.has_more, attachments: &serde_json::to_string(&body.attachments)?, to_addresses: &serde_json::to_string(&body.to)?, cc_addresses: &serde_json::to_string(&body.cc)? }, &state.body_key)`；落库失败 → 500 `internal-error`；成功 → 直接用内存里的 `body` 构造 `wire::MessageBody` 返回 200。

注意：`state.db.read` 的闭包不能跨 await 持有连接引用，所以 provider 构造必须放在 `read` 闭包之外。

- [ ] **Step 5: 跑测试确认它变绿**

Run: `cargo test --manifest-path crates/Cargo.toml -p lagoon-api --test r3_bodies`
Expected: PASS（4 个测试）。

- [ ] **Step 6: 确认契约回放没被打破**

Run: `cargo test --manifest-path crates/Cargo.toml -p lagoon-api --test contract_replay -- --nocapture`
Expected: PASS，`replayed 53 fixtures`。契约用的是 `NoProviderFactory`（`make_body` 默认 None），所以 `body.provider-unconfigured` 仍然回 503。

同时 Run: `cargo test --manifest-path crates/Cargo.toml -p lagoon-api --test read_paths`
Expected: PASS（`body_route_status_codes_match_the_contract` 仍绿）。

- [ ] **Step 7: 变异验证**

把 `make_body` 的默认实现临时改成 `Some(...)`（伪造一个永远成功的 provider），跑 Step 6，确认 `body.provider-unconfigured` fixture 变红，然后还原。

- [ ] **Step 8: 提交**

```bash
git add crates/lagoon-api/src/provider crates/lagoon-api/src/http/mod.rs crates/lagoon-api/src/http/routes.rs crates/lagoon-api/tests/r3_bodies.rs
git commit -m "feat(bodies): 正文路由惰性抓取并落库 —— 之前只读缓存，永远 503"
```

---

## Iteration 2 — 能力接线与安全

### Task 4: 接上 IDLE，消灭 5 分钟延迟

**Files:**
- Modify: `crates/lagoon-api/src/provider/lagoon_mail.rs:132-171`（`pull_changes` 传 `Duration::ZERO`）
- Modify: `crates/lagoon-api/src/sync/mod.rs`（固定 300s 睡眠改为「本轮已等待则不再额外睡」）
- Test: `crates/lagoon-api/tests/r3_sync.rs`（新增 IDLE 接线测试）

**Interfaces:**
- Consumes: `lagoon_mail::imap::provider::IDLE_BUDGET`（`Duration::from_secs(290)`，已定义未被引用）
- Produces: 无新接口。语义变更：`pull_changes` 在服务端支持 IDLE 时最多阻塞 290 秒等新邮件；同步循环因此**不再**额外睡 300 秒。

- [ ] **Step 1: 写会红的测试**

在 `crates/lagoon-api/tests/r3_sync.rs` 新增 `idle_budget_is_passed_to_the_provider`：用 `lagoon_mail` 的假传输（`support::scripted_transport`）构造一个支持 IDLE 的服务端，断言 `ImapProvider::pull_changes(cursor, IDLE_BUDGET)` 会发起 `IDLE` 命令（即 `wait_up_to > 0` 且服务端 CAPABILITY 含 IDLE 时，传输收到 `IDLE`）。

断言要点：传输收到的命令序列里含 `IDLE`；`IDLE_BUDGET` 被 `lagoon_mail` 导出且 `> Duration::ZERO`。

- [ ] **Step 2: 跑测试确认它变红**

Run: `cargo test --manifest-path crates/Cargo.toml -p lagoon-api --test r3_sync -- --nocapture`
Expected: FAIL —— 当前适配层传 `Duration::ZERO`，永远不会发 `IDLE`。

- [ ] **Step 3: 实现**

`lagoon_mail.rs` 的 `pull_changes`：`provider.pull_changes(cursor, Duration::ZERO)` → `provider.pull_changes(cursor, IDLE_BUDGET)`。

`sync/mod.rs` 的循环：IDLE 已经在本轮内阻塞了最多 290 秒，因此成功后**不再**额外睡 `IDLE_WAIT`；轮询兜底（服务端不支持 IDLE）才睡 `IDLE_WAIT`。`ImapProvider::pull_changes` 在不支持 IDLE 时会立即返回，所以需要区分——做法：`MailChangeSet` 增加一个字段 `waited: bool`（`provider/mod.rs`），`lagoon_mail.rs` 转换时填 `wait_up_to > 0 && 服务端支持 IDLE`，`fake.rs` 填 `false`。同步循环据此决定睡不睡。

- [ ] **Step 4: 跑测试确认它变绿**

Run: `cargo test --manifest-path crates/Cargo.toml -p lagoon-api --test r3_sync`
Expected: PASS。

- [ ] **Step 5: 跑全量后端测试**

Run: `cargo test --manifest-path crates/Cargo.toml`
Expected: 全部 PASS。

- [ ] **Step 6: 提交**

```bash
git add crates/lagoon-api/src/provider crates/lagoon-api/src/sync/mod.rs crates/lagoon-api/tests/r3_sync.rs
git commit -m "feat(sync): 接上 IMAP IDLE —— 之前固定 300s 轮询，新邮件最晚晚 5 分钟"
```

---

### Task 5: 前端键盘游标可见 + ⌘⌫ 不再误删

**Files:**
- Modify: `web/src/screens/MessageList.tsx`（消费 `cursor` prop）
- Modify: `web/src/screens/BriefingFeed.tsx`（接收 `cursor` prop）
- Modify: `web/src/ui/MailRow.tsx`（cursor 高亮类 + roving tabindex）
- Modify: `web/src/styles/app.css`（`.cursor` 样式）
- Modify: `web/src/App.tsx`（修饰键处理挪到 `typing` 判断之后；把 `cursor` 传给 BriefingFeed）
- Test: `web/src/core/__tests__/selection.test.ts`（新建）

**Interfaces:**
- Consumes: `App.tsx` 的 `cursor: string | null` 状态
- Produces: `MessageList` / `BriefingFeed` 的 `cursor: string | null` prop **真正生效**；`MailRow` 新增 `isCursor: boolean` prop 与 `.cursor` class；`⌘⌫` 在输入态下不触发删除。

- [ ] **Step 1: 写会红的测试**

新建 `web/src/core/__tests__/selection.test.ts`（vitest）。把「选择模型」抽成纯函数再测：

```ts
import { describe, expect, it } from "vitest";
import { targetIdsOf } from "../selection";

describe("targetIdsOf", () => {
  it("prefers the explicit selection", () => {
    expect(targetIdsOf(new Set(["a", "b"]), "opened", "cursor")).toEqual(["a", "b"]);
  });
  it("falls back to the opened row, then the cursor", () => {
    expect(targetIdsOf(new Set(), "opened", "cursor")).toEqual(["opened"]);
    expect(targetIdsOf(new Set(), null, "cursor")).toEqual(["cursor"]);
  });
  it("is empty when nothing is targeted", () => {
    expect(targetIdsOf(new Set(), null, null)).toEqual([]);
  });
});
```

新建 `web/src/core/selection.ts` 放 `targetIdsOf(selection: Set<string>, openedId: string | null, cursor: string | null): string[]`。

- [ ] **Step 2: 跑测试确认它变红**

Run: `cd web && npx vitest run`（此时还没有 vitest，见 Task 8 的依赖安装；本任务先手工安装）→ 先 `npm i -D vitest` 再跑。
Expected: FAIL —— `../selection` 不存在。

- [ ] **Step 3: 实现**

- `web/src/core/selection.ts`：实现 `targetIdsOf`。
- `web/src/App.tsx`：`targetIds` 改为调用 `targetIdsOf(selection, openedId, cursor)`；把键盘 effect 里的修饰键分支（⌘K / ⌘/ / ⌘Z / ⌘⌫ / ⌘⇧A）**移到 `typing` 判断之后**，即 `if (typing) return;` 放在最前面，修饰键分支放在其后但保留 `⌘K` 在输入框里也可用（⌘K 在输入框里打开命令面板是安全的，保留在 typing 之前；⌘⌫ / ⌘Z / ⌘⇧A 移到 typing 之后）。
- `web/src/screens/MessageList.tsx`：`props.cursor` 传给每一行 `MailRow` 的 `isCursor`。
- `web/src/screens/BriefingFeed.tsx`：新增 `cursor: string | null` prop 并同样下传。
- `web/src/ui/MailRow.tsx`：新增 `isCursor?: boolean` prop，className 加 `props.isCursor ? "cursor" : ""`；`tabIndex` 改为 roving（`props.isCursor ? 0 : -1`），列表本身 `role="listbox"`。
- `web/src/styles/app.css`：加 `.mail-row.cursor { outline: 2px solid var(--accent); outline-offset: -2px; }`（用项目已有的 token 变量名，写之前先 grep `tokens.css` 确认变量名）。

- [ ] **Step 4: 跑测试确认它变绿**

Run: `cd web && npx vitest run && npm run typecheck`
Expected: PASS；typecheck 退出码 0。

- [ ] **Step 5: 提交**

```bash
git add web/src/core/selection.ts web/src/core/__tests__/selection.test.ts web/src/App.tsx web/src/screens/MessageList.tsx web/src/screens/BriefingFeed.tsx web/src/ui/MailRow.tsx web/src/styles/app.css web/package.json
git commit -m "fix(web): 键盘游标可见，⌘⌫ 不再删掉用户看不见的那一行"
```

---

### Task 6: 空态可达 + 手动同步入口

**Files:**
- Modify: `web/src/App.tsx`（四个取数 hook 补 `isEmpty`；加"立即同步"按钮）
- Modify: `web/src/core/hooks.ts`（`useApiOutcome` 透传 `isEmpty`）
- Modify: `web/src/l10n/zh.ts`（补同步按钮文案）
- Test: `web/src/core/__tests__/errors.test.ts`（本任务先放错误码断言，Task 7 扩充）

**Interfaces:**
- Consumes: `core/async.ts` 的 `isEmpty?: (data: T) => boolean`
- Produces: `App.tsx` 的四个 hook 传 `isEmpty`；界面出现一个触发 `POST /api/sync` 的按钮。

- [ ] **Step 1: 写会红的测试**

在 `web/src/core/__tests__/errors.test.ts` 放一个纯函数测试：`emptyStateFor(lens, total)` 必须在 total 为 0 时返回该 lens 的专属空态标题，而不是通用文案。

- [ ] **Step 2: 跑测试确认它变红**

Run: `cd web && npx vitest run`
Expected: FAIL。

- [ ] **Step 3: 实现**

- `web/src/core/async.ts`：`useApiOutcome` 的 options 已含 `isEmpty`，确认它被透传给 `core/async.ts` 的 `fromCall`（已支持）。若 `App.tsx` 的 hook 包装层丢了 `isEmpty`，补上。
- `web/src/App.tsx`：为 `messages` / `briefing` / `counts` / `accounts` 四个 hook 各传 `isEmpty`：`messages` 用 `data.messages.length === 0 && (无搜索词)`；`briefing` 用 `data.groups.length === 0`。
- `web/src/App.tsx` 的 `MessageList` 空态分支：`query` 为空且结果为空 → 显示 `t.list.inboxEmpty`（`zh.ts:104` 已有）；`query` 非空 → 显示 `t.list.searchEmpty`。
- 加"立即同步"按钮：调用 `POST /api/sync`，成功后 `refreshAll()`；按钮放在侧边栏底部或标题栏，标签用新文案 `t.sync.now`（"立即同步"）。

- [ ] **Step 4: 跑测试确认它变绿**

Run: `cd web && npx vitest run && npm run typecheck && npm run build`
Expected: 全部成功。

- [ ] **Step 5: 提交**

```bash
git add web/src
git commit -m "feat(web): 空态真的可达 + 手动同步入口"
```

---

### Task 7: 错误码字典以 Rust 路由为唯一事实源

**Files:**
- Modify: `web/src/core/errors.ts`
- Modify: `web/src/core/writes.ts`
- Test: `web/src/core/__tests__/errors.test.ts`（扩充）

**Interfaces:**
- Consumes: `crates/lagoon-api/src/http/routes*.rs` 里实际返回的 `respond::error(status, "code")` 的 code 集合
- Produces: `web/src/core/errors.ts` 的 code 表与 Rust 路由**逐条一致**。

- [ ] **Step 1: 写会红的测试**

在 `web/src/core/__tests__/errors.test.ts` 里放一份**从 Rust 源码生成**的 code 清单（手抄进测试文件，并在注释里写明来源命令）：

```ts
// Generated from crates/lagoon-api/src/http/routes*.rs on 2026-11-02.
// Regenerate with: grep -rho 'respond::error([A-Za-z:]*::[A-Z_]*, "[a-z0-9-]*"' crates/lagoon-api/src/http/ | grep -o '"[a-z0-9-]*"' | sort -u
const BACKEND_CODES = [ ... ] as const;
```

断言 `describeHttpFailure` / `classifyFailure` 对**每一个** code 都返回一个非空的 `title` 与 `detail`，且没有未知 code 落进兜底分支。

- [ ] **Step 2: 跑测试确认它变红**

Run: `cd web && npx vitest run`
Expected: FAIL —— 后端会返回但前端没有文案的 code（至少 `uidplus-missing`、`internal-error`、`provider-unreachable`）被判为未知。

- [ ] **Step 3: 实现**

以 Rust 路由为准重写 `errors.ts` 的 code 表：

- 补上后端真实返回但前端缺失的：`uidplus-missing`、`internal-error`、`provider-unreachable`、`malformed-pinned`、`malformed-action-id`、`malformed-before`、`unknown-before`、`invalid-body`、`encoding-failed`、`unknown-stack`、`draft-unreadable`、`provider-auth-failed`。
- 删掉后端**从不**返回的三条：`sent-unavailable`（只在 `lagoon-mail/src/error.rs`）、`not-in-trash`（只在 fake provider 的字符串里）、`message-gone`（只在 lagoon-mail 里）——`not-in-trash` 需改映射为 API 层真实行为（后端把 fake 的 `not-in-trash` 映射成 `provider-unreachable`）。
- `core/types.ts` 的 `refreshedFromServer?: boolean` 改成 `refreshedFromServer?: number`（`wire_r2.rs:305` 是 `i64`）。

- [ ] **Step 4: 跑测试确认它变绿**

Run: `cd web && npx vitest run && npm run typecheck`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add web/src/core/errors.ts web/src/core/writes.ts web/src/core/types.ts web/src/core/__tests__/errors.test.ts
git commit -m "fix(web): 错误码字典以 Rust 路由为唯一事实源"
```

---

### Task 8: 端口 TOCTOU —— 不再把真 token 发给未验证的对端

**Files:**
- Modify: `shell/src/port.rs`（删掉 `free_port` 的 bind-then-drop）
- Modify: `shell/src/sidecar.rs`（从后端 stdout 读实际端口）
- Modify: `crates/lagoon-api/src/main.rs`（`--port 0` 时把实际端口打到 stdout 一行固定格式）
- Test: `shell/src/selftest.rs`（加一条断言：后端报的端口与实际监听端口一致）

**Interfaces:**
- Consumes: `crates/lagoon-api/src/main.rs` 已有的 `tracing::info!(port = bound.port(), "listening")`
- Produces: 后端启动时向 stdout 输出一行 `LAGOON_PORT=<u16>`；shell 从这一行取端口，**不再**自己挑端口。

- [ ] **Step 1: 写会红的测试**

在 `shell/src/selftest.rs` 加一条：启动后端（`--port 0`），断言 shell 读到的端口与 `lsof`/实际 `/healthz` 响应一致——即 shell 不再使用自己挑的端口。

- [ ] **Step 2: 跑测试确认它变红**

Run: `cargo run --manifest-path shell/Cargo.toml -- --selftest`
Expected: FAIL。

- [ ] **Step 3: 实现**

- `crates/lagoon-api/src/main.rs`：绑定成功后，除了现有的 tracing 日志，额外 `println!("LAGOON_PORT={}", bound.port())` 并 flush stdout。
- `shell/src/sidecar.rs`：spawn 时传 `--port 0`；`pump` 的 stdout 读取器在看到 `LAGOON_PORT=` 行时把端口写进一个共享槽；`wait_healthz` 等这个槽有值后再握手（预算 20s 内）。
- `shell/src/port.rs`：`free_port` / `free_port_with_retry` 删掉（改由后端自绑）。

- [ ] **Step 4: 跑测试确认它变绿**

Run: `cargo run --manifest-path shell/Cargo.toml -- --selftest`
Expected: 全绿，0 failure。

- [ ] **Step 5: 提交**

```bash
git add shell/src crates/lagoon-api/src/main.rs
git commit -m "fix(shell): 后端自绑端口，不再把 token 发给抢占端口的进程"
```

---

### Task 9: 鉴权 fail-closed + CSP

**Files:**
- Modify: `crates/lagoon-api/src/http/guard.rs:44`
- Modify: `crates/lagoon-api/src/config.rs`（token 缺失时拒绝启动）
- Modify: `shell/tauri.conf.json`（加 CSP）
- Test: `crates/lagoon-api/tests/read_paths.rs`（`host_guard_and_auth_gate_match_v3` 扩展）

**Interfaces:**
- Consumes: `AppState::api_token: Option<Arc<str>>`
- Produces: 无 token 时后端**拒绝启动**（不再有「无鉴权模式」）。

- [ ] **Step 1: 写会红的测试**

在 `read_paths.rs` 增加：token 为 `None` 的服务器对 `/api/accounts` 返回 **401**（而不是 200）。

- [ ] **Step 2: 跑测试确认它变红**

Run: `cargo test --manifest-path crates/Cargo.toml -p lagoon-api --test read_paths`
Expected: FAIL（现在无 token = 放行）。

- [ ] **Step 3: 实现**

- `config.rs`：`validate()` 在任何绑定下都要求 `api_token` 非空；缺失 → 启动失败并给出明确信息：`api token is required: set LAGOON_API_TOKEN (the shell always sets it)`。
- `guard.rs`：删掉 `if let Some(token)` 的条件分支，改为直接用 `state.api_token.as_deref().unwrap_or("")` 比较（token 不存在时任何 `Authorization` 都匹配不上 `Bearer `，自然 401）。
- `shell/tauri.conf.json`：`app.security.csp` 从 `null` 改为 `"default-src 'self'; connect-src ipc: http://ipc.localhost http://127.0.0.1:*; img-src 'self' data: blob:; style-src 'self' 'unsafe-inline'"`。改完必须实跑打包 app 确认前端仍能起（见 Task 10 的打包步骤）。

- [ ] **Step 4: 跑测试确认它变绿**

Run: `cargo test --manifest-path crates/Cargo.toml`
Expected: 全部 PASS。注意 `read_paths.rs` 里用 `TestServer::spawn(...)` 的测试可能传 `None` token——那些测试要改成传 `Some(TEST_API_TOKEN)`。

- [ ] **Step 5: 提交**

```bash
git add crates/lagoon-api/src/http/guard.rs crates/lagoon-api/src/config.rs crates/lagoon-api/tests shell/tauri.conf.json
git commit -m "fix(auth): token 缺失时拒绝启动并 fail-closed；外壳加 CSP"
```

---

## Iteration 3 — 工程卫生

### Task 10: clippy 闸门进 CI + 清死代码

**Files:**
- Modify: `.github/workflows/ci.yml`
- Modify: `crates/lagoon-api/src/http/routes_r5.rs`（清 `BulkBody`，Task 1 已做）
- Modify: `crates/lagoon-api/src/provider/mod.rs`（`NoProviderFactory` 的注释改成当前事实）
- Modify: `crates/lagoon-api/src/provider/fake.rs`（若 clippy 指出）
- Test: 无新增测试；用 clippy 本身当闸门

- [ ] **Step 1: 跑 clippy 看现在有多少债**

Run: `cargo clippy --manifest-path crates/Cargo.toml --workspace --all-targets -- -D warnings`
Expected: 列出当前所有警告。

- [ ] **Step 2: 逐条修到零警告**

对每条警告：能改就改；确实无法改的（例如 `expect` 在测试里）在文件里加 `#[allow(...)]` 并写明理由。

- [ ] **Step 3: 把 clippy 加进 CI**

`.github/workflows/ci.yml` 的 backend job 加一步：

```yaml
      - name: Clippy (warnings are errors)
        run: cargo clippy --manifest-path crates/Cargo.toml --workspace --all-targets -- -D warnings
```

shell job 同样加一条 `cargo clippy --manifest-path shell/Cargo.toml --all-targets -- -D warnings`。

- [ ] **Step 4: 确认本地与 CI 一致**

Run: `cargo clippy --manifest-path crates/Cargo.toml --workspace --all-targets -- -D warnings && cargo clippy --manifest-path shell/Cargo.toml --all-targets -- -D warnings && cargo test --manifest-path crates/Cargo.toml`
Expected: 全部成功。

- [ ] **Step 5: 提交**

```bash
git add .github/workflows/ci.yml crates shell
git commit -m "ci: clippy 闸门进 CI —— 警告不再让构建静默通过"
```

---

### Task 11: README 按单版本事实重写

**Files:**
- Modify: `README.md`

- [ ] **Step 1: 重写**

README 必须满足：不再出现「v4」「与 v3 并行」「v3 保持可构建」；所有链接指向真实存在的路径（写之前逐条 `test -e`）；状态表里**必须有**一行写明「AI：未实现（`/api/ai-status` 恒 `configured:false`）」和一行「发送：未实现（R3.5b）」和一行「IDLE：已接线 / 手动同步：已有」。

- [ ] **Step 2: 校验所有链接**

Run: `grep -oE '\]\([^)]+\)' README.md | sed 's/](\(.*\))/\1/' | while read -r p; do [ -e "$p" ] || echo "MISSING: $p"; done`
Expected: 无输出。

- [ ] **Step 3: 提交**

```bash
git add README.md
git commit -m "docs(readme): 按单版本事实重写，标出未实现的能力"
```

---

### Task 12: 文档归档 + 新的 V1.0 验收尺子

**Files:**
- Create: `docs/README.md`（索引）
- Create: `docs/V1.0-产品定义与验收标准.md`（重写，覆盖旧文件）
- Move: `docs/` 下 v3 时代的审查文档 → `docs/archive/v3/`

- [ ] **Step 1: 归档 v3 文档**

把 `审查-*.md`、`第四轮*.md`、`基线体检*.md`、`深入体检*.md`、`全方位审查报告*.md`、`质量改进计划*.md`、`事故记录*.md`、`竞品研究*.md`、`审查台账.md`、`专家团作业规约.md` 移到 `docs/archive/v3/`。**保留** `00-理解与方案.md`、`api-contract.md`、`ipc-contract.md`、`m1-checklist.md`、`r3-plan.md`、`acceptance-2026-10-29.md`、`adr/`、`recon/`、`release-evidence/`。

- [ ] **Step 2: 重写 V1.0 验收尺子**

新尺子必须以 Rust 产品为对象，且每一条都能被命令验证。三条核心承诺改写为：

- **P1 十分钟清零**：列表、计数、简报三者一致；空态文案区分「没有邮件」与「没有匹配的邮件」与「同步没在工作」。
- **P2 撤销是真的**：撤销归档/删除必须让邮件回到收件箱，且远端与本地同时回退（Task 1 的测试钉住）。
- **P3 不撒谎**：界面上任何状态都能回答「后端此刻的真实状态是什么」；答不出就显示「不知道」。
- 新增 **P4 能读信**：打开一封从未抓取过的邮件，必须拿到正文（Task 3 的测试钉住）。
- **AI 一栏必须写明「未实现」**，不得保留「AI 只读」的承诺措辞。

- [ ] **Step 3: 写 `docs/README.md` 索引**

列出每份文档是「当前有效」还是「已归档」，并给出一句「想验证产品现在的能力，看哪份」。

- [ ] **Step 4: 提交**

```bash
git add docs
git commit -m "docs: 归档 v3 时代文档，按 Rust 产品重写 V1.0 验收尺子"
```

---

### Task 13: `.env.example` 按代码真实读取的环境变量重写

**Files:**
- Modify: `.env.example`

- [ ] **Step 1: 生成真实清单**

Run: `grep -rhoE 'LAGOON_[A-Z_]+' crates/lagoon-api/src shell/src | sort -u`
把结果作为 `.env.example` 的主体，每行写清用途。删掉 Postgres / Gmail OAuth / Fly.io / LLM_PROVIDER_* 这些代码不读的键。

- [ ] **Step 2: 校验**

Run: `comm -23 <(grep -oE '^[A-Z_]+' .env.example | sort -u) <(grep -rhoE 'LAGOON_[A-Z_]+' crates/lagoon-api/src shell/src | sort -u)`
Expected: 只允许剩下「不属于代码读取但用户需要知道」的键；每多一个都要有理由。

- [ ] **Step 3: 提交**

```bash
git add .env.example
git commit -m "docs(env): .env.example 按代码真实读取的变量重写"
```

---

### Task 14: 前端测试落地

**Files:**
- Modify: `web/package.json`（`test` 脚本 + vitest 依赖）
- Create: `web/vitest.config.ts`
- Create: `web/src/core/__tests__/*.test.ts`（Task 5/6/7 已建）

- [ ] **Step 1: 装依赖并加脚本**

`web/package.json` 加 `"test": "vitest run"` 与 `"vitest": "^3"`（devDependencies）。

- [ ] **Step 2: 加配置**

`web/vitest.config.ts`：`test: { environment: "node", include: ["src/**/*.test.ts"] }`。

- [ ] **Step 3: CI 跑前端测试**

`.github/workflows/ci.yml` 的 frontend job 加一步 `npm test`。

- [ ] **Step 4: 全绿**

Run: `cd web && npm test && npm run typecheck && npm run build`
Expected: 全部成功。

- [ ] **Step 5: 提交**

```bash
git add web/package.json web/vitest.config.ts .github/workflows/ci.yml
git commit -m "test(web): 前端测试落地，CI 跑"
```

---

## End-to-End Verification（全部任务完成后跑一次）

- [ ] `cargo test --manifest-path crates/Cargo.toml` —— 全绿，且测试数 ≥ 287 + 本计划新增
- [ ] `cargo clippy --manifest-path crates/Cargo.toml --workspace --all-targets -- -D warnings` —— 零警告
- [ ] `cargo run --manifest-path shell/Cargo.toml -- --selftest` —— 0 failure
- [ ] `cd web && npm test && npm run typecheck && npm run build` —— 全绿
- [ ] `bash scripts/build-product.sh` —— 产出 `dist/Lagoon.app`
- [ ] 打包 app 实跑：启动 → 三个业务请求 200 → 关掉后无残留后端进程（`pgrep -f lagoon-api` 为空）
- [ ] 对真实 QQ 邮箱做一次**只读**验证：连接 → 首轮拉到邮件 → 打开一封能看到正文（**需用户确认后才动真实邮箱**）

---

## 明确不做（等用户拍板）

- **AI（R4）**：补齐 LLM 网关 + 建议/摘要/草稿，或改掉 V1.0 里的「AI 只读」承诺。这是方向分叉，计划里只做**诚实记录**（Task 12），不实现。
- **发送（R3.5b）**：SMTP 客户端已就绪，接线工作量与 Task 3 同量级，但需要真实邮箱才能验；单列一个迭代。
- **Developer ID 签名与公证**：需要证书，属外部依赖。
