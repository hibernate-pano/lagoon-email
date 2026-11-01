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
  ├─ WebView：React 19 + TS + Vite 前端（web）
  ├─ Rust 外壳（shell）：窗口 / 进程监督 / HTTP 代理 / Keychain（M2）
  │     └─ 过渡期边车：v3 的 LagoonServerCLI（开发期脚手架，不进发布物）
  └─ Rust 后端（crates，R1 起）：axum + rusqlite，逐模块取代边车
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
| **产品打包（rust-only）** | ✅ `bash scripts/build-product.sh` → `dist/Lagoon.app`（19MB）；构建只需 rust+node，**不含 Swift**；默认后端 `rust`，fresh install 自动迁移（ADR 0003） |
| R3.5a 写路径 | ✅ 归档/取消归档/废纸篓/恢复/彻底删除/已读/置顶/批量/清空/审计/撤销；api **91 测试**；写 trait 与同步 trait 分离（编译期保证同步不写） |
| R3.5b 发送 | ⏳ SMTP 回复/转发/新邮件 + requestId 幂等 |
| M4 分发 / 跨平台 | ⏳ Developer ID 签名、更新器、Windows/Linux |
| 验收记录 | 📋 `docs/acceptance-2026-10-29.md` · ADR：[0002](docs/adr/0002-rust-backend-first.md) · [0003](docs/adr/0003-rust-default-product.md) |

## 怎么跑

```bash
# 产品：一条命令构建 Lagoon.app（只需 rust + node，不需要 Xcode/Swift）
bash scripts/build-product.sh
open dist/Lagoon.app

# 开发：跑测试
cargo test --manifest-path crates/Cargo.toml    # 后端（crates/）
cd web && npm run build                          # 前端
cd shell && cargo run -- --selftest              # 外壳自检

# 契约一致性（对任意运行中的后端实例）
bash scripts/contract-check.sh http://127.0.0.1:PORT TOKEN
```

**联调注意**：外壳会自己拉起后端；浏览器开发模式见 `docs/ipc-contract.md` §5。

## 纪律

- **前端不持有 token**：只有 `web/src/core/api.ts` 一个入口；Tauri 模式走 `invoke("api")` 由 Rust 代理。
- **契约先行**：改协议先改 `docs/api-contract.md`，fixture 用 `tests/contract/` 回放。
- **密钥**：开发期 0600 文件（`.dev/keys.json`）；发布期接 Keychain（需稳定签名身份）。

## 历史

Swift 版 v3.2.0 与本版本的演进过程都在 git 历史里（checkpoint 提交 11ae71b 之前的树即 Swift 产品）。
