# 竞品研究：Gmail / Outlook 的回收站、归档与批量操作交互

> 调研范围：Gmail 网页版（desktop web）、Outlook 网页版 / 新版 Outlook / Outlook for Mac、经典 Outlook for Windows。
> 调研目标：为 Lagoon（macOS 原生 SwiftUI，AI 分流收件箱）补齐「废纸篓管理」「归档恢复」提供可落地的交互参考。
> 说明：本文只做交互研究，不含代码。涉及 macOS 原生控件翻译的建议集中在最后一节。

---

## 0. 先纠正一个前提错误（重要）

调研任务里写的「Gmail 的 `#archive`」是**反的**。根据 Google 官方快捷键文档：

| 操作 | 官方快捷键 |
|---|---|
| **Archive（归档）** | `E` |
| **Delete（删除/移入回收站）** | `#`（即 `Shift+3`） |
| Report spam | `!`（即 `Shift+1`） |
| Snooze | `B` |
| Mute | `M` |
| Star 切换 | `S` |
| Mark as read | `Shift+I` |
| Mark as unread | `Shift+U` |
| Move to（移动到） | `V` |
| Label as（添加标签） | `L` |
| Undo（撤销） | `Z` |
| 展开/收起会话 | `;` / `:` |
| 快捷键帮助 | `?` |

来源：<https://support.google.com/mail/answer/6594>（中文版同址 `?hl=zh-Hans`，条目「归档 E / 删除 # / 忽略会话 M / 将邮件举报为垃圾邮件 !」）

**注意 `#` 的双义性**：`#` 在收件箱里是「移入回收站」；当你已经身处回收站视图时，同一个 `#` 变成「永久删除」。这是同一个物理按键在不同视图下的语义切换 —— 这个设计非常值得抄（见最后一节第 1 条）。

---

## 1. Gmail

### 1.1 Trash / 回收站

**「清空回收站」按钮在哪、文案是什么、确认几步**

- 位置：**不在侧边栏，也不在工具栏**。它是一条嵌在邮件列表顶部提示条里的**文字链接**，文案为 **`Empty Trash now`**（中文：`立即清空垃圾箱`）。
- 同一条提示条里的前半句是常驻文案：
  > `Messages that have been in Trash more than 30 days will be automatically deleted.`
  >
  > 中文官方版本：`移至垃圾箱的邮件会在 30 天后自动遭到删除。`

  来源：<https://everydaytech.org/email-communication/email-organization-management/how-do-i-delete-trash-in-gmail>、Google 官方中文帮助 <https://support.google.com/a/users/answer/9259770>

- 确认流程：**2 步**。
  1. 点击 `Empty Trash now` 文字链接
  2. 弹出确认对话框，标题为 **`Confirm deleting messages`**，正文询问是否确定要永久删除，按钮为 **`OK` / `Cancel`**

  注意这个设计：**按钮是文字链接而不是图标按钮**，且**明确与工具栏的垃圾桶图标分开**。用户不会误触。

  来源：<https://www.lifewire.com/empty-the-spam-and-trash-folders-fast-in-gmail-3572084>（「Select OK under *Confirm deleting messages*」）

- **「Empty Trash now」只在回收站非空时出现**。空回收站时整条提示条消失，工具栏也无可用操作。这是一个值得抄的**状态收敛**设计（见最后一节第 5 条）。

**回收站里的邮件能预览吗**

**能。** 回收站是一个普通的 Gmail 系统标签，行为与任何标签视图完全一致：
- 可以打开阅读完整正文（不是缩略预览）
- 可以展开会话线程
- 可以搜索：`in:trash "关键词"`
- 附件照常可下载

来源：<https://techpp.com/2024/10/17/gmail-archive-vs-delete>、<https://www.aeanet.org/how-do-i-delete-the-trash-in-gmail>

这一点与很多产品把回收站做成「只读摘要列表」不同。Gmail 明确保证回收站内**完整可读**，理由是 30 天窗口的意义就是「让你能找回并读完它」。

**「永久删除」怎么触发**

两条路径，对应两种粒度：

| 粒度 | 触发方式 | 工具栏文案 |
|---|---|---|
| 单封/多封（选中后） | 勾选左侧复选框 → 点顶部垃圾桶图标 | 视图在回收站内时，按钮标签变为 **`Delete forever`**（`永久删除`） |
| 全部 | 提示条里的 `Empty Trash now` 链接 | — |

关键细节：**同一个垃圾桶图标，在不同视图下 hover 出的 tooltip 文案不同**（收件箱里是 `Delete`，回收站里是 `Delete forever`）。这是「同一个控件、上下文决定语义」的模式。

来源：Google 官方 <http://mail.google.com/support/bin/answer.py?answer=50208>（"At the top, click **Delete forever**"）、<https://www.itechguides.com/what-do-the-different-symbols-in-gmail-mean-a-complete-icon-guide>

**回收站里的邮件右键菜单有哪些项**

在回收站视图右键一封邮件，菜单项包含（官方完整列表，超集）：

- 回复 / 回复所有人 / 转发
- **移到**（Move to）—— 用于恢复，选 Inbox 即恢复
- **永久删除**（Delete forever）
- 标记为已读 / 未读
- 归档（在回收站里意义不大，但菜单项仍存在）
- 静音
- 在新窗口中打开
- 查找「[发件人姓名]」发送的电子邮件

官方右键菜单全集（收件箱视图）：`回复`、`回复所有人`、`转发`、`作为附件转发`、`归档`、`删除`、`标记为已读`、`标记为未读`、`延后`、`添加到 Tasks`、`移至`、`标记为`、`静音`、`查找[发件人姓名]发送的电子邮件`、`在新窗口中打开`

来源：<https://support.google.com/mail/answer/16356082>（Gmail 官方右键菜单文档）

**注意：Gmail 的右键菜单里有「移到」但没有「恢复」这个独立词条。** 恢复 = 移到收件箱。这比单造一个「恢复」动作更统一（所有移动都走同一个 Move to 面板）。

### 1.2 Archive / 归档

**Archive 按钮在 mail row 上怎么呈现**

Gmail 有**两个位置**，都提供 Archive：

**A. 行内悬停图标（hover quick actions）—— 至今仍存在**

- 鼠标悬停在邮件行上时，**该行最右侧浮现 4 个图标**
- 图标内容（从右到左）：**归档、删除、标记为已读/未读、延后（Snooze）**；如果是会议邀请邮件，额外出现 RSVP 按钮
- 官方文档明确确认此功能仍在：*"With hover actions, when you hover to the right of a message, you can archive, delete, snooze, or mark a message as read. You can turn hover actions off."*
- 关闭路径：设置 → 查看所有设置 → 常规 → **`Hover actions`** → `Disable hover actions` → 保存更改

  来源：Google 官方《Buttons in your Gmail toolbar》<https://goo.gle/2rvzRAz>、<https://supportdesk.grcc.edu/TDClient/53/Portal/KB/Article/1064/Enable-or-Disable-Hover-Actions-in-Gmail>

  悬停图标的具体构成：<https://www.worketc.com/blog/new-gmail-is-coming-for-everyone-everything-you-need-to-know>（"you'll see four quick-access icons at that email's right-most side... Archive email / Delete email / Mark as unread / Snooze"）

