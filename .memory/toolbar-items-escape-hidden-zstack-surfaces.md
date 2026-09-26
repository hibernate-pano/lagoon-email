---
name: toolbar-items-escape-hidden-zstack-surfaces
description: macOS SwiftUI 中 toolbar 项是 window 级的——ZStack 隐藏面（opacity/disabled/allowsHitTesting 全套）里的 .toolbar 项照样出现在窗口工具栏，双 surface 各推过详情页就出现重复按钮
type: gotcha
---

# toolbar 项逃过隐藏 surface 的全部隐藏修饰

**What happened.** 2026-09-26 浸泡第一天，Jasper 报"右上角有重复的功能按钮"。根因：v2 B1 的
双 surface 常驻（RootView ZStack，opacity(0) + disabled + allowsHitTesting + accessibilityHidden
四件套藏住隐藏面）只对**视图层**生效；`MessageDetailView` 的 `.toolbar` 项（Pin / 回复组 /
归档 / ⋯）挂在 **window 工具栏**上，隐藏面的详情页照样把它的一套按钮插进右上角——两个栈各
推过一次详情就是两套。

**Why.** SwiftUI 在 macOS 上把 pushed view 的 toolbar 项合并进同一个 NSToolbar；opacity 只藏
视图，不撤 toolbar 项。RootView 的注释说"隐藏面 inert（无 hit testing、无 shortcut、VO 隐藏）"，
漏了 toolbar 这个 window 级通道——instrument 不是真空，总有绕过 modifier 的旁路。

**How to apply.**
- 任何"常驻双视图 + opacity 切换"结构，盘点副作用时按 **window/层级的旁路清单** 过一遍：
  toolbar 项、keyboard shortcut（background Button 兜底那种）、NSWindow 委托、focus、
  `.sheet` 的 presentation 状态。
- 本次修法：详情页加 `surfaceVisible`，`.toolbar { if surfaceVisible { toolbarContent } }`；
  两个父 surface 把自己的 `isVisible` 传下去。视图保持挂载，keep-alive 语义不变。
- SearchSheet 里复用的 `MessageDetailView` 用默认值 `true`——sheet 是独立 window，不共享工具栏。
- 改 toolbar 内容会加 churn；toolbar-insert 的 NSCalendarDate 崩溃是 OS 竞态
  （[[lagoon-app-nscalendardate-toolbar-crash]]），churn 只是加重因子，可见性门控值得付这个代价。

**Related.** [[macos-swiftui-toolbar-overflow-hides-controls]] — 同一层：溢出吞按钮是另一族。
