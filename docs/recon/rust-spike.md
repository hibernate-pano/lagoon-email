# Rust / Tauri 2 侦察报告（v4 spike 实测）

> 任务：task-3。时间盒 25 分钟，实际约 37 分钟（P0–P3 全部完成，P4 只到"机制验证 + 结论边界"）。
> 本文件只写**跑出来的事实**；没跑通的一律标「未知」或「阻塞」，不猜。
> 所有命令都在 `v4/spike/` 内执行，产物也在 `v4/spike/` 内；除一处已披露的临时 keychain（见 §8）外没有触碰 v4 之外的文件。

---

## 0. 结论摘要

| # | 问题 | 结论 | 证据 |
|---|---|---|---|
| P0 | Rust `aes-gcm` 与 Swift CryptoKit 能否互通 `lgb1:` 信封 | **可以，双向 PASS**（ASCII / 中文+emoji / 空串 / 篡改拒绝 4 组） | §2，`v4/spike/cipher-interop/interop-transcript.log` |
| P1 | 没有 Xcode 能否 `cargo build` 一个 Tauri 2 应用 | **可以**，冷编译 ≈54s，产物 27.8 MB，能启动且 8s 不崩 | §3 |
| P1 | 手写 Cargo.toml + 静态 HTML（无打包器）可行 | **可行**，但 `generate_context!` 强制要求 `icons/icon.png`，否则 proc-macro panic | §3.4 |
| P2 | 边车（sidecar）模式 | 机制明确（`externalBin` + `-{target-triple}` 后缀 + plugin-shell），**但 v4 我建议不要用 shell 插件做边车** | §4 |
| P3 | 后端候选 crate 能否通过 `cargo check` | **13/13 通过**，总计 59s（含 rusqlite bundled 的 SQLite C 编译） | §5 |
| P4 | Rust 能否读 Swift 应用写在 Keychain 的密钥 | **未验证成功 = 阻塞**：4 个 `lagoon.*` 服务在两种 keychain 下都是 `-25300 (errSecItemNotFound)`；同进程读自建 keychain 的对照实验 PASS，说明探针本身可用 | §6 |
| — | `pnpm` 不可用（lead 给的假设） | **不成立**：本机 `pnpm 12.16.1` 可用 | §1 |

**最高价值结论**：**AES-GCM 互通没有任何风险**——Rust 侧只要 `nonce(12) || ciphertext || tag(16)` 拼接，格式完全一致，密钥就是 32 字节原始 key，不需要任何 KDF/协商。这条是 v4 迁移中唯一"必须逐字节对齐"的地方，已经跑通。

---

## 1. 工具链事实（实测）

```text
$ rustc --version   → rustc 1.99.1 (58cf8f9c3 2026-10-13) (Homebrew)
$ cargo --version   → cargo 1.99.1 (5f94df478 2026-08-27) (Homebrew)
$ rustc -vV | grep host → host: aarch64-apple-darwin
$ rustup target list --installed → bash: rustup: command not found
$ node --version    → v22.23.2
$ bun --version     → 1.3.13
$ npm --version     → 10.9.8
$ pnpm --version    → 12.16.1          ← 与 lead 给的"pnpm 不可用"不一致
$ xcode-select -p   → /Library/Developer/CommandLineTools
$ xcodebuild -version → xcode-select: error: tool 'xcodebuild' requires Xcode, but active
                        developer directory '/Library/Developer/CommandLineTools' is a
                        command line tools instance
$ clang --version   → Apple clang version 21.0.0 (clang-2100.3.34.2), target arm64-apple-darwin27.2.0
$ xcrun --show-sdk-path → /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
$ swiftc --version  → swift-driver 1.168.6 / Apple Swift 6.4 (swiftlang-6.4.0.34.1)
$ sw_vers           → macOS 27.2 (build 26B5091g), arm64
```

关键含义：

