---
name: macos-swiftui-toolbar-overflow-hides-controls
description: 用户报「按钮/下拉框显示不出来」时先查 NSToolbar 溢出——macOS 是溢出进 » 而不是压缩，且无宽度上限的 Text 会独占预算
type: gotcha
---

# macOS 上「控件显示不出来」多半是 toolbar 溢出，不是渲染失败

**What happened.** 用户反复反馈「很多按钮、下拉框无法正常显示」。三个独立侦察一致指向同一机理：

1. `WindowGroup` 没有 `.defaultSize`，且用的是 `.windowResizability(.contentMinSize)` → 窗口最小尺寸由**内容**决定（720pt），
   而 toolbar 需要 ~755pt。AppKit 按「预算不够就把尾部 item 收进 `»` 溢出菜单」处理，**不压缩、不报 warning**。
2. 账号 Menu 的 label 里是裸 `Text(email)`，intrinsic 宽度无上限 → 它独占预算，把后面的 segmented Picker
   和语言 `.menu` Picker 全部挤进 `»`。用户看到的就是「下拉框不见了」。
3. Picker 一旦进溢出菜单就被拆成若干菜单项，作为控件直接不存在。

**Why.** 这是尺寸协商语义，不是渲染 bug：`.toolbar` 的 item 变成 `NSToolbarItem`，宽度取 fitting size，超预算即溢出。
SwiftUI 全程静默——没有 warning、没有 placeholder，所以排查时极易误判成「控件没写对」。

**How to apply.**
- 一条 toolbar 上放 4 个以上 item 时，给 scene 显式 `.defaultSize(...)`；别让内容最小尺寸决定首启窗口。
- 任何进 toolbar 的 `Text` 都要有宽度上限：`.lineLimit(1).truncationMode(.middle).frame(maxWidth: N, alignment: .leading)`。
- Picker 在 toolbar 里要 `.fixedSize()`（防被压缩成空），但**不要**为此加 `.labelsHidden()`——用 `.accessibilityLabel(...)` 保名。
- 排查手法：把窗口拖到内容最小宽度，数 `»` 里躺了几项；或直接对比未设 `defaultSize` 前后的截图。

**Related.** [[sheet-is-its-own-navigation-root]]
