# 客户端表面盘点（Web 移植范围）

> 读者：M1/M2 的前端与外壳实现者。本文回答「v3 的 SwiftUI 客户端到底有什么、Web 要照抄什么、什么照抄不了」。
> 方法：只读 `Sources/Lagoon`（110 文件 / 31.7k 行），不编译、不运行。证据格式 `file:line`，相对仓库根。
> 约定：**未知** = 仓内无记录且本轮无法实测，不要用记忆补；**未采用** = token/API 存在但视图层没接线。

## 0. 五条结论（先看这个）

| # | 结论 | 证据 |
|---|---|---|
| 1 | 屏幕数远小于端点数：**1 窗口 + 3 栏 + 2 个列表表面 + 1 阅读器 + 23 个面板**。Web 要做 24 个界面，不是 60 个端点 | `RootView.swift:520-590`（13 个 `.sheet`）、`Views/` 共 47 个 View 类型 |
| 2 | 简报页与收件箱页**不是两个页面，是同一个窗口的两个"透镜"**：v3 已把两者同时挂在 ZStack 里靠 `opacity/disabled` 切换 | `RootView.swift:323-366`、`RootView.swift:512-518` |
| 3 | 六态在 v3 是**散落的独立分支 + 1 个纯函数**，没有统一状态机；Web 照抄会得到 23 套重复实现 | `SearchSheet.swift:381-411`（唯一提炼成 enum 的） |
| 4 | 键盘 **26 行事典 / 30 个键位**，另有 5 个未入表但真绑定的键 → **必须做全局键盘层** | `ShortcutsSheet.swift:80-136` |
| 5 | 主题 token **可以**一对一映射，但视图层仍有字面量（token 未采用），CSS 变量须以**视图实际值**为准 | `MessageListView.swift:1301`（7pt 写死，未用 `unreadDotSize`） |

## 1. 界面清单

### 1.1 窗口骨架（`RootView`，1293 行）

| 层 | 内容 | 证据 |
|---|---|---|
| 启动闸门 | 6 分支：服务器启动中 / 启动失败+重试 / 账号读取中 / **钥匙串被拦** / 无账号→连接页 / 有账号→RootView | `LagoonApp.swift:20-77` |
| 全局横幅槽 | 优先级链：store 通知 → 撤销错误 → 同步健康 → AI 状态 → 列表加载错误 | `RootView.swift:818-824` |
| 离线条 | 独立细条，不占横幅槽（横幅同时只允许一条） | `RootView.swift:492`、`OfflineStrip.swift:44-67` |
| 三栏 | 导航 180–300 / 列表 280–460 / 阅读 360–900，共用一个宽度求解器 | `ColumnLayout/LagoonColumn.swift:131-135` |
| 底栏 | 撤销 toast + 时间节省条（同一 safeAreaInset） | `RootView.swift:503-508` |
| 工具栏 | 账号菜单、界面 segmented、新建、搜索、⋯（用量/AI/建议/提醒/历史/发件人排行/音效/语言/关于） | `RootView.swift:1202-1292` |
| 窗口 | 默认 1080×760；最小宽 = sum(min)+分隔 = **822**；最小高 **420** | `LagoonApp.swift:149-153`、`ColumnLayout/LagoonColumn.swift:105-123` |

### 1.2 侧边栏（7 行固定 + N 条用户规则）

单值 `SidebarDestination` 是"我在看什么"的唯一真相，界面由它派生（`RootView.swift:143-145`）。

| 分区 | 行 | 图标 | 计数来源 | 证据 |
|---|---|---|---|---|
| 智能视图 | 简报 | grid.2x2 | 无（是视图不是地方） | `Sidebar.swift:69-79` |
| 智能视图 | 收件箱 | tray.full | `FolderCountKey.live` | 同上 |
| 智能视图 | 未读 | envelope | `.unread` | 同上 |
| 智能视图 | 置顶 | pin | `.pinned` | 同上 |
| 地方 | 已归档 | archivebox | `.archived` | `Sidebar.swift:123-132` |
| 地方 | 已发送 | paperplane | `.sent`（走 `/api/sent`） | `MessageListView.swift:112-121` |
| 地方 | 废纸篓 | trash | `.deleted` | 同上 |
| 我的分组 | 每条规则 | label | `/api/stacks` | `Sidebar.swift:153-168` |

侧边栏**没有写动词**（不能从导航列归档/删除），这是宪法约束（`Sidebar.swift:100-105`）。

### 1.3 两个列表表面 + 阅读器