- **没有 rustup**（Homebrew 装的 rustc/cargo）→ 加交叉编译 target 必须 `rustup target add`（不存在）或者换 rustup 安装；**v4 如果要出 universal / x86_64 包会卡在这里**。本机只能编 `aarch64-apple-darwin`。→ 未知项，留给打包任务。
- **没有 Xcode，只有 CLT**：`cargo build` 能链接 AppKit/WebKit（CLT 的 MacOSX.sdk 有 .tbd stub），实测 Tauri 链接成功。但 `xcodebuild`、`xcrun altool/notarytool`、`codesign --deep 打包流程`中依赖 Xcode 的部分不可用；tauri 的 `bundle`/`dmg` 阶段（`tauri-cli`）**未验证**（本任务禁止装 tauri-cli）。
- `pnpm` 实际可用（12.16.1），lead 的假设需要更正——但这不影响 v4：本方案**不需要任何 JS 包管理器**（Tauri 的 WebView 加载静态文件即可）。

---

## 2. P0 · AES-256-GCM 互通（最高价值，已跑通）

代码：`v4/spike/cipher-interop/{Cargo.toml,src/main.rs,interop.swift,run-interop.sh,interop-transcript.log}`

### 2.1 先证明信封布局（用测量，不用假设）

Swift `AES.GCM.SealedBox.combined` 的实际字节顺序（`swift interop.swift layout` 真实输出）：

```text
plaintext_len=12
nonce_len=12 nonce_hex=ac832cf6aa1f59378d88e731
ciphertext_len=12 ciphertext_hex=23421b059c259ab568ee813d
tag_len=16 tag_hex=e9586398f14f505e574ae8209024c70b
combined_len=40 combined_hex=ac832cf6aa1f59378d88e73123421b059c259ab568ee813de9586398f14f505e574ae8209024c70b
ASSERT combined == nonce||ciphertext||tag : true
ASSERT combined[0..<12] == nonce          : true
ASSERT combined[12..<24] == ciphertext    : true
ASSERT combined.suffix(16) == tag         : true
ASSERT SealedBox(combined: nonce||ct||tag) parses: true
```

→ **断言成立：combined = 12B nonce ‖ ciphertext ‖ 16B tag**，与 v1 代码 `Sources/LagoonKit/BodyCipher.swift:42`（`lgb1:` + base64(`AES.GCM.SealedBox.combined`)）、`:71-76`（seal）、`:84-95`（open）一致。

### 2.2 双向互通实测（`run-interop.sh` 真实输出，节选）

```text
### case: ascii
plaintext      : hello lagoon v4
rust nonce_hex : 473bc0533cc6aedc21988ae6
rust envelope  : lgb1:RzvAUzzGrtwhmIrmxJe3r87WEYDiguR6sDcEnGd5DAuve5yx6g9FtysvaQ==
swift decrypt  : PLAINTEXT=hello lagoon v4
RESULT A (rust->swift): PASS
swift envelope : lgb1:LcH/xenkpJ44fimid/VyxqwwgOEm4wv8f5/7vMOkie7hqmxlSt88+qX1Xw==
rust decrypt   : PLAINTEXT=hello lagoon v4
RESULT B (swift->rust): PASS

### case: cjk+emoji
plaintext      : 你好，Lagoon —— 中文正文 🚀 with ascii tail
rust nonce_hex : fb07da1be922fbc9b3e9afa6
rust envelope  : lgb1:+wfaG+ki+8mz6a+moWT3uxsEnpL9XluRIUy6GLLc5geuV8kVzh74UsJVofWe0GzeEvrC9OXdLi08vTc3xNOvlIkVL8PDw9fOlmatkdNiMfn04IDR
swift decrypt  : PLAINTEXT=你好，Lagoon —— 中文正文 🚀 with ascii tail
RESULT A (rust->swift): PASS
swift envelope : lgb1:dKrEO5zqBGoWq5IG8Iqz7OlIBH5zFRK3CKZoYHucsQsEjaTyk+miq8X/wGv9FM0IP8IwmPWgZLv1w9E0Ro1imbMjIZvhIX/qdM8LN9WRHhJOld8Q
rust decrypt   : PLAINTEXT=你好，Lagoon —— 中文正文 🚀 with ascii tail
RESULT B (swift->rust): PASS

### case: empty-string
rust envelope  : lgb1:mSOJ32w6D7ZReLWqdYICiZL6KF/M0Gyp2x2ykw==
swift decrypt  : PLAINTEXT=
RESULT A (rust->swift): PASS
swift envelope : lgb1:P53bXkWJA/BgGfhmCCUDL374zUhmY0Ggy6b0Pw==
rust decrypt   : PLAINTEXT=
RESULT B (swift->rust): PASS

### case: tamper (bit flip in ciphertext, must be rejected by both)
tampered env   : lgb1:TEgibeiBm2yfxKUJ8IBYKo6NwwnARQgtTP9xSpxFXoVQZ4XRew==
rust  : ERROR=decrypt failed: aead::Error
swift : SWIFT_ERROR=authenticationFailure
RESULT: 两边都以"认证失败"拒绝，语义一致

### case: envelope-prefix guard
rust  : ERROR=not an lgb1: envelope
```

