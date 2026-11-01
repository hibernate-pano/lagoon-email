# M1 验收记录 · v4/shell

全部在本机（macOS 27.2 / arm64 / rustc 1.99.1 Homebrew / 无 Xcode）实际跑出，日志为原文摘录。
可复现：`cd v4/shell && cargo test && cargo run -- --selftest`。

## 1. cargo build

```
$ cargo build
   Compiling tauri-runtime-wry v2.12.3
   ...
   Compiling tauri v2.12.5
   Compiling lagoon-v4-shell v0.1.0 (.../v4/shell)
warning: field root is never read    <- 已修（root 现在写进 spawn 日志）
    Finished dev profile in 36s      <- 依赖编译（首次）
$ cargo build                        <- 第二次
    Finished dev profile in 5.69s
$ cargo build
    Finished dev profile in 0.98s    <- 增量
```

冷编译到可运行 debug 二进制 ≈ 42s。Cargo.lock 实际版本：`tauri 2.12.5` / `tauri-build 2.7.4` / `tauri-runtime-wry 2.12.3` / `reqwest 0.13.5` / `tokio 1.54.1` / `serde_json 1.0.154`。

## 2. cargo test（单元）

```
running 5 tests
test api::tests::unknown_method_is_bad_request ... ok
test api::tests::query_is_encoded_not_dropped ... ok
test api::tests::whitelist_accepts_api_and_healthz_only ... ok
test api::tests::parse_accepts_wrapped_and_flat_shapes ... ok
test api::tests::body_mapping_is_documented_shape ... ok
test result: ok. 5 passed; 0 failed
```

## 3. cargo run -- --selftest（无窗口，12 项）

```
[selftest] no window; same supervisor + proxy code as the GUI
[selftest] PASS api before boot => ok:false code=not-ready status=0
           {"ok":false,"status":0,"error":{"code":"not-ready","message":"sidecar is \"starting\""}}
[boot] {"phase":"starting"}
[sidecar] spawned pid=82567 port=53811 bin=.../.build/release/LagoonServerCLI db=.../v4/.dev/data/lagoon.sqlite root=.../lagoon-email
[sidecar] 2026-10-29T13:28:54+0800 info lagoon.server : [HummingbirdCore] Server started and listening on 127.0.0.1:53811
[boot] {"phase":"ready","port":53811,"pid":82567}
[selftest] PASS phase=ready with port+pid
[selftest] PASS api GET /healthz => ok:true status=200
           {"ok":true,"status":200,"body":"ok"}
[selftest] PASS api GET /api/accounts => ok:true status=200 body=[]
           {"ok":true,"status":200,"body":[]}
[selftest] PASS api GET /api/does-not-exist => ok:true status=404 (passthrough)
           {"ok":true,"status":404,"body":null}
[selftest] PASS wrong Bearer => 401
           status=401
[selftest] PASS real Bearer (proves the header is what authorises) => 200
           status=200
[selftest] PASS api GET /etc/passwd => ok:false code=bad-path
           {"ok":false,"status":0,"error":{"code":"bad-path","message":"path \"/etc/passwd\" is not under /api/ (or /healthz)"}}
[selftest] PASS api TRACE /api/accounts => ok:false code=bad-request
           {"ok":false,"status":0,"error":{"code":"bad-request","message":"unsupported method \"TRACE\"; use GET, POST, PATCH or DELETE"}}
[selftest] SIGKILL sidecar pid=82567 to exercise the restart path
[boot] sidecar exited (ExitStatus(unix_wait_status(9))); restarting once
[boot] {"phase":"starting"}
[sidecar] spawned pid=82569 port=53816 ...
[boot] {"phase":"ready","port":53816,"pid":82569}
[selftest] PASS crash => restarted once, phase=ready with a new pid
           old pid=82567 -> new pid=82569 port=53816
[sidecar] SIGTERM pid=82569
[sidecar] exited cleanly pid=82569 status=ExitStatus(unix_wait_status(0))
[selftest] PASS no orphan after shutdown
[selftest] 0 failure(s)
```

（重启后端口从 53811 变成 53816 —— 契约允许，前端必须读事件里的新端口。）

## 3b. restart_sidecar（契约 §4.3）

restart_sidecar 命令包的就是 `sidecar::restart`，selftest 直接驱动它（没有窗口时调不到命令本身）。
追加该用例后（共 12 项）：

```
[boot] {"phase":"ready","port":58289,"pid":86661}
[selftest] PASS crash => restarted once, phase=ready with a new pid
[boot] {"phase":"ready","port":58296,"pid":86663}
[selftest] PASS restart_sidecar => phase=ready again with a new pid
[selftest] PASS no orphan after shutdown
[selftest] 0 failure(s)
```

端口每次重启都会变（58289 → 58292 → 58296）：契约允许，但前端必须读事件里的新端口。

