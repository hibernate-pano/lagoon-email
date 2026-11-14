# v4 IPC 契约 · Rust 外壳 ↔ Web 前端

> 版本 **v0.1** · 2026-10-29 · 状态：M0 冻结，M1 只允许向后兼容扩展
> 这份文件是 `shell/`（Rust/Tauri）与 `web/`（前端）之间**唯一的接口真相**。
> 改它 = 改协议：先改这里，再加 ADR，再改两边实现。

---

## 1. 原则（为什么不是“前端直接 fetch”）

1. **前端永远不持有 Bearer token。** 服务端零 CORS（`recon/server-contract.md` §9），WKWebView 直连会被拦；而把 token 放进 JS 又等于把钥匙交给 XSS。所以：**所有 HTTP 请求由 Rust 侧代理**，token 只活在外壳进程里。
2. **代理是透明的。** Rust 不改写响应体、不隐藏状态码、不重试写操作。前端看到的 `status` / `body` 就是服务端返回的原值 —— 六态与「不知道」的语义全靠原样透传才不撒谎。
3. **只允许本地服务端。** 代理只打 `http://127.0.0.1:<port>`，路径白名单 `/api/*` 与 `/healthz`，不接受任意 URL（防 SSRF）。
4. **失败要分类。** “没起来 / 连不上 / 超时 / 服务端返回错误”是四件事，前端必须能分开显示。

---

## 2. 目录与密钥（开发期 vs 发布期）

| 项 | 开发期（M1） | 发布期（M2+） |
|---|---|---|
| 数据目录 | `.dev/data/`（env `LAGOON_V4_DATA_DIR` 可覆盖） | `~/Library/Application Support/Lagoon-v4/` |
| 密钥 | `.dev/keys.json`（0600，gitignore）`{ "tokenKey": "<base64 32B>", "bodyKey": "<base64 32B>", "apiToken": "<hex>" }` | data-protection Keychain（稳定签名身份，见方案 §5.2） |
| 边车二进制 | `.build/release/LagoonServerCLI`（env `LAGOON_V4_SIDECAR` 可覆盖） | Tauri `externalBin`，文件名必须带 target-triple 后缀 |

> 密钥文件缺失时：开发期由脚本/外壳**生成一次**再写入（0600），不覆盖已有文件。

---

## 3. 启动序列（外壳负责）

```
read keys ──► pick free port ──► spawn sidecar(env: DB/PORT/KEYS) ──► poll /healthz (≤20s)
                                                                       ├─ 200 ──► phase=ready
                                                                       └─ timeout/exit ──► phase=failed(error)
```

- 端口：外壳自己挑空闲端口（先 bind `:0` 取端口再释放，随后重试兜底），**不固定 8080**。
- 边车工作目录：**固定为仓库根**（`config/providers.json` 按 CWD 解析；Finder 启动时 CWD 是 `/`）。打包期改为资源目录，M2 处理。
- 开发期并发：`scripts/dev.sh` 与外壳会各起一个边车共用 `.dev/data/lagoon.sqlite`（WAL 可并发但会等锁）——**联调时只留一个**，浏览器模式用脚本的，外壳模式用外壳自己的。
- 子进程退出：自动重启一次；连续两次失败 → `phase=failed`，错误文案带上原因分类。
- 外壳退出：先 SIGTERM 边车，5s 未退再 SIGKILL；不留孤儿进程。

---

## 4. Tauri 命令

### 4.1 `boot_status`

```ts
invoke("boot_status") => {
  phase: "starting" | "ready" | "failed";
  port?: number;          // ready 时才有
  pid?: number;
  backend?: "swift" | "rust";   // v0.2：本次运行的业务后端（--backend / LAGOON_V4_BACKEND）
  error?: { code: "spawn" | "health-timeout" | "exited" | "keys" | "port"; message: string };
}
```

后端选择：`--backend swift|rust`（或 `LAGOON_V4_BACKEND`）。R3.6 起默认仍是 `swift`；
Rust 后端能覆盖写路径后（R3.5）翻成默认 `rust`，Swift 仅作对照。前端不感知后端，唯一区别是
`backend` 字段与「Rust 后端暂未实现的端点会回 ok:true + 404 空体」——前端必须照协议把它显示成
「这个操作在当前后端不可用」，而不是网络错误。

### 4.2 `api` —— 唯一的业务通道

```ts
type ApiRequest = {
  method: "GET" | "POST" | "PATCH" | "DELETE";
  path: string;                       // 必须以 "/api/" 或 "/healthz" 开头
  query?: Record<string, string>;     // 值由前端负责转成服务端接受的格式
  body?: unknown;                     // JSON；undefined = 无 body
};

type ApiResponse =
  | { ok: true;  status: number; body: unknown }                       // 服务端答复（含 4xx/5xx）
  | { ok: false; status: 0; error: { code: "not-ready" | "transport" | "timeout" | "bad-path" | "bad-request"; message: string } };
```

