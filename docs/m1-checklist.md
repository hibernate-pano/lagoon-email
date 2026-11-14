# M1 集成验收清单（Lead 维护）

> 目的：把「v4 前端 + Rust 外壳 + Swift 边车」跑通到什么程度算完成，写死在这里，不靠感觉。
> 相关：`docs/ipc-contract.md`（协议）、`recon/server-contract.md`（端点真相）、`00-理解与方案.md`（里程碑）。

## 0. 环境与启动

```bash
# 1) 后端 + 前端（浏览器模式，供 Playwright）：一条命令
bash scripts/dev.sh                       # 生成 .dev/{keys.json,web.env}，起 lagoon-api 和 Vite
# 2) 外壳（Tauri 模式）
bash scripts/tauri-dev.sh                 # 或 cd shell && cargo run
```

数据目录：`.dev/data/lagoon.sqlite`（开发期，独立于 v3）。密钥：`.dev/keys.json`（0600，gitignore）。

> 浏览器模式走 **Vite 同源 dev 代理**（`/api/*` → 边车，代理加 Bearer），浏览器里没有 token（`docs/ipc-contract.md` §5）；生产走 `invoke("api")`。
**不连接真实邮箱时看到的「空收件箱」是正确状态，不是 bug。**

## 1. 已实测的真实响应（2026-10-29，空库）

| 请求 | 状态 | 响应 |
|---|---|---|
| `GET /healthz`（免鉴权） | 200 | `ok`（纯文本） |
| `GET /api/accounts` + Bearer | 200 | `[]` |
| `GET /api/accounts` 无 Bearer | 401 | `{"error":"api-unauthorized"}` |
| `GET /api/messages?accountId=not-a-uuid` | 400 | `{"error":"malformed-accountId"}` |
| `GET /api/messages?accountId=<uuid 不存在>` | 200 | `{"messages":[],"totalCount":0,"cursor":{"accountId":"…","totalUnread":0,"lastFetchedAt":"…"}}` |
| `GET /api/briefing?accountId=<uuid 不存在>` | 404 | `{"error":"unknown-account"}` |
| `GET /api/nope`（未知路由） | 404 | **空体**（不是 JSON 信封）→ 前端按「协议错误」处理，不要显示成业务错误 |
| `GET /healthz` 带 `Host: evil.example` | 403 | `{"error":"forbidden-host"}` |

## 1.1 已知缺陷：v3.2.0 `GET /api/search` 必然 500（2026-10-29 实测）

- 证据：`Sources/LagoonServer/Routes/DraftRoutes.swift:487-490` 的 pass-A SQL 有 `LEFT JOIN advice a`；而 `:513-514` 的 pass-B `scanSQL` 只 `LEFT JOIN message_bodies b`，`WHERE … COALESCE(cheapArms,0)=0` 里却引用了 `a.category` / `a.action` → `SQLite error 1: no such column: a.category` → 500。
- 影响：**v3.2.0 的搜索实际不可用**（不是 v4 引入的）。凡走 pass-B 的请求必失败，而 pass-B 每次搜索都会执行。
- v4 决定：**M1 不调用 `/api/search`**。搜索改为对已加载列表做客户端过滤（≤1000 条，snippet 已由服务端解封返回）；契约仍按 200 `SearchResponse` 定义，fixture 标 `known_defect` 默认跳过（`LAGOON_CONTRACT_KNOWN_DEFECTS=1` 时断言缺陷仍存在）。
- 给 v3 的修复建议（**未执行**，遵守“不改 v1”纪律）：在 pass-B 的 FROM 上加一行
  `LEFT JOIN advice a ON a.account_id = m.account_id AND a.remote_id = m.remote_id`。
  是否发 v3.2.1 由你决定；v4 的 Rust 后端会按正确语义重写搜索（两遍扫描 + 预算）。

## 1.2 Tauri 模式联调实录（2026-10-29，三个真实缺陷）

外壳 + 嵌入 `web/dist` 首次联调暴露了三个问题，都已修复并在 `cargo run` 里验证：

| # | 症状 | 根因 | 修复 |
|---|---|---|---|
| 1 | 窗口停在启动页 | Tauri 2 的 `event.listen` 是 core 命令，默认未授权 → `core:event:allow-listen` 被拒；自定义命令 `invoke` 却照常成功，所以看起来“只有事件不工作” | 新增 `shell/capabilities/default.json`，授予 `core:default` |
| 2 | 早于就绪的三次请求失败后永不重试 | React 挂载即 fetch，而边车 1–2s 后才 ready（浏览器模式看不出，因为 sidecar 早就跑着） | `App.tsx` 三个顶层请求加 `enabled: boot.phase === "ready"`，并把 `bootReady` 放进 deps |
| 3 | 就绪事件可能丢 | `useBoot` 先 invoke 再 listen，事件落在两者之间就丢了 | 先 `listen` 再 `invoke`，并加「见过 settled 相位后忽略 starting 回声」的保护 |

