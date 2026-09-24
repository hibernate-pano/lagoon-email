---
name: ssrf-guard-must-revalidate-redirects
description: SSRF 防护只查初始 URL 不够——URLSession 默认跟随重定向，每一跳都必须重新过 isSafe，否则公开链接 302 即可打内网
type: gotcha
---

# SSRF 守卫必须覆盖重定向的每一跳，而不只是初始 URL

**What happened.** 一键退订的审查（reviewer P0）发现：`UnsubscribeScanner.isSafe(url:)`
只在发起请求前检查目标 URL，而 `hitUnsubscribe` 用 `URLSession.shared` —— 它**默认跟随
HTTP 重定向且不回调任何校验**。攻击者控制的正文链接只要指向自己的公网服务器并 302 到
`http://127.0.0.1:…` 或 `http://169.254.169.254/…`，守卫形同虚设。头部链接同样受影响
（发件人可投毒 List-Unsubscribe）。

**How to apply.**
- 任何「校验后用 URLSession 发请求」的模式，都要用带 delegate 的自定义 session 实现
  `urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:)`：
  对 `request.url` 再跑一次 `isSafe`；不安全时 `task.cancel()` **并** `completionHandler(nil)`。
  只传 `completionHandler(nil)` 是错的 —— 那会把 3xx 当最终响应，而本代码把 200..<400
  计为成功，等于把「被拦截」记成「退订成功」。
- DNS 只在决策时解析一次，连接时仍会重新解析 —— 重绑定窗口存在（本项目服务端仅绑定
  loopback，作为已知上限记录在 `UnsubscribeScanner.isSafe` 注释里，未做连接级 IP 固定）。
- 回归锁：`UnsubscribeRouteTests`（6 例，离线：出站 HTTP 经 `ActionsRoutes.hitUnsubscribeProbe`
  注入）+ `UnsubscribeScannerTests`（IP 分类全谱）。测试夹具用**字面公网 IP**（8.8.8.8 等），
  因为守卫要解析 DNS，`xxx.example.com` 子域名不解析 → 会被正确拒绝导致假失败。

**Related.** [[guardrail-raw-string-tokenizer-desync]] —— 同一次审查会话；教训同源：
信任边界上的检查必须覆盖全部执行路径，而不是只有入口。
