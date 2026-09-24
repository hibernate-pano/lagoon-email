---
name: swiftui-frame-order-centering-noop
description: .frame(maxWidth: 900, alignment: .center) 无法把 900 宽的列居中——必须外层 fill+center、内层 cap，顺序反了 alignment 恒为 no-op
type: gotcha
---

# SwiftUI：居中 frame 的顺序反了就是 no-op

**What happened.** 详情页阅读列 900pt 宽，在宽窗下全部贴左、右侧一大片空白。第一版修复把
`.frame(maxWidth: 900, alignment: .leading)` 改成 `.alignment: .center`，看着像修好了，用户仍
看不到变化。独立 reviewer 用**帧探针**（真实窗口 + GeometryReader 读 frame）实测：新旧版
逐像素一致，列仍在 `x=0`。

**Why.** `alignment` 只决定**子视图在 frame 盒子内怎么摆**，不移动 frame 盒子本身。盒子宽
900pt，由外层 ScrollView 放在文档原点（=靠左）。而盒子的子视图是 `.frame(maxWidth: .infinity)`
——永远填满盒子，于是「在盒子里居中一个填满盒子的东西」= 恒等于盒子原来的位置。**ImageRenderer
离屏像素对比也测不出这个 bug**（新旧渲染结果完全相同），必须用真实窗口的 GeometryReader 探针。

**How to apply.**
- 正确结构（已实测 x=(W−900)/2 生效）：**内层先 cap、外层再 fill+center**
  ```swift
  .frame(maxWidth: 900)                                        // cap：盒子本身收窄
  .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top) // fill：填满窗口并把盒子摆中间
  ```
  `.top` = 水平居中 + 垂直贴顶（`Alignment.top` 的 x 是 0.5），一个 modifier 同时解决两个方向。
- 写完布局改动后问一句：**这个 frame 在移动自己，还是在移动它的子视图？** 绝大多数「不居中」
  的报障都是这个误解。
- 验证手段：真实窗口 + GeometryReader 读 frame.origin.x / width，窗口宽度取 1400 这类明显
  超出上限的值。离屏渲染对比对这类「位置」改动是无效的。

**Related.** [[macos-swiftui-toolbar-overflow-hides-controls]] — 同一个 macOS 布局层的
「尺寸协商静默失败」家族：那边是 overflow 吞控件，这边是 frame 顺序吃掉 alignment。
