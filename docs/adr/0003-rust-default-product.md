# ADR 0003 · 产品默认后端 = Rust；Swift 边车退出运行路径

- 日期：2026-11-01
- 状态：**已采纳**（用户要求：产品不依赖苹果开发环境，Rust 包装）
- 前置：R3.1–R3.4 全部验收通过（mail 196 测试、api 85 测试、契约 54/54）

## 决定

1. **外壳默认后端 = rust**（`backend.rs DEFAULT_BACKEND`）；`--backend swift` 保留为开发期对照，打包产品不包含 Swift 二进制。
2. **打包形态**：`v4/scripts/build-product.sh` 产出 `v4/dist/Lagoon.app`：
   - `Contents/MacOS/Lagoon` —— Tauri 外壳（Web 资源编译期嵌入）
   - `Contents/Resources/lagoon-api` —— Rust 后端（外壳按 bundle 路径解析）
   - 构建只需 rustc/cargo + node/npm；脚本零 `swift`/`xcodebuild` 引用
   - ad-hoc 签名（Developer ID 是 M4）
3. **打包后的数据与密钥**：`~/Library/Application Support/Lagoon-v4/`（keys.json 0600 + lagoon.sqlite）；检测方式 = 可执行文件路径含 `.app/Contents/MacOS`。开发模式行为不变（`v4/.dev`）。
4. **fresh install 自动迁移**：`lagoon-api` 启动时若库不存在则创建并应用 v3 的 11 条迁移（与 v3 的“启动即迁移”一致）；已存在的库仍然只读打开 + 严格校验，外来/更新 schema 保持 fail-closed。
5. **provider 策略**：打包运行传 `LAGOON_MAIL_PROVIDER=production`（真实 IMAP/TLS）；selftest 与契约默认 `none`，永不联网。

## 被否决的选项

- **继续把 Swift 边车作为默认**：用户明确要求产品不依赖苹果开发环境；且双后端并存的验证成本已由契约测试覆盖。
- **用 Tauri bundler 打包**：`tauri build` 的 bundler 行为此前未在本机验证过，且手工装配只需要 cp + plist，工具面更小。

## 后果

- 正面：`v4/dist/Lagoon.app` 是“rust + web”的最终形态；目标机器只需要 macOS（系统 WebView）。
- 负面/待办：
  1. ~~写路径未实现（R3.5）~~ **已于 2026-11-01 完成（R3.5a）**：归档/取消归档/废纸篓/恢复/彻底删除/已读/置顶/批量/清空 + 审计 + 撤销全部落在 Rust 后端（api 91 测试）；仅 SMTP 发送（R3.5b）未做。
  2. 真实邮箱联调需要 QQ 授权码（用户操作）。
  3. Keychain 仍不可用（无稳定签名），密钥落 0600 文件——签名身份到位后迁 Keychain。

## 复验记录（2026-11-01）

- 隐藏 `.build`（Swift 产物）后启动打包应用：`fresh store: migrated applied=11` → `phase=ready backend=rust` → `accounts/store-notices/ai-status 三请求 200`，SIGTERM 后无残留进程。
- 回归：api 85/85、mail 196/196、契约 54/54（2 skipped）。
