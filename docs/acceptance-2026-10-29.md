# 验收记录 · 2026-10-29（M0 / M1 / R1 / R2 / M2）

> 验收人：lead（**独立复跑**，不采信被验收方的自报数字）· 环境：本机 macOS，无完整 Xcode，arm64
> 结论：**M0、M1、R1、R2 全绿；M2 本地可验部分全绿，远端成功路径待真实邮箱**。

## 1. 契约（M0）

| 项 | 命令 | 结果 |
|---|---|---|
| v3 参考实现回放 | `bash v4/scripts/contract-check.sh` | **49/49 match**，2 条 `contract_expected` 按设计 SKIP |
| fixtures 规模 | — | 51 条 = 49 抓取 + 2 contract_expected（v2 格式） |

## 2. Rust 后端（R1 + R2）

| 项 | 命令 | 结果 |
|---|---|---|
| 构建 | `cd v4/crates && cargo build --offline` | 0 warning |
| 测试 | `cargo test --offline` | **50/50 全绿**（36 单测 + 48 fixtures 回放 + 5 R2 路径 + 7 只读路径 + 1 真库冒烟） |
| 实现验证 | `contract-check.sh <rust> <token>` | **48/48 match**，3 条写路径（`r2_skip`）跳过 |
| 与 v3 同库 diff | `bash v4/crates/lagoon-api/scripts/diff-vs-v3.sh` | **46/48 SAME + 2 EXPLAINED + 0 DIFF** |

两条 EXPLAINED 是同一个 v3 缺陷：`GET /api/search` 在 v3.2.0 **恒 500**（pass-B SQL 引用 `a.category` 但只 JOIN 了 `message_bodies`），Rust 返回 **200**。这不是偏差，是修复。

只读保证（已在测试中验证）：`SQLITE_OPEN_READ_ONLY` + `PRAGMA query_only`；缺 v3.2.0 任一只迁移就拒绝启动；不碰 `credentials` 列。

## 3. 桌面外壳（M1）

| 项 | 结果 |
|---|---|
| `cargo run -- --selftest` | **12/12 PASS**（not-ready / ready / 200 / 401 / 404 透传 / bad-path / 崩溃重启 / restart_sidecar / 无孤儿 / SIGTERM 清理） |
| `cargo run`（真实 `web/dist`） | `page-load tauri://localhost` → `boot_status` starting → `ready` → 三个业务请求 **200** |
| 前端 token | 不在 DOM / localStorage / sessionStorage / cookie；`dist` 内也无 |

联调修掉的三个真实缺陷（详见 `m1-checklist.md` §1.2）：Tauri capabilities 未授权 `event.listen`、请求早于 ready 且不重试、ready 事件可丢。

## 4. Web 写路径（M2）

| 项 | 命令/操作 | 结果 |
|---|---|---|
| 构建 | `cd v4/web && npm run build` | **通过**，dist 298.07 kB / gzip 93.59 kB |
| 置顶 → toast → ⌘Z | 浏览器实操作 | `POST /pin → 200`、toast「已取消置顶 · 撤销 ⌘Z」、⌘Z → `POST /api/actions/4/undo → 200`、toast「已撤销」、计数回滚 |
| 能力闸门（API） | `POST …/archive` | **409 `archive-unavailable`** |
| 能力闸门（API） | `POST …/purge` | **409 `not-in-trash`** |
| 远端写（best-effort） | `POST …/read` | **204**（与 v3 一致：远端失败只记日志） |
| 409 回滚（UI） | 合成账号，archive-bulk | 横幅「服务端返回 409 archive-unavailable… 界面已回滚」；两行仍在；批量条保留选择 |
| 浏览器 storage | evaluate | localStorage 0 / sessionStorage 0 / cookie 空 |
| 控制台 | 6 条 | 仅 1 个 404（favicon 类）与 1 个 503（阅读器正文，预期）；无 React 错误 |

![409 回滚与能力闸门](/Users/panbo/Code/Demos/lagoon-email/v4/web/screenshots/m2-409-rollback.png)

## 4.1 验收过程中发现并修掉的三个问题（这才是验收的价值）

| # | 问题 | 证据 | 修复 | 复验 |
|---|---|---|---|---|
| 1 | **M2 改写把 boot 就绪门禁丢了**：Tauri 模式下三个顶层请求在边车 ready 之前发出，全部 status 0 且不重试 → 窗口停在错误态 | `[ipc] api GET /api/accounts -> 0` 早于 `[boot] phase=ready` | `App.tsx` 恢复 `enabled: bootReady` + `deps: [bootReady]` | 重建后：`boot_status → ready` 之后 `ai-status/accounts/store-notices → 200` |
| 2 | **`diff-vs-v3.sh` 每跑一次泄漏 3 个 v3 边车** | `PIDS` 在 `$(start_v3 …)` 的命令替换子 shell 里追加，父进程收不到 → trap 杀不到 | 端口改由全局 `STARTED_PORT` 传递，去掉命令替换 | 跑前后 `pgrep` 均 0 |
| 3 | 开发脚本（`synth-sidecar.sh`）在会话结束时留下后台边车 | `v4/web/.synth/lagoon.sqlite` 的进程仍在 | 已清理；脚本本身有 `stop` 子命令，属使用纪律 | 现存 0 个遗留进程 |

累计清掉 17 个残留 `LagoonServerCLI`（全部指向临时库或 `v4/`，未触碰用户真实数据）。**验收不是签字，是把它跑坏一遍再修好。**

## 5. 明确未验（不打包票的部分）

1. **远端成功路径**：archive/delete/restore 的真实 `MOVE`/`EXPUNGE` 与 UI 收敛；`410 message-gone`；`422 unsubscribe`；`409 send-in-flight`；`action-expired`（需等 15 分钟窗口）；UIDPLUS=true 的彻底删除。
   → 需要你的 QQ 授权码，在 v4 里连一次真实邮箱，且**只在你确认后**才对真实邮件执行写操作。
2. **R3 未开始**：Rust 侧的 IMAP/SMTP、`/body` 的 200 路径、内联图/附件、同步引擎。
3. **M4 未开始**：签名、公证、更新器、Windows/Linux 构建。
4. `/api/briefing` 未实现 v3 的「清理 30 天前 dismissed 建议」写操作（只影响历史行保留）。

## 6. 复现

```bash
bash v4/scripts/contract-check.sh                 # 契约（对 v3 参考实现）
cd v4/crates && cargo test --offline               # Rust 后端
cd v4/shell && cargo run -- --selftest             # 外壳自检
bash v4/scripts/dev.sh                             # 浏览器模式（边车 + Vite 代理）
bash v4/scripts/tauri-dev.sh                       # 桌面壳（嵌入式 dist）
```
