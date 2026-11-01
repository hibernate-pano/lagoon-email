# ADR 0001 · v4 走「先壳后凿」：Rust 外壳 + Web 前端 + Swift 边车

- 日期：2026-10-29
- 状态：**已采纳（用户授权自主执行，推荐项 1b/2a/3b/4b）**
- 背景：见 `v4/00-理解与方案.md`

## 决定

1. 外壳用 **Tauri 2**（系统 WebView），前端用 **Vite + React + TS + 手写 CSS 变量**，不用组件库。
2. 过渡期后端 = **v3 的 `LagoonServerCLI` 边车**（独立进程、env 注入密钥、系统分配端口）；Rust 外壳负责生命周期与 HTTP 代理。
3. **前端不持有 token**，所有请求经 Rust 代理（详见 `docs/ipc-contract.md`）。
4. 数据与密钥**独立于 v3**（`Lagoon-v4` 目录 + 新密钥）：实测 v4 读不到 v3 的 data-protection Keychain 条目。
5. Rust 后端迁移按 storage → AI → mail → sync 的顺序，每个模块以 `tests/contract/` 为 oracle，可回退到边车。

## 被否决的选项

- **Electron**：引入第二个 JS 运行时，与“用 Rust 包装”的诉求相悖，体积/内存最差。
- **裸 wry**：省掉 Tauri 的 sidecar/更新器/托盘能力，等于自己重造轮子。
- **直接 Rust 重写后端**：3–4 个月才出第一个可运行版本，且要重新验证 QQ/IMAP 边角。
- **共享 v3 的 SQLite**：密钥拿不到（−25300），封存正文/草稿解不开。

## 后果

- 正面：M1 就能看到真实界面；契约与测试可复用；每一步可回退。
- 负面：M1–M2 是双进程，需要处理副作用（单写者、孤儿进程、端口）；M3 之前无法跨平台。
- 触发复审的条件：Tauri 在 Windows/Linux 的关键能力（托盘/通知/深链）无法等价实现；或 M3 发现 IMAP 边角成本失控。