**B. 顶部工具栏按钮（选中后）**

- 勾选复选框 → 顶部出现工具栏 → 第一个按钮是归档
- Gmail 还提供 **`Button labels`** 设置，可把纯图标工具栏切换为**带文字标签**的工具栏（`Icon` / `Text` 二选一）

  来源：<https://goo.gle/2rvzRAz>

**Archive 和 Delete 在 Gmail 行内的视觉区分方式**

- 归档 = **带向下箭头的方盒图标**（↓ inbox tray），语义是「收起来」
- 删除 = **垃圾桶图标**
- 两者**并排相邻，图形轮廓明确不同**，且都只用单色描边，不靠颜色区分
- 归档**不带任何红色/警示色**。Gmail 从不给破坏性操作涂红色 —— 破坏性的是「永久删除」，而那个只在回收站视图里以文字按钮形态出现

**归档后邮件去哪了？怎么找回？**

- 机制本质：**归档 = 移除 `Inbox` 标签**。不是移动到某个文件夹。
- 归档后：
  - 从收件箱消失
  - **仍在 `All Mail`（所有邮件）里**
  - 仍在它原有的其他用户标签里
  - **仍可被搜索到**（搜索结果里照常出现）
  - **不会**被自动删除，除非你之后手动删
- 找回入口（三条）：
  1. **撤销（Undo）**：操作后左下角弹出黑色提示框，文案 `Conversation archived` + 蓝色 `Undo` 链接，**数秒内**有效（约 5–30 秒）。点错的第一时间撤销。
  2. **All Mail 视图**：侧边栏 → `All Mail` → 找到邮件 → 勾选 → 顶部 **`移到`（Move to）** 图标 → 选 `Inbox`；或右键 → `移到` → `收件箱`
  3. 邮件本身在阅读视图下也有 `Move to Inbox`

  来源：<https://everydaytech.org/email-communication/email-organization-management/where-do-i-find-my-archive-emails-in-gmail>、<https://apexgear.blog/undo-archived-gmail-email>

**重要行为细节**

- **归档后的会话被回复时，不会自动回到收件箱。** 需要显式恢复。（多处来源一致确认：*"They won't reappear on their own, even if someone replies to the conversation."*）
- 归档的邮件**永久保留**在账户里，只要你不删。它是安全的默认动作 —— 多个来源都给出建议「归档优于删除，因为搜索总能找回来」。

### 1.3 批量操作与全选

**全选复选框设计**

- 位置：**搜索栏正下方、邮件列表第一行上方**，靠左，与每行的复选框左对齐
- 点击效果：**只选中当前页已加载的邮件**（默认 50 封，可在设置里改成 25/50/100）
- 复选框右侧有一个**下拉箭头**，点击展开二级菜单，提供 5 种智能选择：
  - `All`（全部）
  - `Read`（已读）
  - `Unread`（未读）
  - `Starred`（已加星标）
  - `Unstarred`（未加星标）

**「全选所有 N 封（仅加载了 M 封）」这个模式**

这是 Gmail 最有价值的设计之一。**两步递进式全选**：

**第 1 步**：勾选顶部复选框 → 选中本页 50 封

**第 2 步**：邮件列表顶部**立刻出现一条提示条**，文案（英文原文，来自 Google 官方文档）：

> **`All 50 conversations on this page are selected. Select all 2,000 conversations in Inbox.`**

其中 `Select all 2,000 conversations in Inbox.` 是**蓝色可点击链接**。

Google 官方中文版文案：

> **「已選取這個頁面上全部 50 個會話群組。選取『收件匣』中全部 2,000 個會話群組」**

来源：Google 官方 <http://mail.google.com/support/bin/answer.py?answer=50208>（「For example: *All 50 conversations on this page are selected. Select all 2,000 conversations in Inbox.*」）、<https://support.google.com/a/users/answer/9259770>

**链接文案随上下文变化**（这是关键设计）：

| 你在哪 | 链接文案 |
|---|---|
| 收件箱 | `Select all 2,000 conversations in Inbox.` |
| 某个用户标签 | `Select all N conversations in <该标签名>.` |
| 搜索结果 | `Select all conversations that match this search` |
| 分类标签页 | `Select all N conversations in Promotions.` |

来源：<https://www.techbloat.com?p=1606786/>、<https://support.google.com/mail/thread/195042455>

**链接不出现的 5 种情况**（官方 + 社区整理）：

1. 当前视图总数不超过一页 —— 没有可扩展的
2. **移动端 App 没有这个链接**（仅桌面网页版有）
3. 会话视图下一行可能含多封邮件，选中的是「会话」不是「邮件」，数字会小于预期
4. 在单封邮件的阅读视图中（不显示）
5. 搜索条件过窄，结果不足一页

**这个设计的精髓**：Gmail **从不假装全选就是全选**。它先给你低成本的「选中可见的」，然后**明确告诉你还有多少你没选上**，并把「选全部」作为一个需要**第二次显式点击**的动作。这避免了误操作 —— 这一点比文案本身更值得抄。

**批量工具栏的按钮有哪些**

勾选任意数量后，顶部工具栏出现（部分按选中项动态变化）：

- 归档（Archive）
- 举报垃圾邮件（Report spam，八角停标）
- 删除（Delete，垃圾桶）
- 标记为已读/未读（信封图标，随当前状态切换）
- 延后（Snooze，时钟）
- 添加到 Tasks（对勾圆圈）
- **移到**（Move to，文件夹图标 —— 标签 + 归档一步完成）
- **标签**（Label as，标签图标 —— 只加标签不移出收件箱）
- **更多**（More，三点竖排）

`More` 里还有：标记为重要/不重要、筛选类似邮件、静音、作为附件转发、阻止发件人、举报钓鱼、打印、显示原始邮件

**未选中任何邮件时**，工具栏显示的是：刷新、设置、收件箱导航等全局控件 —— 也就是说**工具栏是完全上下文相关的**，不复用。

来源：<https://www.positioniseverything.net/what-do-various-symbols-and-icons-mean-in-gmail>

**`移到` vs `标签` 的区别（重要语义）**

| 按钮 | 效果 |
|---|---|
| **Label as（标签）** | 只**添加**标签，邮件**留在收件箱** |
| **Move to（移到）** | 添加标签 **+ 移除收件箱**，等价于「打标签 + 归档」 |

Gmail 刻意提供两个独立按钮，而不是把「移到」做成「标签」的一个子选项。来源：<https://everydaytech.org/email-communication/email-organization-management/how-to-move-email-to-a-folder-in-gmail>

**智能标签如何与批量操作配合**

- Gmail 的**分类标签**（`Primary` / `Social` / `Promotions` / `Updates` / `Forums`）**不是侧边栏标签，而是收件箱顶部的 Tab**
- 它们本质是 Gmail 自动分类器（AI）的输出，**是只读视图，不可手动应用**
- **训练机制**：把一封邮件从某个 Tab **拖到另一个 Tab**，分类器就学会了这个发件人/这类邮件以后该去哪。这与批量操作是两套正交机制 —— 一个是「我手动整理」，一个是「教 AI 分类」
- 想把分类逻辑固化成规则，用 **Filters**（设置 → 筛选器和屏蔽地址），可勾选 `Also apply filter to matching conversations` **追溯应用到已存在的邮件**
- 官方建议的高效组合：`in:inbox is:unread` + `*+u`（全选未读）+ `E`（归档）→ 三键清空未读

