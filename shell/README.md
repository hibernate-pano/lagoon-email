# shell — Lagoon V4 Rust 外壳（Tauri 2）

M1 的外壳进程。它做三件事，别的一律不做（ADR 0001 / ipc-contract v0.1）：

1. **监督 Swift 边车**：挑空闲端口 → 读/生成密钥 → spawn `LagoonServerCLI` → 轮询 `/healthz` ≤20s → `phase=ready`；崩了重启一次，两次失败 `phase=failed`；退出时 SIGTERM → 5s → SIGKILL。
2. **唯一 HTTP 通道**：`api` 命令代理到 `http://127.0.0.1:<port>`，**Bearer token 只存在本进程**，路径白名单 `/api/*` 与 `/healthz`。
3. **窗口**：1200x800、标题 `Lagoon V4`、图标来自 `Support/Lagoon.icns`。

接口真相在 [../docs/ipc-contract.md](../docs/ipc-contract.md)，本文件不复制它。

---

## 快速开始

```bash
# 一条命令（检查边车二进制存在 → cargo run）
bash scripts/tauri-dev.sh

# 或者直接
cd shell && cargo run

# 无窗口验收（启动边车、跑全部 API 用例、崩溃重启、清理）
bash scripts/tauri-dev.sh selftest
# 等价于：cargo run -- --selftest
```

首次运行会在 `.dev/keys.json` 生成一对密钥 + API token（`0600`，已 gitignore）；数据目录 `.dev/data/`。**这两处都是 dev-only**，发布期按契约 §2 换 data-protection Keychain。

## 三个命令 + 一个事件

| 名称 | 形状 | 实现 |
|---|---|---|
| `boot_status` | 契约 §4.1 | `src/main.rs` |
| `api` | 契约 §4.2（唯一业务通道） | `src/api.rs` |
| `restart_sidecar` | 契约 §4.3 | `src/sidecar.rs::restart` |
| 事件 `boot-status` | 契约 §4.4 | `src/state.rs::publish` |

`api` 的**参数包装两种都接受**：`invoke("api", { request })` 与 `invoke("api", request)`。契约只钉了类型、没钉包装，猜错会让前端第一天就坏，所以两种都收（`src/api.rs::parse_request`，有单测）。这是**向后兼容的宽松实现**，不是协议扩展。

## Tauri 2 的 capabilities（踩过，别再踩）

`@tauri-apps/api/event` 的 `listen` 是 **core 命令**，Tauri 2 默认**不授权**。没有 `capabilities/default.json` 时它会以
`event.listen not allowed. Permissions associated with this command: core:event:allow-listen, core:event:default`
拒绝 —— 而自定义命令 `invoke("boot_status")` 仍然成功，所以症状是「窗口起来了、却永远停在启动页」（2026-10-29 实测并修复）。

- 本目录的 `capabilities/default.json` 授予 `core:default`（含 event 的 listen/emit），窗口 label 是 `main`；
- 自定义命令（`boot_status` / `api` / `restart_sidecar`）**不需要** capability；
- 删掉这个文件 = 前端再也收不到 `boot-status` 事件。

## 两种后端：`--backend swift|rust`（R3.6）

同一个外壳、同一份 Web UI、同一套命令，业务后端可切换：

| 选择方式 | 说明 |
|---|---|
| `--backend swift` / `--backend rust` | 命令行，优先级最高 |
| `LAGOON_V4_BACKEND=swift|rust` | 环境变量（命令行未给时生效） |
| 都不写 | **默认 `swift`**（R3.5 完成后由 lead 翻成 `rust`） |

非法值不猜：直接 `[shell] unknown backend "x"` 并以 **退出码 2** 结束，避免 UI 静默连到另一个服务端。

| 后端 | 二进制（可用环境变量覆盖） | 启动方式 |
|---|---|---|
| `swift` | `.build/release/LagoonServerCLI`（`LAGOON_V4_SIDECAR`） | 环境变量：`LAGOON_DB_PATH` / `LAGOON_SERVER_PORT` / `LAGOON_TOKEN_KEY` / `LAGOON_BODY_KEY` / `LAGOON_API_TOKEN` |
| `rust` | `crates/target/debug/lagoon-api`（`LAGOON_V4_RUST_API`） | 参数 `--db <data>/lagoon.sqlite --host 127.0.0.1 --port <port>`；环境变量只给 `LAGOON_BODY_KEY` / `LAGOON_API_TOKEN`（密钥不走 argv，`ps` 看得见） |

`boot_status` 与 `boot-status` 事件都多了一个 **`backend`** 字段（契约 v0.2 §4.1）：前端据此知道当前跑的是哪个后端，但**不需要**据此改请求路径。

**Rust 后端目前只读**（R1/R2 范围）：它实现了全部 `GET /api/*`，写端点**没有路由**，因此返回 **404 + 空 body**。按契约这是 `ok:true`（服务端答复），不是 `ok:false`——前端必须把它显示成「这个操作在当前后端不可用」，而不是网络错误。`--selftest` 对这一点有专门断言（`POST /api/accounts/imap`：rust 期望 404 + body=null；swift 期望自家 4xx）。

切回 swift：把上面任一选择方式改成 `swift`（或删掉变量）即可，无需改代码、无需重启其它服务。


## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `LAGOON_V4_BACKEND` | `swift` | `swift` 或 `rust`，见上一节（R3.6） |
| `LAGOON_V4_SIDECAR` | `.build/release/LagoonServerCLI`，回退 debug | 契约 §2（仅 swift 后端） |
| `LAGOON_V4_RUST_API` | `crates/target/debug/lagoon-api` | 仅 rust 后端 |
| `LAGOON_V4_DATA_DIR` | `.dev/data` | 契约 §2 |
| `LAGOON_V4_ROOT` | 编译期 `CARGO_MANIFEST_DIR` 上溯两级 | 仓库根；Finder 启动时也能定位 |
| `LAGOON_V4_KEYS` | `.dev/keys.json` | 本实现新增的 dev 逃生口，默认行为与契约一致 |

边车拿到的环境（v3 CLI 的既有契约，`Sources/LagoonServerCLI/main.swift:21-65`）：

```
LAGOON_DB_PATH=<data>/lagoon.sqlite
LAGOON_SERVER_HOST=127.0.0.1
LAGOON_SERVER_PORT=<选中的端口>
LAGOON_TOKEN_KEY=<base64 32B>
LAGOON_BODY_KEY=<base64 32B>
LAGOON_API_TOKEN=<hex>
```

边车的 `current_dir` 被固定为仓库根：v3 CLI 按 CWD 解析 `config/providers.json`，Finder 启动的 app CWD 是 `/`，不固定就会读到不同的配置。

## 为什么不用 `tauri-plugin-shell`

shell 插件是给**前端**执行二进制用的，等于给 WebView 开一个"可执行任意程序"的 capability。外壳自己 spawn 边车用 `std::process::Command` 就够，所以这个插件**没有被链接进来**（详见 recon 的 rust-spike 笔记 §4.2A）。

## 验收

```bash
cd shell
cargo build            # 冷编译（含 tauri + reqwest 依赖）约 42s；增量 < 3s
cargo test             # 5 个单测：白名单 / 方法 / 参数包装 / query 编码 / body 映射
cargo run -- --selftest  # 每个可用后端各 13 项（swift + rust 都跑），见 ACCEPTANCE.md
# 只跑某一个后端的窗口：
cargo run -- --backend rust
LAGOON_V4_BACKEND=rust cargo run
```

最近一次实跑记录（含日志原文）在 [ACCEPTANCE.md](ACCEPTANCE.md)。

## 打包（M2，不在 M1 范围）

- 现在 `tauri.conf.json` 里 `bundle.active = false`，只出裸二进制；出 .app/.dmg 需要 tauri-cli。
- 打包时边车要改成 Tauri 的 `externalBin`，**磁盘文件名必须带 target-triple 后缀**（`binaries/lagoon-server-aarch64-apple-darwin`），tauri-build 在编译期把后缀剥掉再拷进 bundle（recon 的 rust-spike 笔记 §4.1 有 crate 源码行号）。
- 本机只有 Command Line Tools、没有完整 Xcode；且没有 rustup（只能 `aarch64-apple-darwin`）。签名/公证/universal binary 都**未验证**，属于 M2 的待办而不是 M1 的缺陷。

## 已知限制（M1 有意为之）

1. **前端是占位页**（`ui/index.html`）：它只证明 IPC 桥、事件订阅和 `api` 代理可用。真正的界面在 `web`；接上时把 `tauri.conf.json` 的 `build.frontendDist` 从 `./ui` 改成 `../web/dist`（一行），并保留 `withGlobalTauri` 或改用 `@tauri-apps/api` 包。
2. **图标**是从 `Support/Lagoon.icns` 用 `sips` 转的 32/128/256/512/1024 PNG。`generate_context!` 硬性要求 `icons/icon.png`，缺失会让 proc-macro panic（recon 的 rust-spike 笔记 §3.4）。
3. **空 body → `null`，非 JSON body → 字符串**：契约说 body 是"服务端 JSON 原样"，服务端对 404 返回空 body，所以这里有一个明确的映射（`src/api.rs::body_value`），README 与代码注释都写了，不静默改写。
4. **未打包运行时窗口的 LS 身份是继承的**：从终端直接跑裸二进制，系统把窗口归到父 app 名下（本机实测显示为 "DeepSeek Harness"），所以按窗口 owner 名判断"窗口起没起"不可靠；验收改用 **pid + 窗口尺寸 1200x800**（见 ACCEPTANCE.md）。
5. **dev 期两个进程共用一个 SQLite**：`scripts/dev.sh`（给浏览器模式）和本外壳会各起一个边车，指向同一个 `.dev/data/lagoon.sqlite`。WAL 允许，但写入会互相等锁；同一时刻只跑一个更稳。
6. **崩溃重启预算只有一次**（契约要求），且重启会换端口——前端必须用 `boot-status` 事件里的新端口，不能缓存旧端口。
7. 没有 updater / 通知 / 托盘 / 深链（M2）。

## 文件地图

```
src/main.rs      Tauri builder、3 个命令、退出时清理、--selftest 入口
src/state.rs     BootStatus/Phase、事件发布、child 句柄、SIGTERM→SIGKILL
src/sidecar.rs   端口、spawn（env/CWD）、healthz、supervise 循环、restart、信号处理
src/api.rs       契约 §4.2：校验、白名单、透传、错误分类、GET 单次重试
src/keys.rs      keys.json：生成一次 0600、校验 32 字节、绝不打印
src/port.rs      bind :0 取端口 + 重试
src/selftest.rs  --selftest：驱动真实 supervise + forward 的验收脚本
ui/index.html    占位页：订阅 boot-status、调 boot_status / api
icons/           sips 从 Support/Lagoon.icns 转出
```