**参数包装已钉死**：`invoke("api", { request: { method, path, query, body } })` —— 带 `request` 包装（前端只用这种）。
外壳同时接受平铺形式 `{ method, path, query, body }`（兼容用途，工具/手测方便），但**不用于前端代码**。
`query` 的值可以是 string / number / boolean / null：外壳统一转成字符串（null → 空串），保证 `limit=500` 这种数字参数不会被 serde 拒掉。

规则：

- `ok: true` 时 `body` 是服务端 JSON **原样**（包括 `{"error":"archive-unavailable"}` 这种业务错误，以及 409 能力闸门）。
- 只有“没连上/超时/路径非法”才是 `ok: false`。**前端不得把 `ok:false` 与 4xx 混为一种状态。**
- 超时：连接 5s、读 60s（附件/body 可能慢）。
- 请求头固定：`Authorization: Bearer <token>`、`Accept: application/json`；body 有值才加 `Content-Type: application/json`。
- 不缓存、不重放写操作。GET 允许一次重试（仅 `transport` 类失败）。

### 4.3 `restart_sidecar`（仅开发期暴露）

```ts
invoke("restart_sidecar") => { ok: boolean; phase: "starting" | "ready" | "failed" }
```

### 4.4 事件 `boot-status`

payload 同 `boot_status` 的返回值。前端订阅它驱动启动页，不要轮询 `boot_status`。

### 4.5 `download` —— 二进制通道（附件）

`api` 只承载 JSON：代理会把非 JSON 的 body 转成一个有损 `String`，一个 PDF 走那条路必然损坏。
附件因此走第二条、也是**唯一**的第二条通道：

```ts
invoke("download", { request: { path, query?, filename? } }) => {
  ok: boolean;
  status: number;
  path?: string;                                  // 仅 2xx：保存到哪
  code?: string;                                  // 服务端 {"error": …} 的码
  error?: { code: "not-ready" | "transport" | "timeout" | "bad-path" | "save"; message: string };
}
```

规则与 `api` 一致，另外三条：

- `ok` 的含义不变：**服务端答复了才是 `ok: true`**。404 也是答复
  （`{ ok: true, status: 404, code: "attachment-not-found" }`），连不上才是 `ok: false, status: 0`。
- 只接受 `path` 以 `/api/` 开头且不含 `..`；token 只在外壳进程里加，绝不回传。
- 2xx 的字节写到 `<数据目录>/downloads/` 下：文件名只保留最后一段、去掉控制字符与前导点、
  截到 120 字符；**同名文件不覆盖**（`report.pdf` 第二次成为 `report 2.pdf`），然后在访达里
  `open -R` **显示**它。**不打开**文件——`invoice.command` 不能因为被点了一下就执行。

`query` 的值照 `api` 的规则统一转字符串（这里用 `accountId`）。

---

## 5. 浏览器开发模式（没有 Tauri 时）

前端必须能在普通浏览器里跑（Playwright / 人工验收用），此时走 **Vite 同源 dev 代理**：

- 页面请求 `/api/*`（同源）→ Vite dev server 代理到 `http://127.0.0.1:<sidecar 端口>`，**由代理层加 `Authorization: Bearer <token>`**；
- token 与目标端口来自 `.dev/web.env`（gitignore，`scripts/dev.sh` 写入），只存在于 dev server 进程里 —— **浏览器侧永远拿不到 token**；
- 为什么不直连：v3 服务端零 CORS（`recon/server-contract.md` §9），跨源 `fetch` 发得出去、读不到响应；同源代理同时消灭了 CORS 与“token 进浏览器”两个问题；
- 生产路径不变：Tauri `invoke("api")`；构建时 `virtual:sidecar-env` 返回空串，**dist 内不含 token 与端口**（已扫）。

前端的 API 客户端必须只有一个入口（`api(request)`），两种模式在内部切换；界面代码不感知模式。
唯一的例外是附件下载：`downloadFile(request)` 在 Tauri 里走 §4.5 的 `download` 命令，在浏览器里
`fetch` 成 Blob 交给浏览器下载——两条路都拿不到 token。

---

## 6. 版本与兼容

- 破坏性变更：改版本号到 `v0.2`，同时改 `shell` 与 `web` 两侧并更新本文件。
- 新增可选字段/新命令：不算破坏，但要在本文档登记。
- 本文件由 Lead 维护；`shell/` 与 `web/` 的 README 都指向它，不复制内容。