| 表面 | 行数 | 组成 | 证据 |
|---|---|---|---|
| 简报页 | 2432 | 5 个固定分组（emoji、可折叠、噪声组默认折叠）+ 组头计数 + 两行边界说明（另有 N 封 / 更早 N 封） | `BriefingFeedView.swift:522-709`、`LagoonKit/Briefing.swift:8-30` |
| 收件箱 | 2752 | 分组 segmented（会话/发件人/日期）+ 日期桶 section + 会话行/单行 + 悬停卡 + 已发送"可能过期"条 | `MessageListView.swift:417-675` |
| 阅读器 | 1445 | 常驻动作条（置顶｜回复·全部·转发 … 归档并下一封·⋯）+ 头部 + 纯文本正文 + 沙箱 HTML 正文 + 内联图 | `MessageDetailView.swift:335-479`、`HTMLMessageView.swift:94-122` |
| 分栏占位 | — | 未选中 / 多选 N 封 两态 | `MessageSplitLayout.swift:78-93` |

### 1.4 面板（23 个，全部走 `.sheet`）

| 面板 | 何时开 | 尺寸档 | 一句话 | 证据 |
|---|---|---|---|---|
| SearchSheet | ⌘F | wide | 输入框 + 结果列表 + 邮件内嵌预览栈，5 相状态机 | `SearchSheet.swift:381-411` |
| CommandPaletteView | ⌘K | standard | 12 条命令，子串匹配，↑↓ + ↩ | `CommandPaletteView.swift:96-142` |
| ShortcutsSheet | ⌘/ | wide | 26 行键位表 + 作用域胶囊 | `ShortcutsSheet.swift:80-181` |
| AdviceSheet | ⇧⌘A | standard | AI 建议队列（接受/忽略/设提醒） | `AdviceSheet.swift:20` |
| RemindersSheet | 菜单 | standard | 用户自设提醒列表 | `RemindersSheet.swift:23` |
| ReminderSheet | 行/建议 | compact | 设一个提醒（时间选择） | `ReminderSheet.swift:36` |
| ActionHistorySheet | 菜单 | standard | 审计日志分页（`/api/actions`） | `ActionHistorySheet.swift:25` |
| UsageSheet | ⌘B | standard | 本月用量 / 预算 | `UsageSheet.swift:5` |
| SenderRankingSheet | 菜单 | wide | 发件人排行，可"归档此发件人" | `SenderRankingSheet.swift:24` |
| SenderSheet | 行菜单 | wide | 某发件人的全部邮件 | `SenderSheet.swift:9` |
| StackListSheet | 列表工具栏 | standard | 我的分组列表 | `StackSheets.swift:28` |
| StackMailSheet | 分组行 | wide | 某分组下的邮件 | `StackSheets.swift:264` |
| StackRuleEditorSheet | 行菜单 | compact | 新建/编辑聚合规则 | `StackSheets.swift:574` |
| NewMessageSheet | ⌘N | composer | 新邮件（收件人/主题/正文/附件/草稿） | `NewMessageSheet.swift:18` |
| ComposerSheet | ⌘R / ⇧⌘R / ⇧⌘F | composer | 回复/全部回复/转发共用一个编辑器 | `ComposerSheet.swift:8` |
| ForwardSheet | — | composer | 独立转发（带原件） | `ForwardSheet.swift:29` |
| DraftPickerSheet | 阅读器 | compact | 选一个 AI 草稿变体 | `DraftPickerSheet.swift:7` |
| OverrideScopeSheet | 阅读器 | compact | 手动改分组 + 作用域（仅此封/此发件人） | `OverrideScopeSheet.swift:26` |
| AISettingsSheet | 菜单 | standard | 供应商/模型/Key/探活 | `AISettingsSheet.swift:23` |
| AboutSheet | 菜单 | compact | 关于 + 隐私 + 备份入口 | `AboutSheet.swift:17` |
| PrivacySheet | About | compact | 数据流向说明 | `PrivacySheet.swift:19` |
| BackupSheet | About | standard | 导出 / 导入备份（NSSavePanel） | `BackupSheet.swift:26` |
| SyncHealthDetailSheet | 健康横幅 | standard | 同步健康细节 + 能力表 | `SyncHealthDetailSheet.swift:8` |

### 1.5 设置（独立 `Settings` scene，⌘,）

三页 Form：通知（开关 + 授权状态文案 + 去系统设置）、账号（列表/状态点/未读数）、关于（版本、数据目录可选中复制）。证据 `SettingsView.swift:111-241`、`LagoonApp.swift:166-168`。

## 2. 简报页 vs 收件箱页：差别到底在哪（Q1）

