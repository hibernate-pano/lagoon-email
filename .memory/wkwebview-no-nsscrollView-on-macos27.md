---
name: wkwebview-no-nsscrollView-on-macos27
description: macOS 26/27 的 WKWebView 内部不再有 NSScrollView——DFS 找私有层级测高度必然失败，必须走 evaluateJavaScript（禁页面 JS 不影响该 API）
type: gotcha
---

# macOS 26/27：WKWebView 内部 NSScrollView 没了，测高必须走 `evaluateJavaScript`

**What happened.** Lagoon 正文只显示一行 + 内部滚动条 + 外面大片空白。链路：正文高度靠
`HTMLMessageView.Coordinator` DFS 找 WKWebView 私有 `NSScrollView`、观察 documentView frame
回传 —— 这在 macOS 11–15 一直成立。macOS 27 beta 探针实测：

```
WKWebView → WKFlippedView        ← 没有 NSScrollView，且 FlippedView 无子视图
findScrollView: NIL
evalJS "document.body.scrollHeight" → 1104   ← API 侧 evaluateJavaScript 可用
typeof window.__x → undefined                ← allowsContentJavaScript=false 仍挡页面脚本
```

DFS 永远 nil → 高度恒 0 → 1 秒降级路径生效（80pt 地板 + forwardsScrollWheel=false 恢复内部
滚动）→ 用户看到的正是「一小行 + 滑块 + 空白」。

**How to apply.**
- 测 WKWebView 内容高度：`evaluateJavaScript("Math.max(document.documentElement?.scrollHeight ?? 0, document.body?.scrollHeight ?? 0)")`
  轮询（150ms 防抖 + 250ms 间隔，高度连续 3 次不变即停，~10s 上限）。`allowsContentJavaScript = false`
  只挡页面 `<script>`，不挡这个 API —— 安全姿态不变（探针验证过页面全局保持 undefined）。
- 永远别再依赖 WKWebView 的私有视图层级（`findScrollView` 这类 DFS）做测量；公共 API 才是契约。
- `scrollHeight ≥ viewport height`：回传值写进 `.frame(height:)` 后 viewport 变高，但收敛方向正确
  （不会死锁在小值），短邮件停在 80pt 地板是设计内的 floor。
- 窗口 resize 会改变文档排版高度 → 在 `PassThroughScrollWebView.layout()` 检测宽度变化重开测量轮询，
  否则改窗口大小后外层 frame 过期、正文下半截不可达（外层转发滚轮 = 内容永远够不着）。
- 回归锁：`HTMLMessageViewTests.test_measurementReportsHeightWithoutPrivateScrollView` —— 真载一份
  60 行 HTML、泵 RunLoop 断言高度 > 500。回归这个 bug 它会红。

**Related.** [[swiftui-frame-order-centering-noop]] — 同一个详情页阅读列的另一处布局坑；
[[lagoon-app-nscalendardate-toolbar-crash]] — 同一次 macOS 27 beta 排查会话。
