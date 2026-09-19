# M1 收官：时间节省量化 + 回复检测 + 白名单自动驾驶

**Date:** 2026-09-19
**Status:** Approved（Jasper 选定 M1 收官冲刺）
**Audience:** Solo founder + AI co-founder
**前置:** M1.6 已完成（附件/HTML/内联图 + 交互打磨波）

---

## 0. 为什么是这三件事

设计 spec（2026-09-09）的 P0 清单里还剩三件没落地，而它们共同构成产品论点的
验证仪器：

1. **时间节省量化**（产品原则 #3）——没有度量就没有"这个产品有没有改善我每天
   处理邮件的体验"的答案。spec 的失败标准："如果这个 milestone 没有改善创始人
   每天处理邮件的体验，无论功能多完整都算失败。"
2. **回复检测**——"需回复"堆混入已回复邮件是核心循环的信任破口，用户一旦
   不信任这个堆，Briefing 就退化成一个普通邮件列表。
3. **白名单自动驾驶**——产品从"助手"变"操作员"的第一步：订阅噪音类发件人
   自动归档，全程可撤销（产品原则 #2）。

---

## 1. Slice 1 — Time-saved 状态栏

### 数据源
不做新表。`ai_actions`（审计日志）已经记录了 archive / read / pin / unsubscribe /
send / classify_override / undo，`payload->>'undoOf'` 指向被撤销的动作。

### 端点
`GET /api/time-saved?accountId=…` → `TimeSavedReport`：

```swift
struct TimeSavedWindow { minutesSaved: Double, messagesHandled: Int,
                         draftsSent: Int, unsubscribed: Int }
struct TimeSavedReport { today: TimeSavedWindow, week: TimeSavedWindow }
```

- 一次查询取回近 7 天的 `(kind, created_at)`（排除被 undo 的动作行），在 Swift
  侧按"今天 0 点"（服务器本地时区，单人本地部署即用户时区）与"本周"聚合。
- **分钟数是声明式估算，不是测量**。估算常量集中放在一处（`TimeSavedEstimates`）
  并写明依据，允许后续调参：
  - archive 0.5 min（人工分诊一封的常见估算）
  - unsubscribe 2 min（找退订链接 + 确认）
  - send 2 min（三草稿流程对比从零写回复）
  - read / pin / classify_override 计入 handled? 否——只有
    archive / unsubscribe / send 算"处理了一封"（读和置顶本身不是分诊终点）。
- 分钟数保留一位小数。UI 必须标注"估算"（诚实原则，同预算面板的做法）。

### 客户端
- `RootView` 底部 safeAreaInset 增加一条纤细状态栏（UndoToast 之下）：
  "今天 ≈ 节省 23 分钟 · 处理 12 封"，点击打开**本周明细 popover**（每天一行）。
- 每 60s 轮询 + 账号切换即刷；无数据（0 动作）时整条隐藏（原则 #4：空则藏）。
- L10n 双语。

---

## 2. Slice 2 — 回复检测（"需回复"不再混入已回复）

### 信号源（v1 只做 A）
- **A. Lagoon 自己发出的回复**：`ai_actions` kind='send' 且
  `payload ? 'remoteId'`（回复路由记录的是被回复的原邮件）。查询去重后作为
  `repliedRemoteIds` 信号。**跨客户端回复（Mail.app 等）检测不到**——Sent 文件夹
  不入库，这是已知边界，写进 README 的 Known limitations；未来若做 Sent 同步
  可升级为信号 B（References/In-Reply-To 线程匹配，列已在 008 建好）。

### 分类器
- `BriefingReason` 增加 `replied`。
- `HeuristicBriefingClassifier.Signals` 增加 `repliedRemoteIds: Set<String>`。
- 优先级插入（在 fromSelf 之后、readAndOld 之前）：
  pinned → 订阅噪音 → fromSelf → **replied → `.safeToArchive`，reason `.replied`**
  → readAndOld → needsReply。
- 语义：已回复 = 已处理完，归入"可归档"（一键清掉），文案"你已回复"。
- AI 分类器答案仍然覆盖启发式（现状不变）；用户覆写与置顶仍然最优先。

---

## 3. Slice 3 — 订阅噪音白名单自动归档（可撤销）

### 规则
- 新表 `auto_archive_rules`（迁移 011）：`(account_id, sender_address)` 唯一，
  精确地址匹配（与 ai_overrides 的按发件人语义一致）。
- 挂点：`SyncEngine.apply` 落库 upserts 之后——新邮件 from_address 命中规则 →
  provider.archive（remote-first）→ 本地 `is_archived` 翻转 → 记
  `ai_actions` kind='archive'，payload 带 `"autoRule": "true"`。
  - remote 失败：不落地、不记录（与现有"remote-first"纪律一致），下轮再试。
- 撤销：复用现有 undo（30 天窗口）。Undo 后不删规则——用户要停用去规则列表删。

### 客户端
- Briefing 行菜单（订阅噪音组行）加"自动归档此发件人"；规则管理入口在 ⋮ 菜单
  （列表 + 删除）。命中自动归档的行在 ActionHistory 里可见（payload.autoRule）。

### 门槛
- 只对会被启发式/AI 判为 subscriptionNoise 的发件人开放（防止把"需要回复"的
  发件人误设成自动归档——那等于自动拉黑）。

---

## 4. 非目标（本冲刺不做）

Sent 文件夹同步、iOS、API 鉴权、连接池、语义搜索、多账号并行——等 14 天浸泡
数据说话。浸泡期间只修 bug 不加功能（原 spec 规矩）。

## 5. 验收

- `bash scripts/run-all-tests.sh` 全绿（含新增测试：估算聚合、undo 排除、
  replied 优先级、time-saved 路由、白名单归档路径）。
- 客户端状态栏在真实账号上出现且数字随动作变化；已回复邮件 30s 内离开"需回复"。
- README 版本号 M1.6 → M1.7，Known limitations 增补两条边界。
