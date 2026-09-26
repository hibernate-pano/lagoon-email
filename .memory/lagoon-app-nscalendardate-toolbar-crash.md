---
name: lagoon-app-nscalendardate-toolbar-crash
description: Lagoon.app SIGABRT = macOS 27 beta SwiftUI toolbar 桥反序列化 NSCalendarDate 崩溃——磁盘状态干净、竞态不可复现，重建+压测即止
type: gotcha
---

# Lagoon.app 的 `NSCalendarDate` / `NSToolbar` 崩溃是 OS 级竞态，不是应用状态污染

**What happened.** 2026-09-24 两次 SIGABRT（10:48、11:00），崩溃栈完全一致：

```
-[NSCalendarDate initWithCoder:]  ← exception
-[NSToolbar _insertNewItemWithItemIdentifier:propertyListRepresentation:...]
closure in AppKitToolbarStrategy.updateToolbar()
ToolbarBridge.preferencesDidChange ← NSHostingView.preferencesDidChange
```

ObjC 异常未捕获 → AppKit `_crashOnException` → abort。触发点是 `preferencesDidChange`
（任何 UserDefaults 写入，包括窗口 frame autosave）。排查结论：

- **磁盘是干净的**：两个偏好域（`com.lagoon.email.plist` = bundle 启动；`Lagoon.plist` =
  `swift run` 裸进程按进程名写的旧域）都只有 `NSWindow Frame` 几何串和 `lagoon.language`，
  无 toolbar 持久化、无 NSCalendarDate；无 savedState 目录。
- **竞态不可复现**：同一二进制一次撑了 15 小时、一次 90 秒崩；主动 `defaults write` 触发
  toolbar 重建 + 25 轮压测 + 重新 open 全部存活。
- 外部同栈案例：github.com/kmg/steno commit `27ca8e0` 记录了一模一样的栈，定性为
  "SwiftUI ToolbarBridge 序列化 bug"，防御手段是启动时一次性清 toolbar state。

**How to apply.**
- 见到这个栈先查两点：`~/Library/Logs/DiagnosticReports/Lagoon-*.ips` 的
  `lastExceptionBacktrace`，以及偏好域里有没有 toolbar 键 —— 没有就别往"清状态"方向修，
  那是死代码；重建 `dist/Lagoon.app`（`scripts/build-app.sh`）+ prefs 写入压测即可。
- 旧 `dist` 二进制会落后于 HEAD（本次崩溃跑的是 9/23 19:56 的构建），崩溃时先核对
  `stat dist/Lagoon.app/Contents/MacOS/Lagoon` 与最新 commit 的时间。
- 若复发：降低 toolbar 内容 churn（RootView 账号菜单 label 随轮询刷新变化）或提 Feedback；
  steno 的"启动一次性清状态"仅在磁盘确有 toolbar 键时才有意义。

**复发记录（2026-09-27 00:01，第三次）。** v2.1.1 二进制（23:59 启动，2 分 17 秒后崩），
触发路径 = 点击邮件 → 详情 push 插入 toolbar 项 → `AppKitToolbarStrategy.updateToolbar()`
→ NSCalendarDate decode 抛异常。偏好域复查仍无 toolbar 键（只有 window frame /
lagoon.language / lagoon.grouping）——竞态而非必现。与 9/24 的两次同栈。要点：
- 崩溃点在 AppKit 的 `_insertNewItem`（插入新项），不是既有项的内容更新——**push/pop
  详情页的"插入/移除 5 项"是最大的开彩票动作**。
- 彻底规避 = 详情动作条移出窗口工具栏（in-view action bar，零 churn）；折中 = 项常驻
  只切 enabled（但与 surfaceVisible 防重复门控冲突，隐藏面会露出灰按钮）。均为 UX 决策，
  待 founder 拍板，不要擅自重构。
- v2.1.1 新增的 @AppStorage（lagoon.grouping/unreadOnly）只在切换时写一次 defaults，
  与常驻轮询相比不是主要输入源，别错怪。

**处置（2026-09-27，v2.1.2 c291931，founder 拍板"顺畅体验第一"）。** 详情页动作整体
移出窗口工具栏，改为阅读视图内 `safeAreaInset(top)` 常驻动作条（动作/快捷键/⋯菜单
原样保留，Archive & Next 升级 borderedProminent）。push/pop 详情对窗口 toolbar 零
增删 → `_insertNewItem` 路径永不触达，竞态入口移除。连带收益：v2.0.7 的 surfaceVisible
门控（防隐藏面 toolbar 泄漏）连同参数一起删除——没有项可泄漏了。剩余 toolbar 项只有
RootView 常驻那组，数量恒定不增删。若 OS 崩溃仍再现于其他 toolbar 更新路径，下一步
是给 Apple 提 Feedback（栈已留档）。

**Related.** [[macos-swiftui-toolbar-overflow-hides-controls]] — 同一层的另一个静默问题族。