（注：`key_b64=` 那行是 32 个 ASCII 字符 `0123456789abcdef0123456789abcdef` 的 base64，属测试向量，不是 Keychain 里的真密钥；transcript 中原样出现，harness 侧自动打码不影响复现，脚本自己算：`printf '0123456789abcdef0123456789abcdef' | base64`。）

### 2.3 版本与一处 API 陷阱

```text
$ cargo build (cipher-interop) → Finished dev profile in 6.26s
Cargo.lock: aes-gcm 0.10.3 / aead 0.5.2 / aes 0.8.4 / ghash 0.5.1 / base64 0.22.1
$ cargo add aes-gcm (在 probe 里, 2026-10 的 registry 最新) → aes-gcm 0.11.1
$ cargo add base64                              → base64 0.23.1
```

**陷阱**：registry 上 `aes-gcm` 最新是 **0.11.1**（aead 0.6，API 与 0.10 不同：`Key::from_slice` / `Nonce::from_slice` 一类的 helpers 有变动），而本 spike 用的是 **0.10.3**（API 稳定、与 aead 0.5 生态一致）。密文格式两者相同，**但 v4 落代码时要在 Cargo.toml 里钉版本**，否则 `cargo add` 拉到 0.11 会编译不过。建议：

```toml
aes-gcm = "0.10"   # 已知可用；升 0.11 只是 API 迁移，不涉及格式
base64  = "0.22"
```

### 2.4 对 v4 的可操作结论

- 密钥 = **32 字节原始 key**（`SymmetricKey(data:)`，`Sources/LagoonKit/BodyCipher.swift:50`、`Sources/LagoonServer/Runtime/Runtime.swift:132-136`），Rust 侧 `Aes256Gcm::new(key)` 直接用，**无 KDF、无盐、无 AAD**。
- 唯一格式约束：`"lgb1:" + STANDARD_BASE64( nonce || ct || tag )`；base64 必须是标准字母表 + padding（Swift `base64EncodedString()` 默认行为），**不要用 URL-safe**。
- nonce 每次随机 12 字节（本机用 `/dev/urandom` 取，见 `src/main.rs:nonce12()`）。v1 侧由 CryptoKit 生成随机 nonce，语义一致。
- 失败语义要对齐：v1 把"认证失败/非信封"分成不同错误（`BodyCipherError`），Rust 侧也建议区分 `not an lgb1: envelope` 与 `aead error`——否则 v1 ↔ v4 双写期的诊断会退化。

---

## 3. P1 · 最小 Tauri 2 应用（无打包器，手写 Cargo.toml）

代码：`v4/spike/tauri-probe/{Cargo.toml,build.rs,src/main.rs,tauri.conf.json,ui/index.html,icons/icon.png,Cargo.lock}`

### 3.1 结构

```text
tauri-probe/
├── Cargo.toml            # tauri 2 + tauri-build 2，无 npm/tauri-cli
├── build.rs              # tauri_build::build()
├── tauri.conf.json       # frontendDist: "./ui"，bundle.active=false
├── ui/index.html         # 唯一前端文件，无打包器
├── icons/icon.png        # 32x32 PNG（必需，见 3.4）
└── src/main.rs           # Builder + invoke_handler![ping]
```