| 维度 | 简报（BriefingFeedView） | 收件箱（MessageListView） | 证据 |
|---|---|---|---|
| 数据来源 | `GET /api/briefing`（服务端已分类，窗口有上限） | `GET /api/messages`，参数 archived/deleted/pinned/unread/stackId；已发送走 `/api/sent` | `APIClient.swift:383-405`、`:151-205`、`:477-510` |
| 行模型 | `BriefingItem`（message + group + reasonCode） | `MessageHeader`，再按 GroupingMode 归成 `Conversation` | `LagoonKit/Briefing.swift:54-70`、`MessageListView.swift:210-218` |
| 分组 | **固定 5 组**（需回复/等待中/可归档/订阅噪声/置顶），可折叠 | **3 种分组 mode** + 日期桶 section | `BriefingFeedView.swift:524-650`、`MessageListView.swift:525-560` |
| 第三行 | AI/规则给的 **reason 句**（无则用 snippet） | **snippet**（dense 档整行不要） | `BriefingFeedView.swift:2283-2291`、`MessageListView.swift:1348-1353` |
| 行首 | **28pt 头像**（首字母 + 邮箱哈希取色） | **7pt 未读圆点**（无头像） | `BriefingFeedView.swift:2258-2261`、`MessageListView.swift:1296-1306` |
| AI 建议 | 行内 `RowAdviceStrip`（展开/忽略/照做/设提醒） | **无行内**，只有 450ms 悬停卡第三行 | `BriefingFeedView.swift:2301-2320`、`MessageListView.swift:243-259` |
| 选择 | `Set<String>`；⌘A **只在已加载窗口内**切换 | `Set<String>` + **两段式**："选服务器上全部 N 封" | `BriefingFeedView.swift:960-971`、`MessageListView.swift:783-800` |
| 批量条 | 有，无第二段、无 scopeNote | 有，带 scopeNote / selectionReachesUnloaded 警示 | `BulkActionBar.swift:42-99` |
| 独有动词 | 一键退订（仅订阅噪声组） | 清空废纸篓（仅废纸篓透镜）、取消归档/恢复/彻底删除、聚合规则入口 | `BriefingFeedView.swift:619-643`、`MessageListView.swift:477-491`、`:2596-2660` |
| 工具栏 | 标题 + 全部标为已读 + 去列表 + 刷新 | 标题（随透镜变）+ 分组 segmented + 全部标为已读 + 分组列表 ± 清空废纸篓 + 刷新 | `BriefingFeedView.swift:440-490`、`MessageListView.swift:420-521` |
| 空态 | 3 分支（同步坏 / 首次同步带计数 / 收件箱已清空） | 7 分支（每透镜一套图标+标题+提示） | `BriefingFeedView.swift:737-778`、`MessageListView.swift:112-148` |
| 边界说明 | 两行真实行（另有 N 封 / 更早 N 封） | 一行 truncated（末尾真实行） | `BriefingFeedView.swift:657-684`、`MessageListView.swift:565-572` |

**能不能合成一个页面两种模式？——能，v3 架构已在往那儿走；但有 4 条不能合并。**

