# tests/contract — 可执行契约（golden fixtures v2）

每一条 fixture 都是从**真实**进程上抓下来的 HTTP 响应（状态码 + Content-Type + body），
与 `docs/api-contract.md` 的端点表一一对应。现有 fixtures 抓自已退役的 Swift
`LagoonServerCLI`；抓取脚本现在跑 Rust 后端（`crates/target/{release,debug}/lagoon-api`，
没有就 `cargo build -p lagoon-api`），所以重抓会覆盖成 Rust 的实现行为。
R2 把抓取面扩大到纯本地只读端点并准备了**有数据**的种子；R3 又补上账号连接与同步触发。

| 文件 | 作用 |
|---|---|
| `fixtures/fixtures.json` | 61 条 golden 响应（56 抓取 + 5 contract_expected），**version 2** |
| `harness.py` | seed / capture / check / diff（python3 标准库，无第三方依赖） |
| `aesgcm.py` | 纯 stdlib 的 AES-256-GCM，只用于给 seed 生成 `lgb1:` 封存行 |
| `../../scripts/capture-contract.sh` | 起临时边车 → seed → 抓取 → 写 fixtures |
| `../../scripts/contract-check.sh` | 起临时边车（或对指定实例）回放 → diff → 非零退出 |

## 数据从哪来

每次抓取都起一个**一次性**边车：二进制 `crates/target/{release,debug}/lagoon-api`（缺了就地
构建）；数据库是 `mktemp -d` 里的新 SQLite（**绝不**是 `.dev/data`、v3 用户库）；密钥用
`openssl rand -base64 32` 现场生成；端口现挑。**零外联**：账号的 credentials 是 48 个零字节，
provider 在解密阶段就失败，不会建 IMAP socket。

三个合成账号（`example.invalid`、固定 UUID、固定时间）：

| 账号 | 数据 | 用途 |
|---|---|---|
| **A** `11111111-…-111111111111` | 3 封 header（含已归档/已置顶/未读各一），advice/stacks/reminders **故意为空** | 列表 lens、briefing、export、以及「队列为空」的 fixture |
| **B** `33333333-…-333333333333` | 2 封 header + advice 2（pending/accepted）+ stack_rules 2（sender/keyword）+ reminders 2（1 pending、1 dismissed）+ draft_replies 1 + message_bodies 1 + ai_actions 2（send/pin）+ store_notices 1 | R2 只读端点的**有数据**形状 |
| **C** `66666666-…-666666666666` | 只有一行账号（`sync_status='ok'`、无 header） | `POST /api/accounts/imap` 的 **409 account-exists** 对象；独立成账号，避免与 A/B 的数据互相牵连 |

封存行（`lgb1:` + base64(nonce‖ct‖tag)，AES-256-GCM）由 `aesgcm.py` 现场用本次边车的
body key 生成：正文缓存让 `GET /body` 走到 **200**（不需要 provider），草稿让
`GET /drafts` 走到 200；`/api/search` 的 sealed-body 用例也依赖它。
**正确性顺带被服务端验证**：若封存实现有误，CryptoKit 打不开，路由会退化成 503 而不是 200。

## fixture 格式（version 2）

```json
{
  "version": 2,
  "normalized": ["lastFetchedAt", "date", "..."],
  "fixtures": [
    {
      "name": "advice.list.data",
      "note": "人读的说明",
      "r2_skip": "write-path: Rust R2 is READ_ONLY; ...",
      "mutates_store": true,
      "contract_expected": true,
      "defect_evidence": "v3.2.0 的 500 证据",
      "expected_source": "api-contract.md 4.8 + ...",
      "pre": "restore-account-c-ok",
      "request": {"method": "GET", "path": "/api/advice",
                  "query": {"accountId": "..."}, "auth": "token",
                  "headers": {}, "json": null, "raw_body": null},
      "response": {"status": 200, "content_type": "application/json; charset=utf-8",
                   "body_kind": "json", "body": {"advice": []}}
    }
  ]
}
```
- `r2_skip`：写路径（Rust R2 是 READ_ONLY）。**capture 仍抓**，**check 默认跳过**；
  `--include-write` / `LAGOON_CONTRACT_INCLUDE_WRITE=1` 时才断言。
  目前 3 条：`read.mark-read`、`read.recorded`、`pin.set`。
