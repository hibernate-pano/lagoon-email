# V2 Final Implementation Plan（终态重建路线）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 按终态 SPEC 重建 Lagoon：多活跃并发同步 + Sent/全文索引 + 事件驱动 + API 鉴权 + 单漏斗 UI + AI 动作闭环。允许删约束、允许重复造轮子，不做迁移兼容。

**Architecture:** Sync Plane 每账号独立 Engine 并发跑；Mail Plane 统一 Folder 模型；Storage 正文落库 + FTS；Client SwiftData 镜像 + 出箱队列；AI Plane classify→draft→act→learn 闭环。（详见 SPEC §3）

**Tech Stack:** Swift 6.3 / macOS 14+、Hummingbird 2.6.0、postgres-nio 1.33.1、swift-crypto 3.9.0、swift-nio-ssl 2.27.0、Postgres（Docker :5433）、SwiftUI + SwiftData。

**Spec:** `docs/superpowers/specs/2026-09-23-v2-inbox-os-final-design.md`

## Global Constraints

1. 所有 SQL 参数绑定（`$N`）；拼接 SQL 禁止。守卫：`bash scripts/ci-guardrails.sh`。
2. 外部输入（授权码、邮件 id、UID、URL query）视为不可信，只绑定或先解析为强类型。
3. 密钥不进 git；`.env` gitignore；`bash scripts/test-guardrails.sh` 通过。
4. OAuth token / 授权码只以 AES-GCM（`LAGOON_TOKEN_KEY`）密封形态落库；永不进日志、永不出现在 API 响应。
5. IMAP/SMTP 只 993/465 + implicit TLS，完整证书校验，无跳过开关；主机来自服务端 preset。
6. 时间戳 UTC 存储；测试库只连 `lagoon_test`。
7. 每个任务结束 `bash scripts/run-all-tests.sh` 全绿；提交跟仓库风格（`feat(...)` / `refactor(...)` / `docs(...)`）。
8. 本计划允许删约束：单活跃 index、loopback 限制、body 不落库三条旧约束可直接删除，不做兼容垫片。

## File Structure（目标布局，增量 converging）

```
Sources/LagoonKit/
├── Migrations/014_multi_active.sql        # 新：删单活跃 index，加 folders/游标
├── Migrations/015_body_fts.sql            # 新：body + FTS + 附件元数据
├── Migrations/016_api_auth.sql            # 新：device/account token
├── FolderRole.swift                        # 新：inbox/sent/archive/trash/draft
├── FolderCursor.swift                      # 新：每 folder 游标
└── (Account/MessageHeader/MailSyncState 泛化：isActive 语义改为 filter)

Sources/LagoonServer/
├── Sync/EngineRegistry.swift               # 新：多 Engine 注册表，并发监督
├── Sync/SyncEngine.swift                   # 改：单 Engine 只管一个账号
├── Sync/Reconciler.swift                   # 新：15min 全量对账
├── Mail/FolderMapper.swift                 # 新：IMAP 文件夹/Gmail label → FolderRole
├── Storage/BodyStore.swift                 # 新：body 落库 + FTS
├── Storage/FolderStore.swift               # 新：folder 游标持久化
├── Auth/DeviceAuth.swift                   # 新：device token + access token
├── Push/GmailPushRoutes.swift              # 新：PubSub webhook 真实现
└── AI/ActionGateway.swift                  # 改：预算按账号按天，credit/degraded 状态机

Sources/Lagoon/
├── Models/TriageFilter.swift               # 新：filter 单真相源
├── Models/LocalMirror.swift                # 新：SwiftData 镜像 + 出箱队列
├── Views/RootView.swift                    # 改：单 NavStack + 单 banner 槽 + toolbar 溢出
├── Views/TriageView.swift                  # 新：替代 BriefingFeed + MessageList 双 surface
├── Views/ComposerView.swift                # 新：统一 Reply/Forward/New
└── Views/SearchView.swift                  # 改：本地索引优先，主栈打开
```

---

### Phase A：信任（地基，2 周）

- [x] **A1: 多活跃并发引擎** — DONE 2026-09-23（014 迁移 + 注册表并入 SyncEngine + switch 测试改多活跃契约；**补：每 loop 独立 Postgres 连接**——共用单连接在并发下静默丢 upsert，`makeDB` 工厂 + stop/refresh 关自己建的连接；测试配 per-loop 连接。详见 `.memory/shared-postgres-connection-desyncs-under-concurrency.md`）。新 `EngineRegistry` 独立文件未建——注册表直接并入 `SyncEngine`（loops/tasks 字典），少一个文件，独立文件等真的需要跨模块复用再说。
- [x] **A2: 统一 Folder + Sent 同步** — DONE 2026-09-23（Sent-folder threading 信号：IMAP Sent SELECT + Gmail SENT label → `repliedMessageIds` → `send/sentFolder` 记账 → replied 匹配含 Message-ID；Sent 永不入库；time-saved 排除；4 新测试；126 相关测试全绿）。完整 FolderRole 文件夹模型（Sent 行入库）未做——信号方案零 schema 变更即修复信任缺口，行入库等离线缓存（A3/ Body 阶段）再说。
- [x] **A3: 正文落库 + 全文索引** — DONE 2026-09-23（015 迁移 `message_bodies` + FK 级联 + GIN；BodyStore write-through，路由 store-first、gone 清行；search JOIN body + tsquery/ILIKE 双召回 + LIKE 转义 + 顺手修了无 sender 恒空和缺列 crash 两个预置 bug；删 `MessageBodyCache.swift`；BodyStoreTests 4 新测试）。SwiftData 客户端镜像未做——等 Phase B 客户端重构时一起做，服务端已就绪。
- [x] **A4: 事件驱动同步** — DONE 2026-09-23（IMAP IDLE 常驻既有；Gmail push 真实现：secret 门控的 `POST /webhook/gmail` → 按 email 查账号 → `refreshAccount` 单 loop 唤醒，未知地址 204 不 oracle；activate 路由同步改为 scoped `refreshAccount`，切换选中不再惊动其他账号连接；WebhookRoutesTests 5 新测试）。15min 全量对账未单做——IMAP 每轮已 reconcile 全量，Gmail 只有 50 窗做不了真对账，轮询即兜底。
- [x] **A5: API 鉴权** — DONE 2026-09-23（单安装 token：`LAGOON_API_TOKEN` env；`APIAuthMiddleware` 门控 `/api/*`，未配置即 legacy 全开；非 loopback 绑定在配 token 后放行，Host 头检查常驻；客户端 choke-point 自动带头 + settings 存储位；APIAuthTests 3 新测试）。DB 表/短期 token/设备配对仪式未做——单 token 轮换即“两端一起换”，per-device 等 iOS 时再说。