可以合并的依据：`surface` 完全由 `destination.showsBriefing` 派生（`RootView.swift:143-145`）；两个表面**同时挂载**在 ZStack 里靠 `opacity/disabled/allowsHitTesting/accessibilityHidden` 切（`:323-366`）；两者共享同一密度偏好、同一宽度求解器、同一套 ⌘A/⌫/⌘⌫/j-k/⌘[。
必须保留的分支 4 处：**数据源**（briefing / messages / sent 三套 shape）、**分组模型**（固定 5 组 vs 3 mode + 日期桶）、**行模型**（reason 行 + 建议条 + 头像 vs snippet + 圆点）、**两段式全选**（仅列表有）。
建议形态：`/mail?surface=briefing|list&lens=inbox|unread|pinned|archived|sent|trash|rule:<id>` 一个路由；`surface` 决定数据加载器，`lens` 决定过滤器；行组件按 `surface` 分派为两个子组件——**不要**参数化成一个超级行组件（v3 六套"邮件行"的教训就是那么来的，`LagoonTypography.swift:8-20`）。

## 3. 状态模型与六态（Q2）

### 3.1 客户端状态对象（Web 侧对应物）

| 对象 | 职责 | 轮询 | 证据 |
|---|---|---|---|
| `AccountStore` | 当前账号 id，镜像到 Keychain | 无 | `AccountStore.swift:1-30` |
| `DirectoryStore` | 账号列表 + 同步健康 + AI 状态 + 加载错误（**一个 poll 四用途**） | 30s | `DirectoryStore.swift:8-21` |
| `PollClock` | SuspendingClock（睡眠只算清醒时间）+ `shouldPoll(isVisible:scenePhase:)` | — | `PollClock.swift:19-36` |
| `RefreshGate` | 世代号 + 在跑 + 挂起；只允许最新一代提交 | — | `RefreshGate.swift:12-45` |
| `ErrorCenter` | 视图层外的全局横幅（同时仅一条） | — | `ErrorCenter.swift:11-26` |
| `StoreNoticeCenter` | 存储层一次性通知，显示后 ack | 30s | `StoreNoticeCenter.swift:1-25` |
| `NetworkMonitor` | 在线 / 计费网络 / 是否已上报 | 系统回调 | `NetworkMonitor.swift:44-58` |
| `UndoController` | 最近一次可撤销动作 + toast 倒计时 | — | `UndoController.swift:65-103` |

### 3.2 六态：规范 vs 代码（两边措辞不同，别混）

规范定义（`docs/V1.0-产品定义与验收标准.md:68-85`）是 **加载中 / 空 / 错误 / 离线 / 未连接 / 部分成功** + 三个"不知道"。任务书里的"有数据/同步出错/密钥未就绪"是**实现中存在但规范没点名**的三条。全部映射：

| 状态 | v3 怎么表达 | 文案位置 | 证据 |
|---|---|---|---|
| 加载中 | 全屏 ProgressView + 文案（仅当列表为空）；否则只在工具栏转 16pt 小圈 | `L10n.swift:191`（正在加载简报…）、`:1435`（正在加载邮件…） | `BriefingFeedView.swift:514`、`MessageListView.swift:612-619`、`:493-495` |
| 空 | 简报 3 分支 / 列表 7 分支（每透镜一套 icon+title+hint） | `:1710` 收件箱已清空、`:1718`、`:238` noMessagesYet、`MessageListView.swift:112-148` | `BriefingFeedView.swift:737-778`、`MessageListView.swift:620-645` |
| 错误 | 局部横幅（标题说"发生了什么"+ 详情 + 重试），与全局横幅互斥以避免重复 | `:342/343` 列表加载失败、`:218` 简报不可用 | `MessageListView.swift:693`、`BriefingFeedView.swift:782-794` |
| 离线 | **独立细条**不是横幅（状态≠失败，且横幅槽只能一条） | `:333` | `OfflineStrip.swift:1-42` |
| 未连接 | 无账号→连接屏；**有账号但钥匙串读不到→授权屏**（不是连接屏） | `:231` 未连接、`L10n+Keychain.swift:44` | `LagoonApp.swift:54-72`、`KeychainAuthorizationView.swift:50-61` |
| 部分成功 | 真实剩余数：简报两行 / 列表 truncated 行 / 已发送"可能过期"条 / 批量 scopeNote | `:1257` sentStale | `BriefingFeedView.swift:657-684`、`MessageListView.swift:565-572`、`:661-672`、`BulkActionBar.swift:85-99` |
| 同步出错（额外） | 横幅按 SyncHealth.Status 四分支（需重连/降级/错误/账号缺失），每条都有可执行按钮 | `L10n.swift:655/658/659`、`L10n+Account.swift:17` | `RootView.swift:920-978`、`BriefingFeedView.swift:739-751` |
| 密钥未就绪（额外） | 启动屏 4 态 + 秘密解析超时降级为"需要授权" | `:1924/1925`、`L10n+Keychain.swift:56` | `EmbeddedServer.swift:546-556`、`SecretResolver.swift:6-24` |
| 三个“不知道” | ①能力位未探测→按钮禁用 + tooltip 说原因（不隐藏）②Keychain 读取区分 missing/failed ③计数 0 不显示徽章 | — | `MessageDetailView.swift:458-463`、`KeychainAccess.swift:1-30`、`Sidebar.swift:188-211` |

**结论（给 Web）**：v3 只有搜索面板把六态提炼成 `ResultsPhase` 纯函数（`SearchSheet.swift:381-411`，注释明确警告"失败不得落到空"），其余 22 个界面各写各的。Web 应建统一 `AsyncSurface<T>`（idle/loading/empty/error/partial/unauthorized）——这是 v4 验收标准 §10.3"六态不撒谎"唯一可执行的落地方式。

## 4. 交互清单（Q3）

### 4.1 完整键位表（26 行事典 → 30 个键位）

| 键 | 动作 | 作用域 | 绑定位置 | 证据 |
|---|---|---|---|---|
| ⌘[ | 取消选择（回占位） | 两个列表 | 隐藏按钮 | `BriefingFeedView.swift:947-951`、`MessageListView.swift:847-853` |
| ⌘0 | 切换主界面（简报⇄列表） | 全局 | **菜单栏** | `LagoonAppCommands.swift:90-95` |
| ⌘1–⌘5 | 跳到第 N 个简报组 | 简报 | 隐藏按钮 ×5（生成自 allCases） | `BriefingFeedView.swift:910-930` |
| ⌘F | 搜索 | 全局 | 菜单栏 | `LagoonAppCommands.swift:104-107` |
| ⌘K | 命令面板 | 全局 | 菜单栏 | `:148-151` |
| ⌘/ | 快捷键表 | 全局 | 帮助菜单 | `:154-158` |
| ⌘B | 本月用量 | 全局 | 菜单栏 | `:139-142` |
| ⇧⌘A | AI 建议队列 | 全局 | 菜单栏 | `:116-123` |
| ⇧⌘N | 获取新邮件（**IMAP 往返**） | 全局 | 菜单栏 | `:80-83` |
| ⌥⌘R | 刷新（**本地重读**） | 全局 | 菜单栏 | `:109-112` |
| ⌘N | 新邮件 | 全局 | 菜单栏 | `:75-78` |
| ⌘Z | 撤销上一次 | 全局 | 零宽隐藏按钮 | `RootView.swift:776-781` |
| J / K | 下一行 / 上一行 | 两个列表 | 隐藏按钮（无修饰） | `BriefingFeedView.swift:932-939`、`MessageListView.swift:827-840` |
| ⇧⌘K | 全部标为已读 | 两个列表 | 工具栏按钮 | `BriefingFeedView.swift:461`、`MessageListView.swift:458` |
| ⌘A | 全选（已是全选则清空） | 两个列表 | 零宽按钮 | `BriefingFeedView.swift:960-971`、`MessageListView.swift:792-805` |
| ⌫ | 归档选中 | 两个列表 | `onDeleteCommand`（**不是 keyboardShortcut**，grep 不到） | `BriefingFeedView.swift:705`、`MessageListView.swift:584-586` |
| ⌘⌫ | 移动选中到废纸篓 | 两个列表 | 零宽按钮 | `BriefingFeedView.swift:973-980`、`MessageListView.swift:812-819` |
| ⌘R | 回复 | 阅读器 | 动作条按钮 | `MessageDetailView.swift:388` |
| ⇧⌘R | 全部回复 | 阅读器 | 同上 | `:394` |
| ⇧⌘F | 转发 | 阅读器 | 同上 | `:402` |
| ⇧⌘P | 置顶/取消置顶 | 阅读器 | 同上（**不用 ⌘P：⌘P 是打印**） | `:374-378` |
| ⌘D | 摘要 | 阅读器 | ⋯ 菜单 | `:437` |
| ⇧⌘D | 生成草稿变体 | 阅读器 | ⋯ 菜单 | `:447` |
| ⌘E | 归档并下一封 | 阅读器 | 主按钮 | `:414` |
| ⌘↩ | 发送 | 编辑器 | 发送按钮 | `ComposerSheet.swift:339`、`NewMessageSheet.swift:223` |
| ⌘, | 设置 | 全局 | `Settings` scene | `LagoonApp.swift:166-168` |

**未入表但真绑定的 5 个**：↑/↓（`onMoveCommand`，`BriefingFeedView.swift:706` / `MessageListView.swift:591`）、↩（各面板 `.defaultAction`，如 `ShortcutsSheet.swift:144`）、Esc（关横幅 `NoticeBanner.swift:166`、取消面板 `.cancelAction`）、搜索面板内 ⌘[（`SearchSheet.swift:311`）。
**合计 35 个可触发键位 → Web 必须做全局键盘层**。浏览器/外壳会抢走 ⌘N/⌘T/⌘W/⌘Q，需在 Tauri 侧拦截；⌘A/⌘Z/⌘F 需在输入框内让位。

### 4.2 非键盘交互

| 交互 | 实现 | 移植提示 | 证据 |
|---|---|---|---|
| 右键菜单 | `.contextMenu` ×4（简报行 8 项、列表行 11 项、提醒、分组） | Web 自绘菜单（原生菜单无样式） | `BriefingFeedView.swift:590-644`、`MessageListView.swift:2641-2660` |
| 滑动手势 | `swipeActions`：简报左滑归档 / 右滑置顶；列表同构 | 鼠标端几乎不可达，**建议不做**，右键 + 快捷键覆盖 | `BriefingFeedView.swift:557-573`、`MessageListView.swift:2608-2626` |
| 悬停卡 | 450ms 停留后浮层，**不可点**（allowsHitTesting false） | 易做；触屏无 hover 需分支 | `MessageListView.swift:243-259`、`ListDensity.swift:113-159` |
| 多选 | `List(selection:)` + ⌘A/⌘⌫；两段式全选仅列表有 | 自绘选中态 | `BriefingFeedView.swift:2359-2387` |
| 撤销 | toast 4s（悬停暂停）+ ⌘Z 走 undo-latest，批量走 undo-bulk；终态动作不显示 Undo | 倒计时/悬停暂停需自实现 | `UndoController.swift:65-103`、`:270-399` |
| 折叠分组 | 分组头按钮，噪声组默认折叠 | 纯状态 | `BriefingFeedView.swift:711-733`、`LagoonKit/Briefing.swift:29` |
| 列宽拖拽 | 自研求解：橡皮筋 over/(1+over/150)、上限 40、回弹 150ms、键盘步进 16/64 | 需重写（勿用 CSS resize） | `ColumnLayout/LagoonColumn.swift:57-93` |
| 拖放 | **全仓 0 处**（无 onDrag/onDrop） | 无移植负担；附件靠 fileImporter | `NewMessageSheet.swift:249`、`ComposerSheet.swift:360` |

## 5. 主题 token → CSS variables（Q4）

### 5.1 颜色（可一对一的只有这些）

| Swift token | 值 | 建议 CSS 变量 | 备注 |
|---|---|---|---|
| `LagoonTheme.brand` | #1F6F84（0.12/0.43/0.52） | `--lagoon-accent` | 全局 .tint，`LagoonApp.swift:101` |
| severity.success | 系统 .green | `--sev-success` | 系统色 sRGB **未知**，须实机采样（暗色有变体） |
| severity.info | 系统 .blue | `--sev-info` | 同上 |
| severity.warning | 系统 .orange | `--sev-warning` | 同上 |
| severity.error / danger | 系统 .red | `--sev-error` / `--danger` | 同上 |
| unreadMarker 亮 | 0.05/0.23/0.29 → #0D3B4A | `--unread-dot` | 随外观切换 |
| unreadMarker 暗 | 0.45/0.80/0.87 → #73CCDE | `--unread-dot`（暗） | `LagoonTheme.swift:110-114` |
| 头像 8 色 | 见 `SenderAvatar.swift:26-35` | `--avatar-0..7` | 索引 = Σ(utf8 字节) % 8（`:41-45`） |

### 5.2 尺寸 / 间距 / 圆角（可直接一对一）

| 类别 | token | 值 | CSS 变量 |
|---|---|---|---|
| 间距 | spaceXS/SM/MD/LG/XL/XXL | 4/8/12/16/24/32 | `--sp-xs` … `--sp-xxl` |
| 圆角 | radiusSmall/Medium/Large | 4/6/8（**Large 未采用**） | `--r-s` / `--r-m` / `--r-l` |
| 状态点 | statusDotSize | 8 | `--dot-status` |
| 未读点 | unreadDotSize | 7（视图实际写死 6/7/8 三种） | `--dot-unread` |
| 头像 | avatarSize | 28（未采用，视图取默认 28） | `--avatar` |
| 图标列 | iconColumnWidth | 20 | `--icon-col` |
| 阅读列 | readingColumnWidth | 900（类型内又抄一份，`MessageDetailView.swift:173`） | `--reading-max` |
| 行高 | dense / compact | 30 / 52 / nil | `--row-min` |
| 面板 | compact / standard / wide / composer | 360×360 / 520×480 / 640×560 / 600×520 | `--sheet-*` |
| 三栏 | nav / list / reader（min·soft·ideal·max·weight） | 180/150/210/300/1.0、280/240/340/460/2.0、360/300/520/900/3.0 | `--col-*` + JS 求解 |
| 分隔条 | dividerThickness / dividerHitWidth | 1 / 10 | `--divider-w` / 命中区 10px |

### 5.3 字体（**不能**一对一，最大缺口）

`LagoonTypography` 只给语义字号，不带 pt（`LagoonTypography.swift:27-59`）：

| 语义 | SwiftUI 字号 | 用途 | Web 建议 |
|---|---|---|---|
| rowSubject | .body | 行主标题 | `--fs-subject`（px **未知**，须实机采样 NSFont.preferredFont） |
| rowSubjectDense | .callout | 密集档主标题 | `--fs-subject-dense` |
| rowSender | .caption | 发件人 | `--fs-sender` |
| rowSnippet / rowTime | .caption2 | 摘要 / 时间 | `--fs-snippet` |
| rowSpacing | 4 | 行内竖向间距 | 复用 `--sp-xs` |
| 行数上限 | subject 1 行 / snippet 2 行 | — | `--lines-subject: 1`、`--lines-snippet: 2` |
| 时间格式 | 今天→时:分；7 天内→周几 时:分；更早→月日 | 单一函数 | 移植为 formatRowTimestamp()，别用 Intl 默认（`LagoonTypography.swift:78-88`） |

### 5.4 必须新造（v3 用系统语义色/材质，无对应值）

| 新 token | 替代的 v3 概念 | 依据 |
|---|---|---|
| `--bg-window / --bg-nav / --bg-bar / --bg-row-hover / --bg-row-selected` | .regularMaterial（导航栏）、.bar（批量条/顶部条）、.inset 列表 | `MessageSplitLayout.swift:149`、`BulkActionBar.swift:142`、`MessageListView.swift:669` |
| `--fg-primary / --fg-secondary / --fg-tertiary` | .secondary / .tertiary（全仓 ~60 处） | 例 `BriefingFeedView.swift:2275` |
| `--bg-quaternary` | .quaternary（键帽、胶囊底） | `ShortcutsSheet.swift:156` |
| `--sev-*-bg` | severityColor.opacity(0.12)、离线条 0.12/0.4 | `NoticeBanner.swift:156-162`、`OfflineStrip.swift:33-37` |
| `--toast-bg / --toast-fg` | .tint 底 + 白字 | `UndoController.swift:44` |
| `--focus-ring` | 系统焦点环 | 无障碍底线 `docs/V1.0…:118` |
| `--ease-row / --dur-row` | .spring(response: 0.32, damping: 0.85) | `BriefingFeedView.swift:701` |
| `--ease-banner / --dur-banner` | .spring(0.3, 0.85) | `NoticeBanner.swift:196` |

> 采样纪律：**不要用记忆值**（如 #007AFF）。v3 用的是 macOS 系统色，随外观/对比度/强调色变化；必须在实机取 NSColor.systemBlue 等的 sRGB 再写进 token 文件。

## 6. Mac 平台集成（Rust 外壳必须重新提供的 13 项）

| 能力 | v3 实现 | 证据 | v4 替代 |
|---|---|---|---|
| 系统通知 | UNUserNotificationCenter；三态（偏好/授权/是否有 bundle）；新邮件带发件人+主题 | `MailNotificationService.swift:30-134` | tauri-plugin-notification；**授权三态要自己建模** |
| 提醒调度 | 系统会忘记 → 每次启动先清空再按本库重建 | `ReminderScheduler.swift:1-40` | Rust 启动时读库重建（同规则） |
| Dock 角标 | NSApp.dockTile.badgeLabel；0→nil，>999→"999+" | `DockBadgeController.swift:36-56` | Tauri 无跨平台 API；macOS 用 objc2 调 NSApp（Win/Linux **未知**） |
| 音效 | 系统音 Pop/Tink/Glass，30% 音量，可关 | `SoundEffects.swift:39-43` | Web Audio 播自带 wav（系统音再分发/可得性**未知**） |
| `lagoon://` | 3 条：message/<remoteId>、search?q=、unread | `LagoonURLHandler.swift:14-83` | deep-link 插件 + 前端 router |
| 菜单栏 | 6 组、11 个带快捷键、About/Settings 走系统槽 | `LagoonAppCommands.swift:52-160` | Tauri menu API（仅 macOS 有真菜单栏） |
| 快捷键注册 | 全局=菜单栏；局部=零宽隐藏按钮；列表=onDeleteCommand/onMoveCommand | `RootView.swift:766-782` | 单一 keydown 层 + 作用域栈（见 §4.1） |
| Keychain | 6 层：Access（结果三态）/Reader（带超时）/Trust（签名锚定）/Migration/Store/SecretResolver | `KeychainAccess.swift:1-30`、`KeychainReader.swift:1-25`、`KeychainTrust.swift:1-30` | keyring / security-framework；**必须固定签名身份**，否则读挂起事故复现 |
| 内嵌服务端 | 进程内 Hummingbird，端口候选 + UserDefaults "lagoon.serverPort"，启动 4 态 | `EmbeddedServer.swift:43-218`、`:546-556` | 边车进程 + stdout 握手（方案 §5 已定） |
| 网络监听 | NWPathMonitor：在线 + 是否计费 + 是否已上报 | `NetworkMonitor.swift:44-67` | navigator.onLine **不足以**判断（无 isExpensive、会假在线）；由 Rust 侧上报 |
| 外部打开链接 | NSWorkspace.open（仅主框架 + 用户点击） | `HTMLMessageView.swift:396-439`、`NoticeBanner.swift:128` | opener 插件；**保留"仅用户点击才外开"规则** |
| 保存/打开面板 | NSSavePanel ×4、fileImporter ×2 | `MessageDetailView.swift:774/813`、`BackupSheet.swift:204/336`、`ComposerSheet.swift:360` | dialog 插件 |
| 工具提示/警告 | .help() 54 处、.alert 6 处、.popover 1 处 | grep 计数、`TimeSavedBar.swift:75` | title 属性 / 自有 modal（alert() 不可样式化） |

**当前没有、因此不用移植的**：拖放（0）、打印（0）、快速查看/QuickLook（0）、原生 NSMenu（0）、剪贴板读写（0）、多窗口（单 WindowGroup）。

## 7. Web 移植评估（Q5）

| 界面 | 难度 | 主要风险 | 建议 |
|---|---|---|---|
| 连接 / 引导屏 | easy | 无 | 表单 + 4 态 |
| 三栏骨架 | **hard** | 自研宽度求解器（橡皮筋/回弹/键盘步进/持久化）+ 最小宽 822 | 先做 flex + 一个拖拽 hook，不追动画保真 |
| 侧边栏 | easy | 计数 0 不显示徽章 | — |
| 简报页 | medium | 5 组折叠 + 两行边界说明 + 行内建议条（4 按钮同行） | 固定行高 + 虚拟列表 |
| 收件箱页 | **hard** | 3 分组 mode + 日期桶 + 会话归并 + 两段式全选 + 悬停卡 | 会话归并（主题正则）逻辑必须**只在一处**，别前后端都做 |
| 阅读器 | medium | 动作条 8 动词 + 能力位禁用 + 权限文案 | 动词表驱动 |
| **HTML 邮件** | **hard** | v3 = WKWebView + 禁 JS + WKContentRuleList 屏蔽全部网络 + cid→data URL + 高度测量单滚动条（`HTMLMessageView.swift:94-122`、`:480-488`、`:116-121`） | `<iframe sandbox srcdoc>` + CSP `default-src 'none'; img-src data: blob:`；**不要**用 innerHTML（会污染主文档样式/脚本面）；cid 图转 blob URL |
| 搜索 | medium | 5 相状态机 + 内部预览栈 | 直接照抄 resultsPhase 纯函数 |
| 命令面板 / 快捷键表 / 设置 | easy | 12 条命令 + ↑↓；26 行键位；授权文案依赖系统状态 | 同一份 JSON 驱动菜单与键盘层，避免二次漂移 |
| 编辑器（新/回/转） | medium | 收件人解析 + 附件 + 发送错误 12 种码 | 错误码表照 `ComposeFlow.swift:90-149` |
| 建议/提醒/历史/用量/排行/分组 + 撤销 toast | easy–medium | 列表 + 少量写操作；toast 需「悬停暂停倒计时」 | — |
| 通知/角标/深链 | **hard** | 平台 API + 签名身份 | 外壳承担，别在 Web 层假装能做 |

**跨屏风险（按概率）**：①HTML 邮件渲染保真与隐私（最高，`HTMLMessageView.swift` 719 行几乎全为此存在）；②全局键盘层与浏览器默认键冲突；③长列表（500 行）虚拟化与"选中行滚动入视"（v3 用 scrollTo(anchor:.center) 补 ScrollViewReader 的缺陷，`BriefingFeedView.swift:903-906`）；④系统色采样失真导致暗色不可读（v3 已因此改过一次未读点，`LagoonTheme.swift:89-114`）；⑤无障碍：v3 有 54 个 tooltip、按钮几乎都有 accessibilityLabel，Web 需同步补 title/aria-label。

## 8. 风险与未知（不做第二遍采样就别下结论）

1. **字体 px 未知**：`LagoonTypography` 只有语义字号，仓内无任何 pt 记录；`--fs-*` 表须实机采样后冻结。
2. **系统色 sRGB 未知**：severity 四色 + .secondary/.tertiary/.quaternary + .regularMaterial/.bar 全部依赖 macOS 外观解析。
3. **token 采用率不完整**：radiusLarge、avatarSize、unreadStripeWidth、readingColumnWidth 在视图层**未采用**（后两者 0 次引用）；未读点实际写死 6/7/8 三种 → CSS 变量以视图实际值为准。
4. **文档与代码漂移 1 处**：`MessageSplitLayout.swift:42-44` 注释说"简报单选、列表多选"，但代码两者都多选（`BriefingFeedView.swift:1028`、`MessageListView.swift:925`）。以代码为准。
5. **疑似缺陷（照抄会带过去）**：`MessageListView.messageRow` 在 dense 档同时渲染外层 7pt 点与内层 6pt 点（`:1298-1306` 与 `:1313-1318`）→ 未读行出现两个点；且未读点未用 UnreadMarker / unreadDotSize。v4 只画一个。
6. **未验证**：Tauri 在 Windows/Linux 的托盘/Dock/菜单等价能力、iframe 沙箱下 cid 内联图与 position:fixed 邮件行为、5MB 内联图邮件在 WebView 的渲染上限——三项须 M1 实测（归 `recon/rust-spike.md` 或新增 spike）。
