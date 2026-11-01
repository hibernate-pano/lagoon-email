# v4 · 外部版本（Rust + Web）

**Lagoon 的下一代形态，与 v3 并行。发布物里没有 Swift。**
v3（`/Sources`，SwiftUI + 进程内 Hummingbird）保持可构建、可运行、测试全绿。

- 想法与方案：[00-理解与方案.md](00-理解与方案.md)（三层拆解、四路线、里程碑、风险）
- 决策记录：[docs/adr/0001-strangler-tauri-shell.md](docs/adr/0001-strangler-tauri-shell.md)
- 外壳 ↔ 前端协议：[docs/ipc-contract.md](docs/ipc-contract.md)（v0.1，冻结）
- M1 验收清单：[docs/m1-checklist.md](docs/m1-checklist.md)
- 侦察证据：[recon/](recon/)（server 契约 57 端点 / client 表面 24 界面 / Rust 实测）

## 形态

```
Lagoon v4.app（Rust / Tauri 2 外壳，发布物只含它 + Web 资源）
  ├─ WebView：React 19 + TS + Vite 前端（v4/web）
  ├─ Rust 外壳（v4/shell）：窗口 / 进程监督 / HTTP 代理 / Keychain（M2）
  │     └─ 过渡期边车：v3 的 LagoonServerCLI（开发期脚手架，不进发布物）
  └─ Rust 后端（v4/crates，R1 起）：axum + rusqlite，逐模块取代边车
```

## 状态

| 里程碑 | 状态 |
|---|---|
| M0 契约冻结 + fixtures | ✅ `docs/api-contract.md` + `tests/contract/`（**56 条 = 54 抓取 + 2 contract_expected**，54/54 match，两次抓取 byte-identical） |
| M1 Rust 外壳 | ✅ `shell/`：边车监督 / api 代理 / boot 事件 / 无孤儿；`--selftest` 12/12；已接真实 `web/dist`，Tauri 模式端到端 3 个 200（见 `docs/m1-checklist.md` §1.2） |
| M1 Web 前端 | ✅ `web/`：六态 / 引导 / 侧边栏 / 简报 / 列表 / 阅读器（sandbox iframe）/ 命令面板 / 搜索（客户端过滤）/ 写路径（M2） |
| R1+R2 Rust 读面 | ✅ 24 组路由；api **85 测试**；契约 54/54；与 v3 同库 46/48 SAME + 2 EXPLAINED（search 修复） |
| M2 Web 写路径 | ✅ 归档/废纸篓/撤销/动作历史/键盘；409 回滚与能力闸门实测；远端成功路径待真实邮箱 |
| R3.1 邮件协议层 | ✅ `crates/lagoon-mail`：IMAP/SMTP/MIME/GBK + 假传输，**196 测试**，零外联 |
| R3.2 迁移与可写 store | ✅ v3 的 11 条迁移逐字等价（30 对象/11 identifier diff 全同） |
| R3.3 账号生命周期 | ✅ 凭据裸 AES-GCM 双向互操作；accounts 路由矩阵 |
| R3.4 同步 + 生产 provider | ✅ UIDVALIDITY/退避/单写者；`LAGOON_MAIL_PROVIDER` 默认 none；成员集合单会话（4→1 连接） |
| **产品打包（rust-only）** | ✅ `bash v4/scripts/build-product.sh` → `v4/dist/Lagoon.app`（19MB）；构建只需 rust+node，**不含 Swift**；默认后端 `rust`，fresh install 自动迁移（ADR 0003） |
| R3.5a 写路径 | ✅ 归档/取消归档/废纸篓/恢复/彻底删除/已读/置顶/批量/清空/审计/撤销；api **91 测试**；写 trait 与同步 trait 分离（编译期保证同步不写） |
| R3.5b 发送 | ⏳ SMTP 回复/转发/新邮件 + requestId 幂等 |
| M4 分发 / 跨平台 | ⏳ Developer ID 签名、更新器、Windows/Linux |
| 验收记录 | 📋 `docs/acceptance-2026-10-29.md` · ADR：[0002](docs/adr/0002-rust-backend-first.md) · [0003](docs/adr/0003-rust-default-product.md) |

## 怎么跑

```bash
# 0) 一条命令（边车 + Vite dev server，浏览器模式）
bash v4/scripts/dev.sh

# 1) 开发期边车（v3 CLI，独立数据目录 v4/.dev/data，密钥 v4/.dev/keys.json）
bash v4/scripts/sidecar-dev.sh start     # 生成密钥 + 起边车 + 写 v4/.dev/web.env
bash v4/scripts/sidecar-dev.sh status

# 2) 前端（浏览器模式，Playwright 用）
cd v4/web && npm install && npm run dev  # http://127.0.0.1:5173

# 3) Rust 外壳（起自己的边车 + WebView）
bash v4/scripts/tauri-dev.sh             # 或 cd v4/shell && cargo run
cd v4/shell && cargo run -- --selftest   # 12 项无头验收

# 4) 契约一致性（任何后端都必须过）
bash v4/scripts/contract-check.sh        # 起临时实例回放 fixtures
bash v4/scripts/contract-check.sh http://127.0.0.1:PORT TOKEN   # 打已运行实例

# 5) Rust 后端（只读，R1）
cd v4/crates && cargo test --offline
cd v4/crates/lagoon-api && bash scripts/diff-vs-v3.sh   # 与真 v3 边车逐字段 diff
```

**联调注意**：`sidecar-dev.sh` 与外壳会各起一个边车，共用 `v4/.dev/data/lagoon.sqlite`（WAL 可并发但会等锁）——同一时间只留一个。

## 纪律

- **不改 v1**：`Sources/`、`Tests/`、`Package.swift` 一行不动；v3 始终 `bash scripts/run-all-tests.sh` 全绿。
- **前端不持有 token**：只有 `web/src/core/api.ts` 一个入口；Tauri 模式走 `invoke("api")` 由 Rust 代理，浏览器模式仅开发用。
- **数据与密钥独立**：v4 不读 v3 的 Keychain（实测 −25300），用自己的密钥与 `Lagoon-v4` 数据目录。
- **契约先行**：任何后端（Swift 边车 / Rust）都必须过 `tests/contract/`；改协议先改 `docs/ipc-contract.md`。

## M1 的三条刻意的“不”

| 不做 | 原因 |
|---|---|
| 不调用 `POST /read` | 它会 `UID STORE \Seen`，真写远端邮箱；M1 承诺只读。M2 连同撤销审计一起打开 |
| 不调用 `GET /api/search` | v3.2.0 该端点必然 500（pass-B SQL 漏 JOIN `advice`）；M1 用客户端过滤，Rust 后端期重写 |
| 浏览器不直连边车 | v3 零 CORS；改走 Vite 同源代理，token 只存在于 dev server 进程（`docs/ipc-contract.md` §5） |

## 需要你（用户）做的

1. **QQ 邮箱授权码**（16 位）：在 v4 连接页输入一次，M1 才有真实邮件可看。
2. **稳定签名身份**：决定 Keychain 与通知能否稳定（开发期暂用 `v4/.dev/keys.json` 绕过）。
3. 确认最终数据目录名（当前 `~/Library/Application Support/Lagoon-v4/`）。