来源：<https://www.makeuseof.com/tag/essential-gmail-terms-features>、<https://www.clrn.org/how-to-select-all-messages-in-gmail/>

### 1.4 信息架构

**左侧边栏层级结构**

Gmail 侧边栏**没有传统的文件夹树**，是一段扁平的、可折叠的列表：

**主段（固定顺序）**
1. 收件箱（Inbox）
2. 已加星标（Starred）
3. 已延后（Snoozed）
4. 已发邮件（Sent）
5. 草稿（Drafts）—— 草稿数会单独显示在侧边栏，且是**唯一**显示总数的项
6. 重要（Important）
7. 聊天（Chats）
8. 所有邮件（All Mail）
9. 垃圾邮件（Spam）
10. 回收站（Trash）

> 前 5 项（收件箱/星标/延后/已发送/草稿）历史上被固定钉在顶部且不可隐藏；后面几项在「更多」下方可隐藏。

**用户标签段**
- 自建标签列在系统标签下方，**支持无限层级嵌套**（子标签）
- 每个标签有**色块标识**
- 可在设置里逐个隐藏

**「更多」（More）**
- Gmail 早期版本把低频项收在 `More` 展开区。**新版已把 Trash/Spam 等直接显示**，但仍保留 `更多` 用于超长标签列表。

来源：<https://support.google.com/mail/answer/18522>（收件箱版面配置）、<https://www.makeuseof.com/tag/essential-gmail-terms-features>

**系统标签 vs 用户标签 —— 区分方式**

Gmail **不用视觉容器分组**（没有「系统标签」小标题），而是靠以下手段隐式区分：

| 维度 | 系统标签 | 用户标签 |
|---|---|---|
| 图标 | 有专属图标（收件箱/星标/时钟/纸飞机/垃圾桶等） | **无图标**，只有色块 |
| 颜色 | 固定中性色 | 用户可选的彩色 |
| 排序 | 固定在列表顶部，顺序恒定 | 排在系统标签之后，可拖拽排序 |
| 可删除/重命名 | **不可**（Inbox/Trash 无法删除） | 可改名、删除、改色 |
| 可嵌套 | 否 | **是**（子标签） |
| 计数 | 未读数 | 未读数 |

**一个反面教训值得注意**：因为缺少显式分组，当用户标签很多时，侧边栏会变成一堵没有层次的长墙。Lagoon 作为原生 App 有条件做得更好 —— SwiftUI 的 `List` 天然支持 `Section`，可以**显式分区**（收件箱 / 邮件 / 用户标签），而不是靠位置暗示。

**计数徽章的呈现规则**

- 侧边栏显示的是**未读数**（不是总数）
- **有未读时**：数字**加粗**显示，标签名也加粗
- **未读为 0 时**：数字**完全不显示**（不是显示「0」），标签名恢复常规字重
- 草稿是例外 —— 显示草稿**总数**而非未读数（草稿天然都是未读）
- 邮件列表内：未读行 = 发件人 + 主题 + 预览**全部加粗**；已读 = 常规字重
- 收件箱同时有分类 Tab 时，未读数会显示在**对应的分类 Tab** 上

来源：<https://www.techbloat.com/how-to-find-unread-emails-in-gmail-mobile-desktop.html>、<https://en.m.wikibooks.org/w/index.php?title=Gmail/Read_mail>

**「未读为 0 就完全不显示徽章」是 Gmail 最值得抄的一条规则** —— 它让侧边栏视觉噪音随工作量自动伸缩。

**搜索的调用方式（是否离开当前视图）**

- 搜索框固定在顶部，**全局常驻**，快捷键 `/` 或 `Ctrl/⌘+F` 聚焦
- **执行搜索会完全替换当前视图** —— 邮件列表区域变成搜索结果，**侧边栏仍保留**，当前标签的高亮态仍在（视觉上告诉你「我搜的时候在哪个标签的语境下」）
- 返回原视图：搜索框左侧出现**返回箭头**，或按 `Esc`
- 搜索**默认跨全账户**（收件箱 + 已发送 + 已归档 + 垃圾邮件 + 回收站），不限于当前标签
- 高级搜索：搜索框内的**滑块图标**展开面板，可选发件人/日期范围/包含字词
- 搜索结果页**同样支持**第二步「全选所有匹配此搜索的会话」

关键设计：**搜索不改变侧边栏上下文，只改变中间列表的内容。** 这与很多原生客户端「搜索开一个新窗口/新标签」的做法不同 —— 保持空间连续性。

**Gmail 智能标签与搜索的衔接**：搜索结果里也能用分类运算符（`category:promotions`、`label:project-x`），实现「AI 分类结果 + 精确筛选」的组合。

### 1.5 其他可借鉴细节

**撤销（Undo）提示条**

- 位置：**左下角**（桌面版；移动版在底部）
- 形态：**深色/黑色圆角矩形浮层**，左侧一行动作描述（如 `Conversation archived`），右侧一个**蓝色 `Undo` 文字链接**
- 时效：约 5–30 秒后自动消失
- 覆盖动作：归档、删除、标记、移动、加/减标签
- **不覆盖**：清空回收站、永久删除 —— 不可逆操作不给撤销
- 快捷键 `Z` 也能撤销上一次操作

**Gmail 在回收站内点击垃圾桶会弹确认**：「Gmail even gives you a pop-up warning, making sure you understand the finality of your action」—— 即**即使已在回收站内，永久删除仍要二次确认**。清空整个回收站也要确认。两层不可逆操作都有确认。

---

## 2. Outlook

### 2.1 已删除邮件（Deleted Items）

**基本事实**

- 命名：`Deleted Items`（Microsoft 365 / Exchange / Outlook.com）。若账户是 Gmail/Yahoo/iCloud 通过 IMAP 接入，则显示为 `Trash` —— **名称由账户类型决定，不是 Outlook 决定的**
- 层级：默认系统文件夹，位于文件夹列表，与 Inbox / Sent Items / Archive / Junk Email 平级。**不可重命名、不可移动、不可删除**（系统文件夹）

**如何管理 / 批量操作**

| 操作 | 新版 Outlook / 网页版 | 经典 Outlook (Windows) | Outlook for Mac |
|---|---|---|---|
| 清空整个文件夹 | 文件夹窗格右键 `Deleted Items` → **`Empty folder`**；或打开文件夹后点顶部工具栏 `Empty folder` | 右键文件夹 → `Empty Folder`；或 `文件` 选项卡 → `Empty Folder` | 文件夹菜单 → `Empty Folder` |
| 恢复单封 | 勾选 → `常用` 功能区 → `Move` → 选目标文件夹；或右键 → `Restore`；或直接**拖拽**到左侧目标文件夹 | 右键 → `Move` → 选文件夹；或拖拽 | 右键 → `Move` → `Inbox`；或拖拽 |
| 永久删除（跳过回收站） | 选中 → **`Shift+Delete`** | 同左 | 同左 |
| 恢复「已清空」的邮件 | 文件夹内顶部 **`Recover items deleted from this folder`** → 打开 Recoverable Items 面板 → 勾选 → `Restore` | `常用` 功能区 → **`Recover Deleted Items From Server`** → 勾选 → `Restore Selected Items` → OK | 支持 `Recover items deleted from this folder` |