`src/main.rs` 核心（证明 IPC 桥也能用）：

```rust
#[tauri::command]
fn ping(name: String) -> String { format!("pong from rust: {name}") }

fn main() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![ping])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
```

### 3.2 编译实测

```text
# 第一次（空 target/，含全部依赖）
=== elapsed_seconds=50 ===
error: proc macro panicked
  --> src/main.rs:12:14
   |  .run(tauri::generate_context!())
   = help: message: failed to open icon .../tauri-probe/icons/icon.png: No such file or directory

# 生成 32x32 PNG 后重编（增量）
   Compiling tauri-probe v0.1.0 (.../tauri-probe)
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 4.11s
=== exit=0 elapsed=4s ===
-rwxr-xr-x@ 1 panbo staff 27817056 Oct 29 13:14 target/debug/tauri-probe
```

- **冷编译到可运行 debug 二进制 ≈ 54s**（50s 依赖 + 4.11s 本体；不是 release，也没跑 `tauri build`）。
- 产物 `target/debug/tauri-probe` = **27,817,056 字节（27.8 MB）**，arm64。
- 编译期警告：无。`rustc 1.99.1` + `clang 21` + CLT SDK 足够。

### 3.3 Cargo.lock 实际版本（节选，`v4/spike/tauri-probe/Cargo.lock`）

```text
tauri             2.12.5
tauri-build       2.7.4
tauri-macros      2.7.4
tauri-codegen     2.7.4
tauri-runtime     2.12.2
tauri-runtime-wry 2.12.3
tauri-utils       2.10.2
wry               0.57.1
tao               0.37.2
```

### 3.4 踩到的坑（必读）

1. **`generate_context!` 硬性要求 `icons/icon.png`**，否则 proc-macro panic（上引报错）。`bundle.icon = []` **不能**绕过——tauri-codegen 会回退到默认 `icons/icon.png`。用一个 32×32 RGBA PNG 即可（本 spike 用 python zlib 现生成，183 字节）。
2. **不要用 `osascript` + System Events 检查窗口**：本机上它会卡在 Automation 权限询问上（我的第一次探针就是这样超时被转后台的），在无人值守环境里会假死。
3. `bundle.active = false` 时只出裸二进制，不产物 .app/dmg；**真正打包还要 tauri-cli（本任务禁装）**，且 macOS 打包/签名在无 Xcode 环境下**未验证 → 未知**。

### 3.5 启动实测

```text
$ ./target/debug/tauri-probe &  ; sleep 8 ; kill -0 $PID
ALIVE_AFTER_8S pid=74686
--- app stderr/stdout log ---
（空，0 字节）: /tmp/tauri-probe.log
```

进程启动 8 秒仍存活、**stderr/stdout 零输出**（无崩溃、无 WebKit 断言）。窗口**是否真的画出来未用截图证明**（osascript 通道被权限卡住；本任务没有截图工具路径）→ 标「进程稳定」而非「窗口可见」。

---

## 4. P2 · 边车（sidecar / 过渡期复用 Swift 服务端）事实与推荐

### 4.1 机制事实（来自本机实际下载的 crate 源码，非记忆）

- **配置项叫 `bundle > externalBin`**：`tauri-utils-2.10.2/src/config.rs:1693  pub external_bin: Option<Vec<String>>`。
- **磁盘上必须带 target-triple 后缀**：`tauri-utils-2.10.2/src/resources.rs:45-61`
  ```rust
  /// Parses the external binaries to bundle, adding the target triple suffix to each of them.
  pub fn external_binaries(external_binaries: &[String], target_triple: &str, ...) -> Vec<String> {
      ... paths.push(format!("{curr_path}-{target_triple}{extension}"));
  }
  ```
  → 本机是 `aarch64-apple-darwin`，所以配置文件写 `"externalBin": ["binaries/lagoon-server"]` 时，**磁盘上放 `binaries/lagoon-server-aarch64-apple-darwin`**（Windows 再追加 `.exe`）。