## 4. cargo run（GUI）：窗口 + phase=ready

```
$ cargo run --quiet        # 日志里 [boot]/[ipc] 为外壳打印
[boot] {"phase":"starting"}
[boot] {"phase":"starting"}
[ipc] boot_status -> phase=starting port=None
[boot] {"phase":"ready","port":56736,"pid":84989}

$ swift target/verify/windows.swift <binary-pid>
ON_SCREEN WINDOW owner=DeepSeek Harness title=<redacted> size=1200x800 layer=0 alpha=1.0
```

两处证据的含义：

- `[ipc] boot_status` 只可能由 **WebView 里的 JavaScript** 触发（`ui/index.html` 加载即调用），所以它出现 = 页面真的加载并执行了，IPC 桥通。
- 按 **pid** 过滤的 CoreGraphics 窗口列表里出现 **1200x800 / layer 0 / alpha 1.0** 窗口 = 窗口真的在屏幕上，尺寸与 `tauri.conf.json` 一致。
  （窗口标题被系统 redact，owner 名也不可信：未打包的裸二进制会继承父进程的 LS 身份，本机显示为 "DeepSeek Harness"。这是 dev 期现象，打包成 .app 后 owner 才是 Lagoon V4。）

## 5. 退出清理（不留孤儿）

```
$ ./target/debug/lagoon-v4-shell &      # pid=84375, child=84385
$ kill -TERM 84375
shell alive: no; child(84385) alive: no
$ pgrep -fl LagoonServerCLI | grep -v 77238
no leftover sidecar        # 77238 是 sidecar-dev.sh 那个（不属于本外壳），全程未被动过
```

SIGTERM 路径由 `src/sidecar.rs::install_signal_handlers` 处理（只调用 async-signal-safe 的 `kill` / `_exit`），正常关窗路径由 Tauri `RunEvent::Exit` 处理（SIGTERM → 等 5s → SIGKILL）。

## 6. api 命令四类实测（契约 §4.2 逐条）

| 用例 | 期望 | 实得 |
|---|---|---|
| `GET /healthz` | `ok:true, 200` | `{"ok":true,"status":200,"body":"ok"}` |
| `GET /api/accounts` | `ok:true, 200, []` | `{"ok":true,"status":200,"body":[]}` |
| 无/错 token | 服务端 401，**外壳照原样透传** | `{"ok":true,"status":401}` 并非 `ok:false`；原始 401 用错 Bearer 直接验证；正确 Bearer 同路径 200 |
| `GET /api/does-not-exist`（404） | `ok:true, 404` | `{"ok":true,"status":404,"body":null}` |
| `GET /etc/passwd` | `ok:false, bad-path` | `{"ok":false,"status":0,"error":{"code":"bad-path",...}}` |
| `TRACE /api/accounts` | `ok:false, bad-request` | `{"ok":false,"status":0,"error":{"code":"bad-request",...}}` |
| 边车未就绪时调用 | `ok:false, not-ready` | `{"ok":false,"status":0,"error":{"code":"not-ready",...}}` |
| `restart_sidecar` | `ok:true, phase:"starting"`，事件随后推到 ready | selftest 驱动同一函数：新 pid、新端口、最终 phase=ready |

`timeout` / `transport` 两类没有在 selftest 里造（造 60s 读超时要等 60s，造 transport 要防火墙丢包）；分类逻辑在 `src/api.rs::classify`，单测覆盖到路径与方法两类拒绝，超时/传输依赖 reqwest 的 `is_timeout()`。

## 7. 未验证 / 留给后续

- 打包（`tauri build` → .app/.dmg）、签名、公证、universal binary：本机无 Xcode、无 rustup，M2 再做。
- `raw_status` 的 401 用例走的是直连边车（因为代理永远带真 token），这在报告里已注明是"证明 header 起作用"的手段，不是绕过代理。
- 真实邮箱同步、AI、附件：M1 不涉及（空库是预期）。

---

## 8. R3.6 · 两种后端（--backend swift|rust）

命令：`cd v4/shell && cargo run -- --selftest`（一次跑完两个后端；缺哪个就打印 SKIP，不算失败）。

### 8.1 后端发现与总览

```
[selftest] found swift backend: .../.build/release/LagoonServerCLI
[selftest] found rust backend: .../v4/crates/target/debug/lagoon-api
[selftest] backends under test: swift, rust
[selftest] all backends done, 0 failure(s)
```

### 8.2 swift 后端（v3 LagoonServerCLI）