来源：<https://support.microsoft.com/en-us/outlook/mail/recover-and-restore-deleted-items-in-outlook>（微软官方）、<https://www.usecarly.com/blog/how-to-empty-deleted-items-in-outlook>

**关键：Outlook 是「三层」删除模型**

```
第 1 层：Delete          → 已删除邮件（可一键恢复）
第 2 层：Shift+Delete    → 跳过已删除邮件，直入 Recoverable Items
         或 清空已删除邮件
第 3 层：Recoverable Items（隐藏文件夹，14 天后彻底清除）
```

对比 Gmail 只有两层（回收站 30 天 → 彻底删除）。**Outlook 多出的第三层是一个「隐藏但可访问」的二级保险箱**，这是它比 Gmail 更强的地方，也是它更复杂的原因。

**保留期**

- **Recoverable Items**：Microsoft 365 工作/学校账户**默认 14 天**，管理员可延长至最多 30 天
- **Outlook.com 消费者账户**：已删除邮件保留**最多 30 天**后自动删除；垃圾邮件同样 30 天
- 若邮箱套用了保留策略（retention policy）或合规性 eDiscovery 保留，邮件可保留**数年**，且解除保留后还有 30 天延迟
- **M365 工作账户即使 Shift+Delete / 清空文件夹，邮件仍进 Recoverable Items** —— 用户以为的「永久删除」实际不是

**Shift+Delete 的确认文案**（英文原文）：

> **`This item will be permanently deleted. Continue?`** → `OK`

中文：「此项目将被永久删除。是否继续？」

**自动清空设置**

- 经典 Outlook：`文件` → `选项` → `高级` → `Outlook 启动和退出` → 勾选 **`退出 Outlook 时清空「已删除邮件」文件夹`**
- 同区域还有 **`永久删除项目前要求确认`** 开关
- 新版 Outlook / 网页版：`设置` → `邮件` → `邮件处理` → 开启 **`Empty my Deleted Items folder (when I sign out)`**
- 注意：**新版 Outlook（Windows）已移除 AutoArchive 功能**

**Recoverable Items 的操作细节（值得抄）**

- `Recover items deleted from this folder` 这条链接就放在**邮件列表顶部、`Deleted Items` 标题的正下方** —— 位置极其隐蔽但位置固定可预期
- 打开的是 Recoverable Items 面板，**有独立搜索框**（可按发件人/主题/关键词过滤）
- 支持**勾选面板标题旁的复选框全选**
- 从 Recoverable Items 恢复的邮件**回到「已删除邮件」文件夹**，不是直接回收件箱 —— 需要用户再走一步 Move to Inbox
- `Deleted On` 列记录的是**永久删除的时刻**（Shift+Delete 时点，或从已删除邮件移除的时刻），可用于判断剩余恢复时间
- 经典 Outlook 的 `Recover Deleted Items From Server` 窗口内**不支持 `Ctrl+A`**，只能用 Ctrl 点选 / Shift 范围选
- **仅 Exchange / Microsoft 365 / Outlook.com 账户支持。** POP3 和多数 IMAP 账户**没有这个功能**（因为删除不落服务器）。如果看到的是 `Trash` 而非 `Deleted Items`，或菜单里没有恢复命令，说明账户类型不支持

**Outlook 网页版「清空已删除邮件失败」的官方排障指引**（很好的错误处理文案范例）：

> 1. 打开「已删除邮件」文件夹，选择「空文件夹」
> 2. 选择页面顶部的「恢复从此文件夹删除的项目」，然后再次选择「空文件夹」
> 提示：删除大量邮件时可能需要一些时间，请保持浏览器窗口打开；如果仍无法删除，请选择更小的批次删除

来源：<https://support.microsoft.com/zh-cn/office/无法清空-outlook-com-中的-已删除邮件-文件夹-b7590ecc-c97c-4e23-8b93-3fbbf9521787>

**批量操作**

- 标准 Windows 模式：`Shift+点击` 选范围，`Ctrl+点击` 选离散项，`Ctrl+A` 全选当前可见
- **移动端 App 不支持从服务器恢复**（Recoverable Items）—— 必须切到桌面/网页版
- 经典 Outlook 支持**恢复已删除的文件夹**（若它还在「已删除邮件」内）：展开「已删除邮件」→ 定位文件夹 → 拖回原位。**但已永久删除的文件夹无法恢复**

### 2.2 Archive / 归档

**Outlook 的 Archive 是「真文件夹」，不是 Gmail 那种「去标签」**

- 归档 = 移动到名为 **`Archive`（存档）** 的真实文件夹
- 该文件夹是 M365 / Exchange / Outlook.com 账户的**默认系统文件夹之一**，与 Inbox / Sent Items / Deleted Items 平级
- **即使从未使用过归档功能，该文件夹也已存在**并出现在文件夹列表中
- **无法重命名、移动或删除**
- POP/IMAP 账户（Gmail/Yahoo/iCloud 接入）：可自建 Archive 文件夹，或指定现有文件夹作为归档目标
- **重要副作用：用「存档」按钮后，邮箱大小不会缩减**（邮件还在，只是离开收件箱）。要真正减容需 M365 企业版的「联机存档」

来源：<https://support.microsoft.com/zh-cn/office/存档在-outlook-for-windows-中-25f75777-3cdc-4c77-9783-5929c7b47028>（微软官方）

**Archive 按钮的位置与视觉**

- 位置：顶部**工具栏 / 功能区**，位于 **`删除`（Delete）分组内** —— 与 Delete 按钮**在同一个按钮组里相邻**
- 新版 Outlook：在邮件列表上方顶部命令栏
- 图标：与 Gmail 一致，**带向下箭头的方盒**
- 经典 Outlook：**`存档` 按钮只在 Outlook 2016 / 2019 / Microsoft 365 版的功能区上可见**，更老版本的功能区上没有这个按钮
- 多选：`Ctrl+点击` 逐个选，`Shift+点击` 选范围
- 右键菜单也有 `Archive`

**键盘快捷键**

| 平台 | 快捷键 |
|---|---|
| 经典 Outlook / 网页版 / 新版 | **`Backspace`** |
| Outlook for Mac | **`Control+E`**（`⌃E`），或 `⌘⌫` |
| 撤销 | `Ctrl+Z` |

**关键行为约束（官方明确说明）**：

- **`Backspace` 的行为无法更改**
- **如果邮件是在独立窗口中打开的（不是在阅读窗格中打开），`Backspace` 无效。** 必须关闭该窗口、在阅读窗格中查看，才能用 Backspace 归档。此时只能用功能区的 `存档` 按钮
  > 这是一个真实存在的可用性缺陷 —— 同一个快捷键在两种窗口模式下行为不一致，且无提示