- **编译期把后缀剥掉再拷贝**：`tauri-build-2.7.4/src/lib.rs:148-152`
  ```rust
  .replace(&format!("-{target_triple}"), "");
  ```
  产物里叫 `lagoon-server`。
- **命名冲突会直接报错**：`tauri-build-2.7.4/src/lib.rs:154-159` —— "Cannot define a sidecar with the same name as the Cargo package name"。
- **运行时 API 在 `tauri-plugin-shell`**（最新 2.6.0）：`tauri-plugin-shell-2.6.0/src/lib.rs:67-72`
  ```rust
  /// Creates a new Command for launching the given sidecar program.
  pub fn sidecar(&self, program: impl AsRef<Path>) -> Result<Command> { Command::new_sidecar(program) }
  ```
  实际 spawn 在 `src/process/mod.rs:238  pub(crate) fn new_sidecar<S: AsRef<Path>>(program: S)`。
- 权限模型：`tauri-plugin-shell` 带 `permissions/{default.toml, autogenerated, schemas}` → v2 里**必须**在 `src-tauri/capabilities/*.json` 里显式授权（`shell:allow-execute` / sidecar 白名单），否则前端调不动。（文件清单已核实；具体 permission 标识符命名 v4 落地时以 `cargo doc`/schemas 为准 → 未逐条核对）

### 4.2 推荐做法（v4 边车，按我的判断排序）

**A. 首选：Rust 侧直接 `std::process::Command` 起 Swift 服务端，不用 shell 插件。**
理由：边车由 Rust 启动 = 不需要前端权限、不需要在 capabilities 里开一个"能执行任意二进制"的口子（这是 Tauri 沙箱模型里最该省掉的权限）。`tauri-plugin-shell` 的价值在于"前端要执行命令"，v4 不需要前端执行任何东西。

**B. 传密钥/环境变量：`Command::env()` 注入，不要写进配置文件。**
- v1 的 CLI 已经支持 `LAGOON_BODY_KEY`（base64，32 字节，见 `Sources/LagoonServerCLI/main.swift:37-53`），这是现成的注入点。
- 边车进程只继承显式 `env()`，不要 `env_clear()` 之后漏掉 `PATH`；也要注意 **子进程会出现在 `ps -E`（macOS 上环境变量默认对同用户可见）** → 若要更强，用 **stdin 一次性写入 + 立刻清空** 或 **unix domain socket + 权限 0600 的文件描述符传递**，不要停在环境变量。

**C. 端口发现：推荐 stdout 握手，端口文件次之，固定端口最差。**
- **stdout 握手（推荐）**：Rust 以 `Stdio::piped()` 起边车，边车启动后第一行打印 `PORT=<n>`（v1 的 Hummingbird 服务端需要加这一行；这是 v1 唯一需要改的配合点，属"边界确认"，不属于重构），Rust 读一行 → 拿到端口 → 之后 stdout 转为日志泵。优点：无竞态、无残留文件、进程死了端口自然失效。
- **端口文件**：`~/Library/Application Support/Lagoon/port` + `flock`/原子 rename；缺点是要处理陈旧文件（进程被 SIGKILL 后残留 → 连上去是别人的端口）。若用，必须伴随 pid + start-time 校验。
- **固定端口**：最差——与"用户可能开了两个实例"和"端口被占"直接冲突；v1 已经是 127.0.0.1 + Bearer token，安全上不致命，但可用性上会踩坑。
- 无论哪种，**Bearer token 一定要走 §4.2B 的通道传**，不要落在端口文件旁边。

**D. 签名/沙箱注意**
- Tauri 打包的 macOS app 若开 App Sandbox，**子进程继承沙箱**，边车必须也在 bundle 内并带 `com.apple.security.inherit` 或自己的 entitlements；v1 的 Swift 服务端要访问 Keychain + `~/Library/Application Support`，在沙箱里行为会变 → **过渡期建议不开沙箱**（分发方式为 DMG 直发，而非 Mac App Store）。
- `codesign` 需要对**边车单独签名**（`--deep` 已废弃），且 hardened runtime 下边车也要 `--options runtime`；否则 Gatekeeper 在 M 系列上会直接 kill。
- 本机**无 Xcode → 完整 `tauri build` 打包流程未验证（未知）**；`codesign` 可用（CLT 带），但 notarization（`notarytool`）需要 Xcode 或独立下载 → 未验证。