- `mutates_store`：这条 fixture 会改本地库，所以回放时**排到读路径之后**——否则
  `read.mark-read` 会把 `search.contract` 断言的前置状态（fixture-msg-3 未读）改掉。
  目前 4 条：3 条写路径 + `sync.request`（它会叫醒同步循环）。`r2_skip` 作为
  旧数据的兜底判据。
- `contract_expected`：期望值是**契约应为**，不是 v3 实测。默认跳过；
  `--assert-contract-expected`（两参数模式的 contract-check 默认开启）时断言。
  目前 5 条：`search.contract`、`search.contract.sealed-body`（附 `defect_evidence`），
  以及退订的三条拒绝路径（`unsubscribe.unavailable`、`unsubscribe.unknown-mail`、
  `unsubscribe-bulk.empty`）——退订的 200 路径要真实发布方，按设计不进 CI。
- `request.raw_body`：发送**精确字节**而不是 JSON 对象（用来表达「空 body」）。
  与 `request.json` 二选一；两者都为 null 则不发 body。
- `pre`：**请求前钩子的名字**（JSON 里存不了可调用对象）。目前只有
  `restore-account-c-ok` —— 把账号 C 的 `sync_status` 复位成 `ok`。
  为什么需要它：v3 的同步循环一旦发现凭据解不开，就会把账号标记成
  `needsReconnect`；而 409 `account-exists` 只在账号**健康**时给出。
  钩子在请求前一刻复位，所以 fixture 与「同步跑没跑过」无关（确定性）。

## 规范化

只按 **key 名**把 wall-clock 时间戳替换成 `"<timestamp>"`：
`lastFetchedAt, fetchedAt, lastSyncAt, createdAt, updatedAt, decidedAt, dueAt, expiresAt,
lastErrorAt, startedAt, date`（`date` = `TimeSavedDay.date`，随运行日期移动）。
其余值逐字比较（含 `receivedAt`、`latestAt`、UUID、计数、错误 code）。
写盘时 `sort_keys=True`：Foundation 的 JSONEncoder 没开 `.sortedKeys`，键序每进程随机。

## 三种运行方式

```bash
bash scripts/capture-contract.sh               # 重抓（临时边车 + 合成 seed）
bash scripts/contract-check.sh                 # 起临时 Rust 后端：含写路径，断言 contract_expected
bash scripts/contract-check.sh <url> <tok>  # 对实现（Rust）：断言 contract_expected，跳过写路径
LAGOON_CONTRACT_VERBOSE=1                      # 逐条打印 ok
```

| 环境变量 | 作用 |
|---|---|
| `LAGOON_CONTRACT_FIXTURES` | fixtures 目录（默认 `tests/contract/fixtures`） |
| `LAGOON_CONTRACT_VERBOSE=1` | 逐条输出 |
| `LAGOON_CONTRACT_INCLUDE_WRITE=1` | 两参数模式下也断言写路径 |
| `LAGOON_CONTRACT_SKIP_CONTRACT_EXPECTED=1` | 两参数模式下跳过 contract_expected |
| `LAGOON_CONTRACT_SKIP_WRITE=1` | 无参模式下跳过写路径 |

给 Rust 后端做实现验证时，种子要与抓取时一致：

```bash
python3 tests/contract/harness.py seed --db <你的库> --body-key <32B body key base64>
bash scripts/contract-check.sh http://127.0.0.1:PORT TOKEN
```

## /api/search 的处理（重要）