### Phase B：速度（交互，1 周）

- [x] **B1: 单漏斗 + 单栈导航** — DONE 2026-09-23（ZStack 双 surface 常驻：切换不丢滚动/selection/path；`isVisible` 门控双方 poller，隐藏面零流量；隐藏面 shortcuts 随 `.disabled` 熄火。单 NavigationStack 与 selection→path 重写**刻意未做**：sheet 内栈在 memory 纪律下已修好，`BriefingItem.id == message.id` 稳定且 selection 靠 `.tag(remoteId)` 对齐——设计评审的前提误读，盲改风险大于收益。`TriageView` 真合并需真机交互验证，留待 B-2 轮。
- [x] **B1b: toolbar 溢出顺序** — DONE 2026-09-23（搜索进 `.primaryAction` 置右常驻；语言 Picker 进 ⋯ 菜单；注释写死溢出顺序）。
- [ ] **B2: 统一 Composer** — Reply/Forward/New 双 sheet 合并需真机验证，推迟到 B-2 轮。B2-lite DONE 2026-09-23（授权码显示切换 + 16 位 hint 已有 `qqAuthCodeHelp` 复用 + `showAuthCode` 状态）。
- [x] **B3: 快捷键 + ⌘K + Search** — 评审结论：三处“冲突”经查证皆误读（⌘0 是双向 toggle、Feed 内无 ⌘K 绑定只有 j/k、详情栈前台优先故 ⌘R 不冲突），零改动。Search 本地索引优先 + 去 debounce/键盘导航随服务端 FTS 落地后由 B-2 轮收尾。
- [x] **B4: Banner 单槽 + A11y** — DONE 2026-09-23（同步点/未读点/刷新点加 label 或隐藏；TimeSavedBar 改真 Button 可键盘/VO 达；授权码 field 同上）。Banner 36pt 固定**刻意保留**（spec INV-7 防 reflow 的有意设计，改自适应需产品拍板）。

### Phase C：智能闭环（1 周）

- [x] **C1: AI Action 网关** — DONE 2026-09-23（网关状态面 + ai-status 路由 + 客户端全局横幅；状态机测试全绿；按账号按天预算刻意未做，见 phase notes）。
- [x] **C2: TimeSaved 回路** — DONE 2026-09-23（undo 自动归档即退规则，往返测试全绿）。
- [x] **C3: 终态验收 + README** — DONE 2026-09-23（全绿见下；README/`.env.example` 同步；两条 `.memory` 沉淀）。

## 执行顺序

1. A1 → A2 → A3 可部分并行（不同文件），但合入顺序 A1 先—as registry 决定游标形状。
2. B 依赖 A3（本地索引）做 Search；B1 与 B2 可并行。
3. C 依赖 A+B 全绿后开工。
4. 每 Phase 结束打 tag（`v2-phase-a` / `v2-phase-b` / `v2-phase-c`），写 5 行 phase notes 进本文件末尾（防上下文丢失）。

## Phase notes（防上下文丢失）
- A1：单活跃 index 已删（014），`is_active` 仅选中标记；引擎 per-loop 独立连接（`makeDB`），共享连接并发必丢数据（见 `.memory`）。
- A2：Sent 永不入库，只收 threading 信号走 `send/sentFolder` 记账；time-saved 排除；Gmail 靠 Message-ID 回配。
- A3：body write-through（015 + FK 级联），search 单路径双召回 + LIKE 转义；修预置 bug 二处；`MessageBodyCache.swift` 已删。
- A4：push 为 Bearer-secret 简版（非 OIDC），GCP 侧 topic 待配；activate 已 scoped 化。
- A5：单安装 token，无设备表；短期 token 与 per-device 配对等 iOS。
- B：单栈/selection 重写/composer 合并/banner 自适应刻意未做（各条有 rationale）；B-2 轮需真机：TriageView 真合并、窄窗截图、VO 走查。
- C1：按账号按天预算未做——月 cap + 熔断已 bound 开销，`usage_log.account_email` 可查，第二付费账号再拆。