- 管理员可通过注册表项 `DisableOneClickArchive`（DWORD = 1）**全局禁用 Backspace 归档**：
  ```
  群组策略：HKEY_CURRENT_USER\SOFTWARE\policies\Microsoft\office\16.0\outlook\options
  Office 自定义工具：HKEY_CURRENT_USER\SOFTWARE\microsoft\office\16.0\outlook\options
  ```
  **但注意：Outlook 网页版、Outlook for Windows、Outlook 移动端、Outlook.com 上的归档功能无法通过组策略禁用。** 即「禁不禁得掉」取决于客户端，这个不一致性本身就是设计缺陷

**归档后的反馈**

- 操作后**弹出确认通知，提供「撤消」（Undo）选项**
- 撤销窗口约 **5 秒**
- 可通过 `Move` → `Inbox` 找回归档的邮件，或从文件夹窗格直接拖拽

**归档 vs 联机存档（Online Archive）**

- 联机存档是 M365 企业客户的功能，相当于**第二个账户**，有自己的文件夹树
- **联机存档中的项目不包含在从收件箱发起的搜索中** —— 搜不到
- 管理员可设置存档策略，一年后自动把项目移到联机存档
- 旧的「自动存档（AutoArchive）」把邮件移到本地 `.pst` 文件 → 邮件从服务器移除 → **更难被搜索到，硬盘丢失即永久丢失**。这是被**主动废弃**的设计，理由正是「可搜索性」

**Outlook 有而 Gmail 没有的：批量操作后仍可搜索**

Outlook 的 Archive 文件夹是真实文件夹，虽然默认搜索范围是全邮箱（所以归档后仍能搜到），但用户可以**把搜索范围限定在 Archive 文件夹内**：先选中 Archive 文件夹，再搜索，搜索框就只搜这个文件夹。

### 2.3 重点收件匣（Focused / Other）—— Outlook 的「归档替代品」

**设计**

- 2016 年推出，**取代 Clutter**，现为 M365 / Outlook 网页版 / Outlook.com / 移动端的默认体验
- 把收件箱一分为二：
  - **`Focused`（重点）** —— 预测你现在最想看的
  - **`Other`（其他）** —— 其余，包括大部分营销邮件
- **启用后立刻生效**：一旦开启，邮箱顶部立即出现 `Focused` 和 `Other` 两个 Tab，**并立即重新整理收件箱中所有邮件**（不是只对新邮件生效）
- 关闭路径：`设置` → `邮件` → `版面配置` → `Focus Inbox` → 选 **`Don't sort my messages`（不对我的邮件进行排序）**
- **切换设置会导致「已筛选邮件（Clutter）」文件夹停止接收邮件**；原本设为进 Clutter 的邮件现在进 `Other`；Clutter 里已有的邮件会**留在那里不动**

**Tab 的位置**：**在邮箱顶部的邮件列表上方**，与分类 Tab 同一层级。

**操作方式（右键）**：

| 场景 | 菜单路径 |
|---|---|
| Focused → Other（仅这一封） | `Move` → `Move to Other inbox` |
| Focused → Other（**该发件人以后所有**） | `Always move to Other inbox` |
| Other → Focused（仅这一封） | `Move` → `Move to Focused inbox` |
| Other → Focused（该发件人以后所有） | `Always move to Focused inbox` |

来源：<https://support.office.microsoft.com/zh-cn/article/outlook-的重点收件箱-f445ad7f-02f4-4294-a82e-71d8964e3978>

**「Move to」vs「Always move to」的二分设计 —— 这是本报告最值得抄的单点设计**

- 普通「移到 X」= 只影响当前选中项
- 「**始终**移到 X」= 建立一条**发件人级规则**，影响该发件人未来所有邮件
- **两者在同一个菜单里，紧邻，一目了然**

这解决了一个真实痛点：用户在 AI 分流收件箱里把一封邮件移到「其他」，但下一次同一发件人的邮件又被 AI 放回「重点」，反复 annoying。「始终移到」把一次性纠错升级为永久训练，且**用户不需要去找设置界面**。

Lagoon 的定位是「AI 分流的收件箱」，这个设计与产品核心机制直接契合。

**分类器信号（微软未完全公开，但业界已总结）**：

推向 `Focused`：个人发件地址在已知企业域名、显示名是人名、内容以纯文本为主、无 List-Unsubscribe / Precedence: bulk 头、无追踪像素、用户此前打开或回复过该发件人、主题是对话式/含 `Re:`、发件人显示名与地址始终一致
推向 `Other`：重 HTML 模板、大量主图、多个 CTA、营销话术、追踪像素、退订头、ESP 共享发件池

**`Other` 不是垃圾邮件**：`Other` 是**已投递的收件箱视图**，可搜索、可索引、SMTP 层计入收件箱。垃圾邮件在 `Junk Email` 文件夹，是完全不同的目的地。

**已知限制**：**共享邮箱不支持重点收件匣**（设计如此），此时右键菜单里点「移动」邮件不会移动。

### 2.4 信息架构

**文件夹窗格（Outlook 网页版 / 新版 Outlook）**

典型自上而下：
```
收件箱
草稿
已发送邮件
存档 (Archive)
垃圾邮件 (Junk Email)
已删除邮件 (Deleted Items)
───────────
[账户名 / 更多文件夹]
```

- 无「星标」概念；有 **`标记/跟进`**（Flag）替代，用颜色标记
- 无 Gmail 式的「重要」系统标签
- 侧边栏可折叠（`显示导航窗格` 按钮）
- 「收藏夹（Favorites）」机制：把常用文件夹置顶。从收藏夹移除只是隐藏快捷方式，**不删除真实文件夹**

**计数徽章规则**

- Outlook.com / 新版 Outlook：**未读数显示在文件夹名右侧**
- Outlook.com 默认**同时显示「未读数」和「总件数」**（如 `12 / 340`）—— 这是 Outlook 特有的、Gmail 没有的信息密度
- **经典 Outlook 桌面版默认不显示未读数**（需手动开启「显示项目计数」或用「搜索未读项」替代）
- **焦点收件匣的未读数与 `Focused` Tab 同步**（移动端徽标数也同步；可在设置里关闭同步）

**搜索的调用方式**

- 搜索框在**顶部**，但**默认只搜当前文件夹**
- 可切换范围：`All Mailboxes`（所有邮箱）/ `Current Mailbox`（当前邮箱）
- **经典 Outlook 默认搜整个邮箱**；若要限定范围，先选中目标文件夹再搜
- **联机存档中的邮件不参与收件箱发起的搜索** —— 这是明确的搜索盲区
- 搜索**不会像 Gmail 那样把当前标签高亮保留**为「搜索语境」，它是独立的搜索范围选择器

**右键菜单（Gmail vs Outlook 对比）**

| Gmail | Outlook |
|---|---|
| 回复 / 回复所有人 / 转发 | 回复 / 回复所有人 / 转发 |
| 归档 | **归档** |
| 删除 | 删除 |
| 标记为已读 / 未读 | 标记为已读 / 未读 |
| 延后 | —（**无延后**） |
| 添加到 Tasks | —（**无**） |
| 移到 | **移动**（子菜单） |
| 标记为（标签） | 分类（Categories） |
| 静音 | 规则 → 忽略对话 |
| 查找该发件人的邮件 | — |
| 在新窗口中打开 | — |
| — | **始终移到重点/其他** |
| — | **筛选** |
| — | 规则 / 分类 / 跟进 |