```
[selftest swift] ---- run start (no window; same code paths as the GUI) ----
[selftest swift] PASS api before boot => ok:false code=not-ready status=0
[boot] {"phase":"starting","backend":"swift"}
[boot] {"phase":"ready","backend":"swift","port":61767,"pid":26706}
[selftest swift] PASS phase=ready, backend field matches, port+pid present
[selftest swift] PASS api GET /healthz => ok:true status=200
[selftest swift] PASS api GET /api/accounts => ok:true status=200 body=array
[selftest swift] PASS api GET /api/does-not-exist => ok:true status=404 (passthrough)
[selftest swift] PASS POST /api/accounts/imap => ok:true and a 4xx from the server (implemented, rejects empty body)
[selftest swift] PASS wrong Bearer => 401
[selftest swift] PASS real Bearer => 200 (proves the header is what authorises)
[selftest swift] PASS api GET /etc/passwd => ok:false code=bad-path
[selftest swift] PASS api TRACE /api/accounts => ok:false code=bad-request
[boot] sidecar exited (ExitStatus(unix_wait_status(9))); restarting once
[boot] {"phase":"ready","backend":"swift","port":61771,"pid":26707}
[selftest swift] PASS crash => restarted once, phase=ready with a new pid
[boot] {"phase":"ready","backend":"swift","port":61775,"pid":26708}
[selftest swift] PASS restart_sidecar => phase=ready again with a new pid
[selftest swift] PASS no orphan after shutdown
[selftest swift] 0 failure(s)
```

### 8.3 rust 后端（v4/crates lagoon-api，只读）

```
[selftest rust] ---- run start (no window; same code paths as the GUI) ----
[selftest rust] PASS api before boot => ok:false code=not-ready status=0
[boot] {"phase":"starting","backend":"rust"}
[boot] {"phase":"ready","backend":"rust","port":61787,"pid":26709}
[selftest rust] PASS phase=ready, backend field matches, port+pid present
[selftest rust] backend base=http://127.0.0.1:61787
[selftest rust] PASS api GET /healthz => ok:true status=200
[selftest rust] PASS api GET /api/accounts => ok:true status=200 body=array
[selftest rust] PASS api GET /api/does-not-exist => ok:true status=404 (passthrough)
[selftest rust] PASS POST /api/accounts/imap => ok:true status=404 body=null (unimplemented, not a transport error)
[selftest rust] PASS wrong Bearer => 401
[selftest rust] PASS real Bearer => 200 (proves the header is what authorises)
[selftest rust] PASS api GET /etc/passwd => ok:false code=bad-path
[selftest rust] PASS api TRACE /api/accounts => ok:false code=bad-request
[boot] sidecar exited (ExitStatus(unix_wait_status(9))); restarting once
[boot] {"phase":"ready","backend":"rust","port":61795,"pid":26710}
[selftest rust] PASS crash => restarted once, phase=ready with a new pid
[boot] {"phase":"ready","backend":"rust","port":61801,"pid":26712}
[selftest rust] PASS restart_sidecar => phase=ready again with a new pid
[selftest rust] PASS no orphan after shutdown
[selftest rust] 0 failure(s)
```

关键一行是 **8.3 的第 9 条**：`POST /api/accounts/imap` 在 rust 后端是 **`ok:true + status 404 + body null`**。
这不是「请求没发出去」，所以外壳没有把它归成 `transport`——契约 v0.2 §4.1 要求前端把它显示成「当前后端不支持该操作」。
同一个请求在 swift 后端是 **ok:true + 4xx**（端点存在、拒绝空 body），两行日志放在一起就是后端差异的全部证据。

### 8.4 GUI 窗口（rust 后端）

```
$ ./target/debug/lagoon-v4-shell --backend rust     # 9s 后检查，再 SIGTERM
[shell] backend=rust
[boot] {"phase":"starting","backend":"rust"}
[ipc] page-load url=tauri://localhost event=Started
[ipc] page-load url=tauri://localhost event=Finished
[ipc] boot_status -> phase=starting port=None
[boot] {"phase":"ready","backend":"rust","port":61851,"pid":27088}
[ipc] api GET /api/ai-status -> 200
ON_SCREEN WINDOW owner=<继承的父 app 名> size=1200x800 layer=0 alpha=1.0
after TERM: shell=gone api=gone
```

### 8.5 选择方式与非法值

```
$ ./target/debug/lagoon-v4-shell --backend bogus     ; echo exit=$?
[shell] unknown backend "bogus": use --backend swift or --backend rust
exit=2
$ LAGOON_V4_BACKEND=bogus ./target/debug/lagoon-v4-shell ; echo exit=$?
exit=2
$ LAGOON_V4_BACKEND=rust ./target/debug/lagoon-v4-shell
[shell] backend=rust
[boot] {"phase":"ready","backend":"rust","port":61924,"pid":27211}
$ ./target/debug/lagoon-v4-shell --backend swift
[shell] backend=swift
[boot] {"phase":"ready","backend":"swift","port":61976,"pid":27251}
```

`cargo test` 仍是 5/5（`api.rs` 的白名单/方法/参数包装/query 编码/body 映射；R3.6 没改这些路径）。