### 4.3 边车要小心的三个现实坑

1. **生命周期**：Tauri app 被强退时子进程会变孤儿（macOS 不会自动收）。必须 `app.on_window_event(CloseRequested → child.kill())` + 边车自身做 `getppid()==1` 自杀。
2. **Swift 服务端已占 `/api/*` 的 60 个端点**：v4 Web 前端直接打它就行，**不需要在 Rust 里重写任何路由**。Rust 外壳只需要：起边车 → 读端口 → 把 `http://127.0.0.1:<port>` + token 通过 `invoke`/`window.__TAURI__` 交给前端。
3. **CORS**：WebView 的 origin 是 `tauri://localhost`（macOS）或 `http://tauri.localhost`——v1 服务端若只接受同源/无 Origin，需要对本地边车放开；这是**必查项**，我未验证（未知，建议 v4 第一阶段就测一次 `curl -H 'Origin: tauri://localhost'`）。

---

## 5. P3 · 后端候选 crate 的 `cargo check` 结果

命令：`cd v4/spike/probe && cargo add ... && cargo check`。版本来自 `cargo add` 解析到的 registry 最新（2026-10）。

```text
Locking 211 packages to highest compatible versions
   Finished `dev` profile [unoptimized + debuginfo] target(s) in 58.97s
=== cargo_check_exit=0 elapsed_seconds=59 ===
warning: the following packages contain code that will be rejected by a future version of Rust:
         imap-proto v0.10.2
```

| crate | 解析版本 | 结果 | 备注 |
|---|---|---|---|
| axum | 0.8.9 | ✅ | 同时拉入 tower 0.5.3 / tower-http 0.6.11 / hyper 1.12.0 |
| tokio | 1.54.1 | ✅ | `features=["full"]` |
| rusqlite | 0.41.1 | ✅ | `features=["bundled"]`（C 编译 SQLite，libsqlite3-sys 0.39.1），59s 里主要成本 |
| aes-gcm | 0.11.1 | ✅ | 最新版；但要与 §2.3 的 0.10 决定对齐 |
| base64 | 0.23.1 | ✅ | |
| encoding_rs | 0.8.42 | ✅ | |
| imap | 2.4.1 | ✅ | 但**间接依赖 imap-proto 0.10.2 有 future-incompat 警告** |
| async-imap | 0.12.0 | ✅ | **默认 features = async-std 运行时**（`runtime-async-std`）；要配 tokio 必须改成 `default-features=false, features=["runtime-tokio"]`（+ `tokio`/`async-compression` 按需） |
| lettre | 0.11.23 | ✅ | 默认 `native-tls` + `smtp-transport` + `pool`；v4 若要 rustls 需关默认特性 |
| mail-parser | 1.0.0 | ✅ | 默认不开 `full_encoding`（中文头解码能力受限，**建议开**） |
| reqwest | 0.13.5 | ✅ | 默认已走 rustls 系（`rustls-platform-verifier 0.7.1` / `hyper-rustls`），不依赖 OpenSSL |
| security-framework | 3.7.0 | ✅ | mac-only |
| keyring | 4.2.0 | ✅ | 4.x 拆成 `keyring-core` + store（默认拉了 secret-service/zbus，Linux 用）；macOS 要显式开 `apple-native` store 特性 → **API 与 2.x/3.x 不同，v4 落地前先看 docs** |

**结论**：后端全部候选 crate 在本机 59s 内 `cargo check` 通过，**没有任何编译级阻塞**。唯一需要注意：`async-imap` 默认运行时是 async-std（与 axum/tokio 栈不一致），必须换 feature；`imap-proto 0.10.2` 有 future-incompat 警告（不致命）。

---

## 6. P4 · Rust 读 Keychain（结论：阻塞，但边界已测清）