**Outlook 独有的右键能力**：`筛选`（按发件人/收件人/主题/正文/重要性/附件/敏感性创建规则）、`分类`（彩色分类标签）、`规则`（新建/管理规则）。

---

## 3. Gmail vs Outlook 关键对比

| 维度 | Gmail | Outlook |
|---|---|---|
| 回收站命名 | Trash（en-GB 为 Bin） | Deleted Items（IMAP 账户为 Trash） |
| 保留层数 | 2 层 | **3 层**（已删除 → Recoverable Items → 清除） |
| 保留期 | 30 天 | 已删除 14–30 天；Recoverable 14–30 天（可配） |
| 永久删除触发 | 回收站视图内点垃圾桶 | **`Shift+Delete`**（任意视图） |
| 永久删除确认 | 有 | 有（"This item will be permanently deleted. Continue?"） |
| 归档语义 | **移除 Inbox 标签**（邮件原地不动） | **移动到 Archive 文件夹** |
| 归档后可否搜索 | 可以（全局搜索） | 可以（默认全邮箱搜；联机存档除外） |
| 归档按钮位置 | 工具栏 + **行内悬停** | 工具栏 `删除` 分组内（**无行内悬停**） |
| 归档快捷键 | `E` | `Backspace`（Mac: `⌃E`） |
| 撤销提示 | 左下角黑色浮层，数秒 | 底部弹出通知含「撤消」，约 5 秒 |
| 二级全选 | **有**（"全选所有 N 封"） | **没有**（只能 `Ctrl+A` 选已加载的） |
| 智能全选下拉 | **有**（已读/未读/星标/未星标） | 有 Filter 下拉（未读/已标记/有附件/日期） |
| 分类机制 | 5 个 Tab（Primary/Social/Promotions/Updates/Forums），**可拖拽训练** | 2 个 Tab（Focused/Other），右键 `Move` / `Always move` **训练** |
| 分类 Tab 数量 | 5 | 2 |
| 计数信息 | 仅未读数，0 时不显示 | 未读数 + 总数（Outlook.com） |
| 侧边栏结构 | 扁平列表，靠位置隐式区分 | 文件夹树，真实层级 |
| 搜索默认范围 | 全账户 | 当前文件夹（可切） |
| 移动端二级全选 | **没有** | 没有 |
| 移动端服务器级恢复 | 无此概念 | **不支持**（需桌面/网页） |

---

## 4. 可直接抄的具体设计（面向 macOS 原生 SwiftUI）

以下 10 条按「抄的价值 / 实现成本」排序。每条都注明 Gmail/Outlook 出处与 SwiftUI 落地方式。

### 1. 同一个按钮、上下文决定语义（抄 Gmail 的 `#` 键设计）

**设计**：垃圾桶图标在收件箱里是「移到回收站」，在回收站视图里变成「永久删除」，图标不变、tooltip 文案变。用户建立一次肌肉记忆，图标位置永远不动。

**Gmail 出处**：`<http://mail.google.com/support/bin/answer.py?answer=50208>` —— 同一篇文档里，收件箱段落写 `click Delete`，回收站段落写 `click Delete forever`。

**SwiftUI 落地**：`Button` 内的 `Image(systemName: "trash")` 固定，用一个从当前 mailbox 派生的 `actionTitle` 变量驱动 `Label`/`help`：
- 视图是 `.trash` → `"trash"` + title `永久删除`
- 其他视图 → `"trash"` + title `移到废纸篓`

不要为回收站单独设计一套工具栏。用户会迷路。

### 2. 「Empty Trash now」用文字链接、且只在非空时出现（抄 Gmail）

**设计**：
- 清空整个废纸篓**不是工具栏图标按钮**，是嵌在列表顶部提示条里的**文字链接**
- 链接的宿主提示条还承担教育职责：「废纸篓中超过 30 天的邮件将被自动删除」
- **废纸篓为空时，整条提示条连同链接一起消失**
- 链接与工具栏垃圾桶图标**在视觉上明确分离**，不可能误触

**Gmail 出处**：<https://everydaytech.org/email-communication/email-organization-management/how-to-delete-trash-in-gmail>

**SwiftUI 落地**：
```swift
if !trash.isEmpty {
    HStack {
        Text("废纸篓中超过 30 天的邮件将被自动删除。")
        Spacer()
        Button("立即清空废纸篓") { ... }   // SwiftUI 默认 Button 就是文字样式
            .buttonStyle(.plain)
            .foregroundStyle(.accent)
    }
}
```
放在 `List` 的第一个 `Section` 里（或 `.safeAreaInset(edge: .top)`）。**这个位置对应 Gmail 的邮件列表顶部，也是 macOS 邮件类 App 放状态提示的天然位置。**

### 3. 两步递进式全选：先给便宜的，明确告诉你漏了多少（抄 Gmail —— 本报告价值最高的一条）

**设计**：勾选顶部全选框后，只选中已加载的 50 封。**立刻**在列表顶部出现提示条：
> 「已选取本页面上全部 50 个会话。选取『收件箱』中全部 2,000 个会话」
>
> `All 50 conversations on this page are selected. Select all 2,000 conversations in Inbox.`

后半句是蓝色链接。**文案随上下文变化**：在收件箱说「收件箱」，在标签里说该标签名，在搜索结果里说「匹配此搜索的会话」。

**Gmail 出处**：Google 官方 <http://mail.google.com/support/bin/answer.py?answer=50208>

**为什么值得抄**：它**从不假装「全选」就是「全部」**。Apple Mail 的 `Cmd+A` 只选已加载项且**完全不提示**有多少遗漏 —— 这是用户在批量删除后才发现「怎么还剩这么多」的根因。Gmail 把「还有 1,950 封没选」变成一个**需要第二次显式点击**才能跨越的边界。

**SwiftUI 落地**：
```swift
if selection.count == loadedMessages.count, loadedMessages.count < totalInView {
    HStack {
        Text("已选取本页面上全部 \(loadedMessages.count) 封邮件。")
        Button("选取「\(viewName)」中全部 \(totalInView) 封") {
            selection = Set(allIDsInView)   // 触发全量查询
        }
        .buttonStyle(.plain)
    }
    .font(.callout)
}
```
`viewName` 由当前 mailbox / 搜索条件派生。移动端不做这一步（与 Gmail 一致）。

### 4. 行内悬停浮现操作图标（抄 Gmail 的 Hover Actions）

**设计**：悬停邮件行时，**该行最右侧**淡入 3–4 个单色描边图标：归档（方盒带下箭头）、删除（垃圾桶）、标记未读（信封）、延后（时钟）。**只有悬停的那一行有**，其他行不变化。移开即消失。

**Gmail 出处**：Google 官方 <https://goo.gle/2rvzRAz>（「With hover actions, when you hover to the right of a message, you can archive, delete, snooze, or mark a message as read. You can turn hover actions off.」）