v3.2.0 的 `GET /api/search` **必然 500**：pass-B 的 SQL 引用 `a.category`，但只 JOIN 了
`message_bodies`，SQLite 报 `no such column: a.category`。所以它**不参与 live capture**，
而是由 `synthesize_contract_expected()` 现场合成两条 200 期望：

- `search.contract`：`q=fixture` 在账号 A 命中 3 封（subject 匹配），结果按
  `received_at DESC, id DESC` 排序，`totalCount=3, truncated=false, bodyScanSkipped=0, bodyScanLimit=1000`；
- `search.contract.sealed-body`：`q=sealedneedle` 在账号 B 只命中封存正文那一封，
  用来验证「sealed body 扫描」这条臂。

Header 字节取自同一次抓取的 `export.index` / `messages.list.b`（不是手写猜测）。

## R2 覆盖（本目录新增）

briefing、advice（空/有数据/decision=any）、advice.accepted-stats、stacks（空/有数据）、
senders（空/有数据）、sent（200+staleReason）、store-notices（1 条）、time-saved（零/非零）、
usage、ai-status、actions（有数据）、drafts（有数据）、drafts.generate（503）、summary（503）、
body（缓存 200 / 无 provider 503）、export/index、search（contract_expected ×2）。

## R3 覆盖（本目录新增）

| fixture | 请求 | 期望 |
|---|---|---|
| `accounts.imap.empty-body` | POST `/api/accounts/imap`，空 body | 400 `{"error":"missing-field"}` |
| `accounts.imap.missing-field` | body 缺 `authCode` | 400 `{"error":"missing-field"}` |
| `accounts.imap.unknown-provider` | body `provider:"gmail"` | 400 `{"error":"missing-field"}` |
| `accounts.imap.exists` | body 用账号 C 的 email | 409 `{"error":"account-exists"}` |
| `sync.request` | POST `/api/sync` | 204，空 body、无 Content-Type |

三点值得记下来（都是实测，不是推测）：

1. **空 body 也是 `missing-field`，不是 `missing-body`。** `missing-body` 只在
   `collectBody` 抛错（超 1 MB 上限）时出现；空 body 能收下，只是 JSON 解不出来，
   于是落到同一个 code。写客户端时别把两者当成不同语义。
2. **409 在任何网络动作之前给出。** 路由先查 `(oauth_user, provider)`，命中健康账号
   就直接 409，不探活、不建 socket。所以这条 fixture 零外联，也不需要真授权码。
3. **`sync.request` 放最后。** 它会叫醒同步引擎，而同步引擎正是把账号标成
   `needsReconnect` 的那个东西；放在末尾，后面的读不受影响。

## 新增一条 fixture

1. 在 `harness.py` 的 `scenario()` 里加 `add(...)`（读操作在前，改本地状态的放最后：
   fixtures 是有序回放，顺序即状态机）；需要请求前状态就用 `pre="<钩子名>"`，
   需要精确字节就用 `raw_body="…"`；
2. `bash scripts/capture-contract.sh`；
3. 检查 `git diff tests/contract/fixtures/fixtures.json` —— 应只含新增/预期的变化；
4. `bash scripts/contract-check.sh` 必须全绿；两参数模式对 Rust 也应全绿。

## 边界

- 不连接真实邮箱、不放真实邮件内容、不读取 v3 的 Keychain；合成数据只用 `example.invalid`；
- 干净机器只要有 `bash + python3 + curl + openssl`；
- 只覆盖「形状」（路径、状态码、Content-Type、错误 code、字段集合），不覆盖业务正确性；
- `body.attachments` 的字节下载、`raw.eml` 的 200 形状仍需真实 IMAP（禁止），fixtures 只锁 503；
- `POST /api/accounts/imap` 的 **201 成功路径**（真的连上一次 IMAP）同样需要真授权码，
  禁止在此抓取；本目录只锁它的 400 / 409。