代码：`v4/spike/keychain-probe/{Cargo.toml,src/main.rs}`（**只查属性，从不要密文**：`load_data` 恒为 false，输出只有条目数与 OSStatus）

### 6.1 v1 的条目长什么样（源码事实）

- 类 `kSecClassGenericPassword`，**account 固定 `"primary"`**：`Sources/Lagoon/Services/KeychainStore.swift:92-102`
- **写入目标是 data-protection keychain**：`kSecUseDataProtectionKeychain = true`（`KeychainStore.swift:88 writeLocation = .dataProtection`，`:98-100`）
- `kSecAttrAccessibleAfterFirstUnlock`：`KeychainStore.swift:336`
- service 名：`lagoon.bodyKey`（`Sources/Lagoon/Services/EmbeddedServer.swift:20`）、`lagoon.tokenKey`、`lagoon.apiTokenSecret`、`lagoon.envJSON`
- 旁证：库里有 **52 条 `lgb1:` 密文**（`SELECT count(*) FROM message_bodies WHERE body_cipher LIKE 'lgb1:%'` → 52，总 52），说明 body key 确实曾被拿到并用于写入。

### 6.2 实测

```text
$ security find-generic-password -s lagoon.bodyKey      # 只查 login.keychain-db，输出经 sed 打码
security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain.
（password 行已强制替换为 <REDACTED>，全程没有打印任何密钥值）

$ ./keychain-probe        # security-framework 3.7.0，attributes-only，不限 account
probe: attributes-only SecItemCopyMatching; secrets are never requested
service                     dp_keychain   login_keychain
lagoon.bodyKey               err -25300       err -25300
lagoon.tokenKey              err -25300       err -25300
lagoon.apiTokenSecret        err -25300       err -25300
lagoon.envJSON               err -25300       err -25300
```

**-25300 = errSecItemNotFound**（不是 -34018 errSecMissingEntitlement）。

**对照组（证明探针本身不是坏的）**：在临时 keychain 里放一个条目再由 Rust 读：

```text
$ security create-keychain -p probe-pass ctl2.keychain-db
$ security unlock-keychain -p probe-pass ctl2.keychain-db
$ security add-generic-password -a primary -s lagoon.probe -w control-value ctl2.keychain-db
$ ./keychain-probe --keychain "$HOME/Library/Keychains/ctl2.keychain-db"
control: searching throwaway keychain /Users/.../ctl2.keychain-db
  service=lagoon.probe account=primary -> items=1 osstatus=0     ← 读得到
```

→ security-framework 的 **attributes-only 跨进程读取是可行的，且不弹窗**（对照条目由 `security` CLI 创建，Rust 进程读到 1 条，无任何提示）。

### 6.3 结论与解读（这里必须诚实）

- **v1 的 4 个 `lagoon.*` 条目对一个未授权（ad-hoc 签名、无 `keychain-access-groups` entitlement）的进程完全不可见**：data-protection keychain 与 login keychain 两边都是 `-25300`。
- **"不可见"有两种可能，本次无法区分**：(a) data-protection keychain 对无 entitlement 进程直接当作不存在（macOS 已知行为：不返回 -34018 而是 not-found）；(b) 条目此刻确实不存在（例如只在某次运行的进程内注入过 `LAGOON_BODY_KEY`）。**→ 标"未知"**，不猜。
- 无论 (a) 还是 (b)，工程结论一致：**Rust 进程拿不到 v1 的密钥，除非**：
  1. **同签名身份 + 同 access group**：v4 外壳用与 v1 相同的签名身份（同一 Team ID）签，并在 entitlements 里带 `keychain-access-groups`，才可能读到 data-protection 条目。v1 当前是 **ad-hoc 签名兜底**（`scripts/sign-app.sh:48` 明确写了"no usable certificate → ad-hoc"），ad-hoc 没有 Team ID → **这条大概率走不通**。
  2. **由 Swift 侧主动交接**（推荐）：v1 已经有 Keychain 读取能力，v4 过渡期让边车读 key，再按 §4.2B 的通道交给 Rust；v4 完全不碰 Keychain。
  3. **用户重新输入/重新生成**：若 v4 要自己管密钥，就要一次迁移（读旧库需要旧 key → 仍需 1 或 2）。