**SwiftUI 落地**：这是 macOS 原生比网页更有优势的地方。
```swift
.onHover { inside in
    withAnimation(.easeOut(duration: 0.12)) { hoveredRowID = inside ? row.id : nil }
}
.opacity(hoveredRowID == row.id ? 1 : 0)
```
两个关键细节（Gmail 做对了的）：
- **淡入用 0.1–0.15 秒的 ease-out**，不要瞬切。瞬切会让扫读时图标「跳」出来，很干扰
- **图标区不参与布局**（用 `.overlay(alignment: .trailing)`），出现时行内容**不发生位移**。这是悬停按钮最容易做错的地方
- 未读行的加粗文字不能因为图标出现而改变字重或截断

**建议**：在设置里提供开关（抄 Gmail 的 `Disable hover actions`）。macOS 触控板用户其实很依赖这个，而纯键盘用户会觉得是干扰。

### 5. 未读数为 0 时徽章完全不显示（抄 Gmail）

**设计**：侧边栏只显示**未读数**。有未读 → 数字**加粗**、标签名也加粗；未读为 0 → **数字不显示**（不是显示 0），标签名恢复常规字重。

**Gmail 出处**：<https://www.techbloat.com/how-to-find-unread-emails-in-gmail-mobile-desktop.html>

**为什么值得抄**：侧边栏噪音随实际工作量自动伸缩。空的时候侧边栏是干净的「目录」，忙的时候才变成「待办清单」。如果固定显示 `0`，七个标签就是七个灰色的 0，纯噪音。

**SwiftUI 落地**：
```swift
if unreadCount > 0 {
    Text("\(unreadCount)").bold()
}
```
同时草稿类项目（如 Lagoon 后续若有）可以走相反策略显示总数 —— Gmail 也是这么做的。

### 6. 撤销提示条放在左下角、几秒后自动消失（抄 Gmail / Outlook）

**设计**：归档/删除/移动后，**左下角**浮出深色圆角浮层：左侧一行动作描述（`会话已归档`），右侧一个强调色 `撤销` 文字链接。约 5–30 秒后自动消失。**不可逆操作（清空废纸篓、永久删除）不给撤销。**

**出处**：<https://apexgear.blog/undo-archived-gmail-email>、<https://email-tools.me/posts/how-to-archive-emails-in-bulk>

**SwiftUI 落地**：`.overlay(alignment: .bottomLeading)` 挂在最外层容器上（不是 `List` 内部，否则会随滚动）。macOS 上应支持**点击「撤销」按钮聚焦**（`.focusable()` + 默认按钮行为），键盘用户不该必须去按 `⌘Z`。

**进阶（Outlook 做得更好）**：Outlook 的撤销通知明确写出动作名（"已归档" vs "已移动到 X"）。Lagoon 的撤销条也应显示具体目标，而不是笼统的「操作已完成」。

### 7. 「移到」与「标记为」拆成两个独立按钮（抄 Gmail 的 Move to vs Label as）

**设计**：
- **标记为（Label）** = 只打标签，邮件**留在收件箱**
- **移到（Move to）** = 打标签 **+ 移出收件箱**，一次完成

**Gmail 出处**：<https://everydaytech.org/email-communication/email-organization-management/how-to-move-email-to-a-folder-in-gmail>

**为什么值得抄**：这两个动作在心智上极易混淆（都表现为「邮件去某个地方了」），但**可逆性完全不同** —— 误打标签只需删标签，误移出收件箱则邮件从眼前消失。把它们做成两个平级按钮（而不是一个按钮 + 一个选项），用户在**点击前**就完成了选择。这是把「决策前移」的经典做法。

### 8. 「移到 X」与「始终移到 X」并列在同一个菜单（抄 Outlook 的 Focused/Other）

**设计**：右键菜单里紧邻两项：
- `移到「其他」` —— 只影响当前选中项
- `始终移到「其他」` —— 建立**发件人级规则**，影响该发件人未来所有邮件

**出处**：<https://support.office.microsoft.com/zh-cn/article/outlook-的重点收件箱-f445ad7f-02f4-4294-a82e-71d8964e3978>

**为什么值得抄（对 Lagoon 尤其关键）**：Lagoon 的核心是 **AI 分流**。AI 分类必然会出错，而用户纠错的默认路径就是「移到 X」。但如果只有单封移动，用户会发现**同一发件人下封信又被 AI 放回原处** —— 反复纠错是分流类产品最伤信任的失败模式。

把「建立发件人规则」放在**纠错动作的正旁边**，用户不需要知道「规则」这个功能存在，就能顺手把一次纠错升级为永久训练。

**SwiftUI 落地**：`Menu` 里两组，每组之间 `Divider()`，第二项用 `.textCase(nil)` 保持正常大小写（避免被系统渲染成全大写而弱化视觉权重 —— 虽然逻辑上它是更重的动作）。**注意**：这条动作要发网络请求、影响未来所有邮件，建议加简短副标题如「以后来自该发件人的邮件都放到这里」。

### 9. 恢复动作复用「移到」而不是单造「恢复」（抄 Gmail 的 Move to 菜单）

**设计**：在回收站里，官方右键菜单提供的是 **`移到`**，用户在其中选 `收件箱` 来完成恢复。**没有**一个独立的「恢复」词条。

**Gmail 出处**：<https://support.google.com/mail/answer/16356082>、<http://mail.google.com/support/bin/answer.py?answer=50208>（回收站恢复步骤就是「顶部点 `Move to`」）

**为什么值得抄**：
- 恢复就是「移到 X」的一个特例，**不需要新的心智模型**
- 用户在收件箱学到的「移到」用法，在回收站里原样可用
- 避免了多出一个语义重叠的动作，让右键菜单保持短

**SwiftUI 落地**：`Menu("移到…")` 里列出「收件箱」置顶 + 分隔线 + 用户标签 + 「废纸篓」置底（灰显）。**不额外加「恢复」按钮。**

### 10. 永久删除要确认两次（抄 Gmail + Outlook 的双层保护）

**设计**：
- Gmail：在回收站内点垃圾桶**（= 永久删除）会弹确认；再点「立即清空废纸篓」**又弹一次**确认，标题 `Confirm deleting messages`
- Outlook：`Shift+Delete` 弹确认 **`This item will be permanently deleted. Continue?`**
- Outlook 经典版还有独立的全局开关 `永久删除项目前要求确认`

**出处**：<https://www.lifewire.com/empty-the-spam-and-trash-folders-fast-in-gmail-3572084>、<https://email-tools.me/posts/how-to-permanently-delete-emails>

**SwiftUI 落地（用 `.alert` 而非 sheet）**：
- 永久删除**单封** → `.alert("永久删除这封邮件？", isPresented:)`，按钮：`取消`（默认）/ `永久删除`（`.destructive` 角色）。**不要加第二个「删除」字样的按钮** —— 两个都叫「删除」的按钮是确认对话框的设计事故
- 清空整个废纸篓 → 文案带上数量：`永久删除废纸篓中的 2,000 封邮件？此操作无法撤销。` 按钮 `清空废纸篓`（`.destructive`）
- **`.alert` 用于需要用户决策的确认；不要用 sheet 承载破坏性确认** —— sheet 容易被误当成「设置面板」而随手关掉，而 alert 的模态权重更适合不可逆操作
- 归档、删除（非永久）、移动 → **一律不弹确认**，只给撤销条

### 补充：把系统标签与用户标签显式分区（抄教训，Google 和 Outlook 都没做对）

