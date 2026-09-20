---
name: sheet-is-its-own-navigation-root
description: sheet 不继承 presenter 的 NavigationStack（NavigationLink 点了不跳），且 List(selection:) 与行 id 类型不匹配会静默吞掉高亮/j-k/Delete
type: gotcha
---

# sheet 是自己的 presentation root；List selection 类型不匹配是静默失效

**What happened.** 两个「点了没反应」的缺陷，都是 SwiftUI 静默失败：

1. `SearchSheet` 里 `List` 内的 `NavigationLink(value:)` + `.navigationDestination(for:)` 挂在顶层 `VStack` 上，
   但整个 sheet **没有任何 `NavigationStack`** —— sheet 是独立 presentation root，不继承调用方的栈。
   唯一那个 `NavigationStack` 写在 destination 闭包**内部**（永不执行），是当初绕坑留下的痕迹。
   结果：搜索出的邮件全都点不动，只在控制台留一句 "no matching navigationDestination"。
2. `BriefingFeedView` 的 `List(selection: $selectedGmailId)` 是 `String?`，而 `ForEach` 的 identity 是
   `BriefingItem.id`（UUID）→ 类型不匹配，selection 永远写不进去。连带 `scrollTo(remoteId)`、
   `onMoveCommand`(j/k)、`onDeleteCommand` 全部失效，而文件头注释还在宣传 j/k 导航。

**Why.** 两处都不是渲染问题，是「修饰符挂在了错误的容器上」：`navigationDestination` 只在栈内有效；
`List` 的 selection 按行 id 匹配，id 类型对不上就静默丢弃——不报错、不警告。

**How to apply.**
- sheet（以及 popover、独立 window）里要用导航，必须自己包一层 `NavigationStack(path:)`；
  确认全文件只有一个栈，`.frame` 放在栈**外**，不要出现双层标题栏。
- `List(selection:)` 的泛型类型必须与行 identity 一致：`NavigationLink(value:)` 的行按需补 `.id(...)`（给 `scrollTo` 用）
  和 `.tag(...)`（给 selection 用），改完必须**真机点一次**——编译通过不代表选中态生效。
- `.id()` 会改变行视图身份；若行动画异常，改走「selection 类型换成 UUID」的路线，而不是删 `.id`。

**Related.** [[macos-swiftui-toolbar-overflow-hides-controls]]
