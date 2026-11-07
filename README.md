# Lagoon

本地优先的 macOS 邮件客户端。邮件、密钥和索引都留在本机；前端不接触 API token。

- 产品形态：Tauri 2 外壳 + React 前端 + Rust 后端，一条命令打包成 `dist/Lagoon.app`。
- 构建依赖只有 rust 与 node：不需要 Xcode，不需要 Swift。
- 当前构建面向 macOS；其他平台未验证。

## 形态

```
Lagoon.app
├─ 外壳 shell/            窗口、边车监督、IPC 代理、密钥文件（Tauri 2）
├─ 前端 web/              React 19 + TypeScript + Vite
└─ 后端 crates/
   ├─ lagoon-api          axum + rusqlite：HTTP 面、同步循环、账号与写路径
   └─ lagoon-mail         IMAP / SMTP / MIME：协议层，测试里零外联
```

前端唯一的网络出口是 `web/src/core/api.ts`：Tauri 模式走 `invoke("api")`，由外壳代发并附加 token；浏览器开发模式才直连本机后端。

## 现在能做什么

| 能力 | 状态 |
|---|---|
| 读路径 | ✅ 列表 / 计数 / 简报 / 阅读器 / 搜索 / 导出 / 草稿 / 内联图（正文里的图片真的会显示） |
| 搜索 | ✅ 走服务端（`GET /api/search`）：整个账号的未删除邮件，含已打开过的邮件正文；结果上限 100 条，解封预算 1000 封，界面如实说出没扫到的部分 |
| 附件 | ✅ 点一下就存到 `<数据目录>/downloads/` 并在访达里显示；同名不覆盖，**不自动打开**（附件是别人的文件，点一下不等于同意执行它） |
| 正文 | ✅ 缓存优先；未缓存的邮件在首次打开时抓取并落库 |
| 账号 | ✅ IMAP 连接、激活、删除；重新认证后同步循环自动恢复 |
| 同步 | ✅ 每账号一个循环；UIDVALIDITY、指数退避、单写者 |
| IDLE / 手动同步 | ✅ IDLE 已接线（单次等待 290s）；「立即同步」按钮与 `POST /api/sync` 已有 |
| 写路径 | ✅ 归档 / 取消归档 / 废纸篓 / 恢复 / 彻底删除 / 已读 / 置顶 / 批量 / 清空 / 审计 |
| 撤销 | ✅ 归档与删除执行真正的逆操作，本地与远端同时回退 |
| 安全 | ✅ API token 必需且 fail-closed；Host 守卫；外壳 CSP；端口由后端自绑 |
| AI | ✅ 只读顾问（摘要 / 起草 / 分诊建议）；在 `keys.json` 里加 `llmApiKey` 即启用，没配 key 时如实返回 `configured:false`，绝不伪造摘要；AI 永不写邮箱、永不发信 |
| 发送 | ✅ 回复 / 新建 / 转发，**有界面**（标题栏「写邮件」、阅读器「回复 / 转发」、快捷键 `c` / `r`）；`requestId` 是幂等键，同一次请求只发一封 |
| 打包 | ✅ `bash scripts/build-product.sh` → `dist/Lagoon.app` |

「远端成功路径」已用**真实邮箱**端到端验收过（2026-11-02，归档 / 删除 / 恢复 / 发信各一次，
发信界面也跑通了：真实 SMTP 交付 + `providerMessageId` 落库）。测试用的是真实库的**副本**，
真实库本身没被改过。

## 怎么跑

```bash
# 产品：构建并打开 Lagoon.app（只需 rust + node）
bash scripts/build-product.sh
open dist/Lagoon.app

# 后端测试（211 个 lagoon-api 测试 + 211 个 lagoon-mail 测试）
cargo test --manifest-path crates/Cargo.toml

# 前端：类型检查与构建
cd web && npm run typecheck && npm run build

# 外壳自检：拉起后端、握手、崩溃重启、无孤儿进程（不联网）
cargo run --manifest-path shell/Cargo.toml -- --selftest
```

浏览器开发模式（Vite dev server + 本机后端）见 `docs/ipc-contract.md` §5。

## 目录

| 路径 | 内容 |
|---|---|
| `crates/lagoon-api` | 后端：路由、store、同步、迁移 |
| `crates/lagoon-mail` | 协议层：IMAP、SMTP、MIME、字符集 |
| `shell` | Tauri 外壳与边车监督 |
| `web` | 前端 |
| `tests/contract` | 从真实后端抓取的黄金 fixture 与回放工具 |
| `scripts` | 构建、契约检查、开发辅助 |
| `docs` | 方案、契约、ADR、验收与历史归档 |

## 纪律

- **前端不持有 token**：token 只存在于外壳进程；前端通过 IPC 发请求。
- **契约先行**：改协议先改 `docs/api-contract.md`；`cargo test` 里的契约回放会逐字节比对。
- **密钥**：首次启动在 `~/Library/Application Support/` 的应用数据目录生成 `keys.json`（权限 0600），不打印、不覆盖。Keychain 存储尚未实现。
- **AI 只读**：AI 平面没有写接口，不依赖 `MailProvider`，永不发信；分诊建议只落 `advice`，执行永远是用户的点击。AI 的花费按调用记进 `usage_log`，达到 `LAGOON_BUDGET_USD_PER_MONTH` 后调用被拒（503 `ai-budget-exceeded`），不会悄悄超支。
- **测试不联网**：`lagoon-mail` 与 `lagoon-api` 的测试都用脚本化传输，真实邮箱只在显式设置 `LAGOON_MAIL_PROVIDER=production` 时才会被连接，AI 测试从不发请求。

## 文档

- 产品定义与验收标准：`docs/V1.0-产品定义与验收标准.md`
- 方案与取舍：`docs/00-理解与方案.md`
- HTTP 契约：`docs/api-contract.md` · 外壳/前端协议：`docs/ipc-contract.md`
- 决策记录：`docs/adr/0001-strangler-tauri-shell.md`、`docs/adr/0002-rust-backend-first.md`、`docs/adr/0003-rust-default-product.md`
- 里程碑与验收记录：`docs/m1-checklist.md` · `docs/acceptance-2026-10-29.md` · `docs/r3-plan.md`
- 侦察证据：`docs/recon/`

## 历史

早期的 Swift 实现保留在 git 历史里；当前产品与构建链路不含 Swift。