**观察**：Gmail 靠**位置**隐式区分系统标签和用户标签（系统在上、用户在下方，无分组标题）。当用户标签一多，侧边栏就退化成一面没有层次的长墙。Outlook 虽有真实文件夹树，但系统文件夹与自建文件夹同样混在一棵树里。

**原生机会**：SwiftUI 的 `List` 天然支持 `Section`，可以**零成本**做显式分区：
```swift
Section("收件箱") { Inbox, Starred, Snoozed, Drafts, Sent }
Section("归档") { Archive, AllMail, Spam, Trash }
Section("标签") { ForEach(userLabels) { LabelRow($0) } }   // 支持缩进层级
```
代价几乎为零，扫读效率显著提升。这是 macOS 原生相对网页的**结构性优势**，不用白不用。

---

## 5. 明确「没有」的功能

| 功能 | Gmail | Outlook |
|---|---|---|
| 回收站邮件完整正文预览 | **有**（完整可读可展开会话） | 有 |
| 回收站「恢复到原位置」按钮 | **没有**（只能手动选目标） | **有**（`Restore` 会尝试回原文件夹；原文件夹不存在则回收件箱） |
| 回收站内的搜索 | **有**（`in:trash`） | 有（Recoverable Items 面板内独立搜索框） |
| 移动端二级全选（"全选所有 N 封"） | **没有** | **没有** |
| 移动端服务器级恢复（Recoverable Items） | 不适用 | **没有**（明确不支持，必须桌面/网页） |
| 批量操作前的「你确定要操作 N 封」确认 | 超过数百封时弹确认 | 有 |
| 回收站容量/占用空间显示 | **没有** | **没有** |
| 归档操作的独立快捷键说明浮层 | 有（`?` 打开全量快捷键表） | 有 |
| Outlook 式「始终移到 X」发件人级规则（针对归档） | **没有**（Gmail 需去设置里建 Filter） | **没有**（只有 Focused/Other 有） |
| 清空回收站前的「不可撤销」明确字样 | 部分有（确认框标题 `Confirm deleting messages`） | 有 |

---

## 6. 来源汇总

**Gmail 官方**
- 键盘快捷键：<https://support.google.com/mail/answer/6594>
- 工具栏按钮 + Hover actions + 按钮文字标签设置：<https://goo.gle/2rvzRAz>
- 右键菜单全集：<https://support.google.com/mail/answer/16356082>
- 删除与二级全选（含英文原文示例）：<http://mail.google.com/support/bin/answer.py?answer=50208>
- 收件箱版面配置：<https://support.google.com/mail/answer/18522>
- 整理及封存（中文官方，含中文提示条原文）：<https://support.google.com/a/users/answer/9259770>
- 释放存储空间（中文官方）：<https://support.google.com/a/users/answer/14300711>
- 社区版悬停设置说明：<https://supportdesk.grcc.edu/TDClient/53/Portal/KB/Article/1064/Enable-or-Disable-Hover-Actions-in-Gmail>

**Gmail 第三方**
- 清空回收站流程与确认框标题：<https://everydaytech.org/email-communication/email-organization-management/how-to-delete-trash-in-gmail>
- Empty Trash 确认框原文：<https://www.lifewire.com/empty-the-spam-and-trash-folders-fast-in-gmail-3572084>
- 二级全选链接的上下文变体：<https://www.techbloat.com?p=1606786/>
- 二级全选英文原文与 Primary 变体：<https://support.google.com/mail/thread/195042455>
- 移动端无二级全选：<https://support.google.com/mail/answer/7401>
- 悬停图标构成（4 个，从右到左）：<https://www.worketc.com/blog/new-gmail-is-coming-for-everyone-everything-you-need-to-know>
- 移动到 vs 标签、Move to 语义：<https://everydaytech.org/email-communication/email-organization-management/how-to-move-email-to-a-folder-in-gmail>
- 归档后去哪、All Mail 找回、撤销浮层：<https://everydaytech.org/email-communication/email-organization-management/where-do-i-find-my-archive-emails-in-gmail>
- 撤销浮层位置与时效：<https://apexgear.blog/undo-archived-gmail-email>
- 回收站可完整阅读：<https://techpp.com/2024/10/17/gmail-archive-vs-delete>
- Delete forever 与 Empty Trash 区别：<https://eathealthy365.com/what-happens-when-you-delete-emails-in-gmail>
- 侧边栏未读计数规则：<https://www.techbloat.com/how-to-find-unread-emails-in-gmail-mobile-desktop.html>
- 标签 vs 分类（智能标签）：<https://www.makeuseof.com/tag/essential-gmail-terms-features>
- 搜索替代当前视图：<https://www.clrn.org/how-to-undo-in-gmail>
- 智能全选下拉 + 批量工具栏按钮：<https://www.positioniseverything.net/what-do-various-symbols-and-icons-mean-in-gmail>
- 移动到 = 标签 + 归档：<https://email-tools.me/posts/how-to-archive-emails-in-bulk>

**Outlook 官方**
- 恢复与还原已删除项目（含新版/经典/Web 三套路径）：<https://support.microsoft.com/en-us/outlook/mail/recover-and-restore-deleted-items-in-outlook>
- 存档在 Outlook for Windows 中（按钮位置、Backspace 约束、禁用注册表、联机存档区别）：<https://support.microsoft.com/zh-cn/office/25f75777-3cdc-4c77-9783-5929c7b47028>
- 重点收件箱（Move to / Always move to 完整路径）：<https://support.office.microsoft.com/zh-cn/article/f445ad7f-02f4-4294-a82e-71d8964e3978>
- 无法清空已删除邮件（排障指引）：<https://support.microsoft.com/zh-cn/office/b7590ecc-c97c-4e23-8b93-3fbbf9521787>
- 复原和还原 Outlook 中的删除项目（繁中）：<https://support.microsoft.com/zh-tw/office/49e81f3c-c8f4-4426-a0b9-c0fd751d48ce>

**Outlook 第三方**
- 三层删除模型、保留期、Recoverable Items 操作细节：<https://www.usecarly.com/blog/how-to-recover-deleted-emails-in-outlook>
- 清空已删除邮件的全部路径 + 退出时自动清空设置：<https://www.usecarly.com/blog/how-to-empty-deleted-items-in-outlook>
- Deleted Items vs Trash 命名由账户类型决定、恢复功能的支持范围：<https://www.itechguides.com/where-is-the-trash-folder-in-outlook-a-quick-guide>
- Recover items deleted from this folder 位置、Ctrl+A 不支持：<https://robert365.com/article/recover-deleted-items-outlook-web>
- Archive 按钮位置与 Archive 文件夹性质：<https://www.positioniseverything.net/how-to-archive-emails-in-outlook>
- 重点收件箱分类信号与限制（共享邮箱不支持）：<https://smtpedia.com/?p=35170/>
- Backspace 归档与 Shift+Delete 的行为：<https://learn.microsoft.com/en-us/answers/questions/4706155>

**Apple（原生参考）**
- macOS Mail 永久删除（Mailbox > Erase Deleted Items，Control-点垃圾桶）：<https://discussions.apple.com/thread/256258091>
- macOS Mail 废纸篓行为与自动清除设置：<https://support.apple.com/fr-cf/guide/mail/mlhlp1001/11.0/mac/10.13>