**修复后的终局证据**（`cargo run`，嵌入式 `web/dist`）：

```
[ipc] page-load url=tauri://localhost event=Started
[ipc] page-load url=tauri://localhost event=Finished
[ipc] boot_status -> phase=starting port=None
[boot] {"phase":"ready","port":50202,"pid":2006}
[ipc] api GET /api/ai-status -> 200
[ipc] api GET /api/accounts -> 200
[ipc] api GET /api/store-notices -> 200
```

即：WebView 真的加载了构建产物、前端真的拿到了 ready、随后三次业务请求全部 200 —— **没有任何 token 出现在前端**。

## 2. 前端必须做到的（逐条勾）

**启动与连接**
- [ ] 外壳 `phase=starting/failed` 有独立文案，不把「边车没起来」说成「网络错误」
- [ ] 无账号时显示**连接账号**引导（邮箱 + 16 位授权码），不是空列表
- [ ] 连接失败按 code 区分：401 `imap-auth-failed`（授权码错）/ 502 `imap-unreachable`（网络）/ 503 `provider-not-configured`

**六态**（`docs/V1.0-产品定义与验收标准.md` §4）
- [ ] 加载中 / 空 / 错误 / 离线 / 未连接 / 部分成功 各有独立呈现
- [ ] 「不知道」不显示成 0 或 false：`totalCount`、`hasMore`、`capabilities.*` 缺失时显示 `—` 或不说
- [ ] 409 能力闸门（`archive-unavailable` 等）显示为「这台服务器不支持」，而不是通用错误（M2 写操作时验证）

**阅读**
- [x] **M1 不调用 `POST /read`**：该端点会 `UID STORE \Seen`（真写远端），与「M1 不改远端邮箱」冲突；`record=false` 只免审计行、不免远端写入。前端以 `ENABLE_MARK_READ=false` 关闭，M2 连同撤销审计一起打开。
- [x] 列表 → 打开正文：只 `GET /body`（+ `/inline-images`）
- [ ] HTML 正文在 `<iframe sandbox srcdoc>` 里渲染；禁脚本；外链图片不自动加载（隐私）
- [ ] 内联图（cid）经 `/inline-images` 转 data URL；失败时退化为纯文本，不空白
- [ ] 纯文本邮件有等价呈现

**安全**
- [ ] 浏览器里 `localStorage`/`sessionStorage`/`document.cookie` **没有 token**（Playwright 断言）
- [ ] 前端任何请求都不直连 8080 等非商品端口；浏览器模式只连 `VITE_SIDECAR_URL`
- [ ] 外壳 `api` 命令拒绝 `/api/`、`/healthz` 之外的路径

**键盘**
- [ ] ⌘K 打开命令面板；↑↓ 移动；Enter 打开；Esc 关闭
- [ ] 不劫持 ⌘N/⌘T/⌘W/⌘Q（留给外壳/浏览器）

## 3. Playwright 自动化场景（lead 负责）

| # | 场景 | 断言 |
|---|---|---|
| S1 | 打开首页（空库） | 出现连接引导；无 JS 控制台错误；无 token 泄漏 |
| S2 | 侧边栏切换 | 简报/收件箱/未读/置顶/已归档/已发送/垃圾箱 每个都有独立空态文案 |
| S3 | 命令面板 | ⌘K 打开、Esc 关闭、输入能过滤 |
| S4 | 错误态 | 把 VITE_SIDECAR_URL 指向关闭端口 → 显示「连不上服务端」，不是空白 |
| S5 | 无鉴权 | token 置空 → 401 被渲染成「未授权」，不是「网络错误」 |
| S6 | 未知路由 404 空体 | 不崩溃、不弹业务错误 |
| S7 | 键盘导航 | ↑↓ 改变选中行，Enter 打开阅读器（M2 数据齐全后） |
| S8 | 外壳模式 | `cargo run` 起窗 → 渲染同一首页（人工/截图） |

## 4. 需要用户本人完成的事

1. **QQ 邮箱授权码**（设置 → 账户 → 开启 IMAP/SMTP 生成 16 位），在 v4 连接页输入一次 —— M1 无法伪造，没有它只能看空态。
2. **稳定签名身份**（Developer ID 或至少固定 Apple Development 证书）—— 决定 Keychain 与通知能否稳定工作；现在开发期用 `v4/.dev/keys.json` 绕过。
3. 决定 v4 的最终数据目录名（当前 `~/Library/Application Support/Lagoon-v4/`，可改）。

## 5. 已知限制（M1 不修）

- 双进程：边车崩溃自动重启一次；彻底失败会显示 failed 并给原因。
- 无 SSE：列表/账户 30s 轮询、time-saved 60s（与 v3 一致）。
- 写操作全部在 M2；M1 里归档/删除/回复按钮要么隐藏，要么明确标「M2」。
- 附件下载、`.eml` 导出、退订、打印/QuickLook 不在 M1。