- **弹窗风险**：如果强行用 `SecItemCopyMatching` 带 `kSecReturnData` 去读**文件型 keychain** 里 ACL 不匹配的条目，macOS 会弹 SecurityAgent 确认，且**在无窗口的后台进程里表现为永久阻塞**——v1 就是被这个坑过（`KeychainStore.swift:26-39`、`:65-75` 的注释写得很清楚：连 `SecItemCopyMatching` 都会卡死）。**所以 v4 的探针绝对不能带 `kSecReturnData`**；本报告所有探针都是 attributes-only，这也是我没打印任何密钥值的技术原因。

---

## 7. 复现命令

```bash
cd v4/spike

# P0 互通（Rust 编译 + Swift 脚本，双向 4 组用例）
(cd cipher-interop && cargo build && ./run-interop.sh)

# P1 Tauri 最小应用
(cd tauri-probe && cargo build)            # 冷编译 ≈54s；产物 target/debug/tauri-probe (27.8MB)
(cd tauri-probe && ./target/debug/tauri-probe &) ; sleep 8 ; pgrep -fl tauri-probe

# P3 候选 crate
(cd probe && cargo check)                  # 59s，exit 0

# P4 keychain（只读属性，永远不取密文）
(cd keychain-probe && cargo run)
```

产物清单：`v4/spike/{cipher-interop,tauri-probe,probe,keychain-probe,shellprobe}/`，其中 `cipher-interop/interop-transcript.log` 是 §2.2 的原始 transcript。

---

## 8. 风险 / 阻塞 / 未知（给 lead 的判断依据）

**阻塞（需架构决策，不是技术不可行）**
- **B1 v4 拿不到 v1 的 Keychain 密钥**（§6）。过渡期必须让 Swift 边车持有密钥，v4 外壳只拿"端口 + Bearer token"；否则用户要重新授权/迁移。**这条会直接影响 v4 第一阶段的接口设计。**
- **B2 无 Xcode → 打包链路未验证**（`tauri build` 出 .app/.dmg、notarization、universal binary 均未测；本机无 rustup 也加不了 x86_64 target）。

**风险**
- **R1 `aes-gcm` 版本漂移**：`cargo add` 拉 0.11.1（API 变），spike 用 0.10.3。v4 必须钉版本（§2.3）。
- **R2 `async-imap` 默认 async-std**（§5），与 axum/tokio 栈不一致，容易在上手第一天浪费半天。
- **R3 `generate_context!` 的图标硬依赖**（§3.4）会让"零配置最小应用"第一次编译就失败，文档里没强调。
- **R4 边车孤儿进程 + CORS(`tauri://localhost`) 未验证**（§4.3）。
- **R5 `tauri-plugin-shell` 的 capabilities 白名单**若开了，等于给前端一个"执行外部二进制"的入口，安全模型上应尽量避免（§4.2A）。

**未知（明确没做/没测）**
- 窗口是否真的渲染出来（只证明进程不崩，没截图证据）。
- `tauri build` 完整打包、签名、公证。
- `lagoon.*` keychain 条目"到底在不在"（§6.3 的 (a)/(b) 无法区分）。
- Tauri WebView 的 `WKWebView` 对 v1 服务端 SSE/长连接的兼容性（未测）。
- v1 服务端对 `Origin: tauri://localhost` 的处理（未测，建议第一优先验证）。

**合规披露（唯一一次 v4 之外的写入，已清理）**：做 P4 对照实验时 `security create-keychain` 把临时 keychain 文件建在了 `~/Library/Keychains/`（它不接受相对路径为工作目录内路径）。这些 keychain 只含 `lagoon.probe / control-value` 这种假值，且**已用 `security delete-keychain` 删除并 `rm` 复核**（`ls | grep -c ctl2` → 0）。没有读写、修改任何 v1 源码或 `Sources/`、`Tests/` 文件；没有运行 `swift build`/`swift test`；没有 `cargo install`。
