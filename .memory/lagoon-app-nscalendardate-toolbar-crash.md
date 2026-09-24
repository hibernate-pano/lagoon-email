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

**Related.** [[macos-swiftui-toolbar-overflow-hides-controls]] — 同一层的另一个静默问题族。
