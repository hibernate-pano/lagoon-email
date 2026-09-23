# V2 Final：AI Inbox OS 终态设计（清零版）

**Date:** 2026-09-23
**Status:** Approved（创始人确认：忽略历史债务与迁移兼容，允许重复造轮子）
**Audience:** Solo founder + AI co-founder
**前置:** M1.8 已落地（单活跃多账号、Briefing Feed、AI 网关、TimeSaved、自动归档）。本文是终态重定义，不是增量补丁。

---

## 0. 一句话定义

> **Mac-first、键盘优先的 triage 机器：所有账号汇成一个待办流，AI 把每封信变成可一键执行的动作，全部可撤销。**

成功标准：每天打开 2 次、每次 10 分钟清零。常驻挂着 = 失败。

## 1. 为什么推翻上版增量建议

上版建议（soak / Sent 补齐 / toolbar 溢出顺序 / selection 统一 / 单栈 / banner 收敛 / 迁移测试 / providers 硬校验）全对，但全是镣铐里跳舞：

1. 守住“单活跃”伪约束 —— 并发多账号才是立身之本。
2. 守住“loopback 无鉴权” —— 没有鉴权就没有多端和 iOS。
3. 守住“正文不落库 + 60s 缓存” —— 没有全文索引就没有离线、真搜和 AI 上下文。
4. 守住“双 surface + 9 个 sheet” —— Briefing vs All 不该是平行世界，而是一个漏斗的不同切片。
5. 守住“轮询 + 501 webhook” —— 终态是事件驱动（IDLE + PubSub）+ 定时对账，轮询只是兜底。
6. AI 仍是点缀 —— 终态 AI 是动作执行者（起草→发送→归档→规则沉淀闭环），TimeSaved 从展示条变成动作回路。

## 2. 产品终态

### 2.1 一个漏斗，三种切片

- 待办流是同一列表的不同 filter：NeedsReply / Awaiting / Subscription / Pinned / Done。
- ⌘1-5 是 filter 切换，不是页面跳转。All Messages = `filter=all` + 日期分组。
- 滚动 / selection / navigation path 全局一份，切换 filter 不丢状态。

### 2.2 ⌘K 第一入口

新建 / 搜索 / 跳转 / 刷新 / 规则 / 快捷键说明全进 palette。Search 选中即主栈打开、sheet 关闭，不再 sheet 内压栈。

### 2.3 一种 Composer

Reply / Forward / New 同一组件，`mode` 决定 To 是否可编辑，同一 draft key + 同一自动保存。授权码框加显示切换 + 16 位格式提示。

### 2.4 快捷键单真相源

- ⌘R 全局 = 刷新；回复 = `R`（无修饰，j/k 系）或 ⇧⌘R。
- ⌘K 全局 = palette；Feed 内下移只用 `j`。
- 删除 palette 里两项同写 ⌘0 的文案 bug。

### 2.5 Banner 单槽 + 自适应

全局只留 RootView 一个槽，子视图错误转 toast/inline。删除 36pt 固定裁剪，长错误可展开。

### 2.6 A11y 是 DoD

同步点/未读点加 label；TimeSavedBar 改 Button 语义可键盘达；附件行可 Tab 到达；群组 header 热区放大。

## 3. 架构终态

```
Client (SwiftUI, offline-first)
  └─ SwiftData 本地镜像 + 全文索引 + 出箱队列
            ↕ Auth API (token) ↕ Push (APNs/WebSocket)
Server (Hummingbird)
  ├─ Sync Plane：每账号独立 Engine，并发跑，连接池 + IDLE/PubSub 事件 + 周期对账
  ├─ Mail Plane：统一 Folder 模型 INBOX/Sent/Archive/Trash/Draft，全文件夹游标
  ├─ AI Plane：classify → draft → act → learn 闭环，每动作记账、可撤销
  └─ Storage：Postgres 为真源，body + 附件元数据全落库，Message-ID 全局稳定身份
```

### 3.1 多活跃并发同步（删单活跃约束）

- 每账号独立 `Engine` + 独立游标 + 独立 backoff；连接池按 host 复用。
- 切换账号 = 切换 filter，不是启停同步。013 的 partial unique index 在终态删除。

### 3.2 统一 Folder 抽象

IMAP 文件夹与 Gmail label 统一映射到 INBOX/Sent/Archive。**Sent 必须同步**，否则 needs-reply 永远不可信（P0）。

### 3.3 正文 + 全文索引落库

- body 全量存 Postgres + SwiftData 镜像 + FTS。`GET body` 只走缓存。
- Search 走本地索引 + 服务端 `api/search` 双通道。删除 60s 缓存中间态。

### 3.4 事件驱动同步

IMAP IDLE 常驻 + Gmail PubSub webhook 真实现 + 15min 全量对账。30s 轮询降级为无 IDLE 时的兜底。

### 3.5 API 鉴权 + 多端

Device token + 短期 access token。删除 loopback 限制，server 常驻 + iOS 可长出来。这是 M2 门票。

### 3.6 AI Action 网关

- budget 按账号 + 按天封顶；402/429/5xx 统一为 `credit/degraded` 状态机，前端只有：可执行 / 降级可读。
- 每次 AI 动作写 `ai_actions` 可审计、可撤销；TimeSaved 从展示条变成“动作→撤销→学习规则”回路。欠费时明确横幅 + 一键重试。

## 4. 非目标（终态也坚持）

附件 >25MB、S/MIME/PGP、服务端图片代理、音视频预览、多草稿 tab。这些是债务，不是特性。

## 5. 验收（终态 DoD）

1. 2 账号下，一端已读/归档/发送，另一端 30s 内一致。
2. 断网可读可搜可起草，联网自动补发。
3. 900px 窄窗无 » 吞掉新写/搜索；VO 走查通过。
4. j/k/⌫/R 全程不用鼠标清零 50 封。
5. 欠费时明确横幅 + 一键重试；每条 AI 动作可撤销且撤销后不再重复推荐。
6. `bash scripts/run-all-tests.sh` 全绿。
