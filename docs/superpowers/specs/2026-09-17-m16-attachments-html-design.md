# M1.6 · Attachments, HTML, Inline Images

**Date:** 2026-09-17
**Status:** Draft for review
**Predecessor:** v0.2.0 (UX feedback discipline, commit `afd9d90`)
**Audience:** Solo founder + AI co-founder

---

## 0. 背景与目标

**现状 (v0.2.0).** Lagoon 邮件正文只有纯文本，附件被显式跳过 (`MIMEParser.swift:141`)，详情页只渲染 `Text(messageBody.text).font(.body).lineSpacing(3)`。一个不能看附件 / 不能看 HTML 的邮件客户端是 demo 级，不是产品级。v0.2.0 spec 把这两块都列为"非目标"(`2026-09-11-imap-qq-provider-design.md:30`)，M1.6 是填这个洞。

**目标 (M1.6).** 用户在详情页能看到：
- 排版后的 HTML 正文（字体、颜色、表格、超链接）
- 邮件的所有附件（含 inline images），可下载到本地
- 整封邮件原始 `.eml` 可导出

**非目标 (M1.6 仍不做).**
- S/MIME、PGP 签名 / 加密
- HTML 内的服务端图像代理（外链 `https://...` 图片不替用户抓）
- 视频 / 音频附件内嵌预览
- 大附件（>25 MB）优化（QQ 邮件本身有限，IMAP fetch 一次性返回）
- 离线缓存（用户决策：每次进详情临时拉，命中后再考虑缓存）

---

## 1. 数据模型

### 1.1 `Attachment`（新）

```swift
public struct Attachment: Codable, Equatable, Sendable, Identifiable {
    public let id: String              // server-side stable id (e.g. "1.2" for IMAP part, "anghhdjs" for Gmail)
    public let filename: String?       // from Content-Disposition filename or Content-Type name
    public let mimeType: String        // "image/png", "application/pdf", ...
    public let size: Int               // bytes (post-transfer-encoding decoded)
    public let contentId: String?      // raw "<image001@example.com>" for cid: inline images
    public let disposition: Disposition

    public enum Disposition: String, Codable, Sendable {
        case attachment   // user should download
        case inline       // referenced by HTML via cid:; usually an image
    }
}
```

`id` 是 server 内部对 part 的稳定标识。对 IMAP 是 part 路径（`1.2.1`），对 Gmail 是 `body.attachmentId`。client 看不到这两个实现细节，server 端在 `GET /api/messages/{remoteId}/attachments/{id}` 路径里用。

### 1.2 `MessageBody` 扩展

```swift
public struct MessageBody: Codable, Equatable, Sendable {
    public let remoteId: String
    public let subject: String?
    public let fromAddress: String
    public let fromName: String?
    public let toAddress: String?
    public let receivedAt: Date
    public let text: String           // 现有：纯文本，最长 50 KB（防止恶意超大正文）
    public let html: String?          // 新：HTML 原文，server 已经在阶段 6 limit 5 MB
    public let attachments: [Attachment]   // 新：附件元数据列表
    public let hasMore: Bool          // 新：true 表示 text/html 超过截断
}
```

`hasMore` 让 client 知道"这是部分内容"，避免误以为整封邮件都读到了。`text` / `html` 截断阈值在 server 端是 hard cap，client 不参与。

### 1.3 截断策略

| 字段 | 阈值 | 超出行为 |
|---|---|---|
| `text` | 50 KB | 截断到 50 KB，加 `…[truncated, original N KB]`，`hasMore = true` |
| `html` | 5 MB | 截断到 5 MB，`hasMore = true`；client 决定是否改用下载 .eml |
| attachments list | 不截断 | 列表本身可以很长（每条 ~200B） |
| attachment binary | 25 MB | 超过 25 MB 的附件 server 返回 413，client 提示"过大" |

---

## 2. 服务端

### 2.1 MIME 提取改造

`Sources/LagoonServer/IMAP/MIMEParser.swift`：

- 新增 `public static func parse(message: Data) -> ParsedMessage`
- `ParsedMessage` = `{ text, html, attachments: [AttachmentPart] }`
- `AttachmentPart` 包含 `id = "1.2"`、`mimeType`、`filename`、`contentId`、`disposition`、`decoded: Data`
- `parseContentType` 已存在，复用
- 旧 `plainText(from:)` 调用 `parse` 然后只取 `.text`，保持向后兼容

递归规则：
- `multipart/alternative` → 偏好 `text/plain`，同时记下 `text/html`（不丢弃）
- `multipart/mixed`、`multipart/related` → 递归各 part，把 `text/*` 之外的 part 当作 attachment
- `multipart/related` 内的 `Content-ID: <xxx>` 是 `cid:xxx` 引用，HTML 里的 `cid:xxx` 应该能在同一 multipart 树里找到对应 part
- `Content-Disposition: attachment` → 强制当 attachment（即使 mimeType 是 `image/*`）
- `Content-Disposition: inline` 或缺省 → 看 mimeType；`image/*` 当 inline（可被 HTML 引用），其它当 attachment

附件 id 编码（IMAP）：`multipart/related` 的 part 路径按 `IMAP ENVELOPE` 的相对位置编为 `1.2.1` 这种点分字符串，跟 IMAP `BODY[<id>]` 取子 part 的协议兼容。

### 2.2 Gmail 提取改造

`Sources/LagoonServer/Gmail/GmailBodyExtractor.swift`：

- 现在已经递归遍历 `payload.parts`，把 `text/plain` / `text/html` 分别抽出
- 改造：递归同时收集 `body.attachmentId` 不为空的 part 当 attachment
- filename 来自 `part.filename`
- contentId 来自 `part.headers["Content-ID"]`（如果有）
- disposition 来自 `part.headers["Content-Disposition"]`

附件 id 直接用 `body.attachmentId`（Gmail 自己的 id，server 转发给 client 即可）。

### 2.3 Provider 改造

`IMAPProvider.fetchBody` 改返回 `MessageBody`（不只是 String）：
- 调 `MIMEParser.parse(message:)` 拿 `(text, html, attachments)`
- 解析出 from/subject/to/receivedAt 时已经做了，复用
- 把 IMAP `AttachmentPart.id` 映射成 `Attachment.id` 暴露给 client

`GmailProvider.fetchBody` 类似。

### 2.4 新增路由

`GET /api/messages/{remoteId}/attachments/{attachmentId}`

- 返回二进制字节流，Content-Type 为 attachment.mimeType
- Content-Disposition: `attachment; filename="<encoded filename>"`
- 大小 > 25 MB → 413 Payload Too Large
- IMAP：拿 `MessageStore` 找到 stable id，重新拉 `BODY[]`，本地解析找 part `1.2.x` 提取，base64 解码 → bytes
- Gmail：调 `users.messages.attachments.get?messageId=…&id=…` 拿 data
- Auth：跟现有 `/api/messages/...` 一样，靠 `accountId` 查询参数

`GET /api/messages/{remoteId}/raw.eml`

- 返回完整原始邮件字节流
- Content-Type: `message/rfc822`
- Content-Disposition: `attachment; filename="<subject>.eml"`
- IMAP：直接返回 `client.fetchFullBody(uid:)` 的结果
- Gmail：调 `users.messages.get?format=raw`，base64 解码

### 2.5 路由注册

在 `Sources/LagoonServer/Routes/MessageRoutes.swift` 加：
```swift
route.get("/api/messages/:remoteId/attachments/:attachmentId", use: downloadAttachment)
route.get("/api/messages/:remoteId/raw.eml", use: downloadRawMessage)
```

---

## 3. 客户端

### 3.1 数据模型（同步 server）

`Sources/LagoonKit/Briefing.swift` 的 `MessageBody` 加 `html`、`attachments`、`hasMore` 字段。

### 3.2 `MessageDetailView` 改造

详情页正文渲染策略（按顺序）：

1. 如果 `attachments` 里有 inline 图（`disposition == .inline` 且 `mimeType` 起始是 `image/`），把 `contentId` 收下来等会儿注入 HTML
2. 如果 `html != nil` 且非空：用 `WKWebView` 渲染（见 §3.3）
3. 否则用现在的方式渲染 `text`（保证降级路径仍然干净）
4. 附件列表渲染在正文下方：filename、mimeType icon、`size` (human-readable: KB/MB)、`下载` 按钮
5. 顶部 toolbar 加 `下载 .eml` 按钮（侧边或更多菜单里）

下载按钮：
- 调 `GET /api/messages/{remoteId}/attachments/{aid}` 拿 Data
- 用 `NSSavePanel` 弹原生保存对话框，suggested filename = `attachment.filename`
- 用户选路径后写文件

### 3.3 WKWebView 渲染

`Sources/Lagoon/Views/HTMLMessageView.swift`（新文件）：

```swift
struct HTMLMessageView: NSViewRepresentable {
    let html: String
    let attachmentsByCid: [String: Data]   // cid:xxx (without <>) -> image bytes

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false  // 邮件不该跑 JS
        // 其它安全设置：禁用 plug-ins、自动播放、跨域等
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let resolvedHTML = resolveCidReferences(in: html, with: attachmentsByCid)
        webView.loadHTMLString(resolvedHTML, baseURL: nil)   // baseURL=nil → 不允许外链
    }

    /// 把 <img src="cid:xxx"> 替换成 <img src="data:image/png;base64,...">
    /// cid 内容来自 attachmentsByCid（已 fetch 的 inline images）
    private func resolveCidReferences(in html: String, with map: [String: Data]) -> String {
        // regex: src="cid:([^"]+)"
        // 对每个匹配，从 map[matched] 拿 Data，转 base64，组装 data URL
        // 没找到对应附件的 cid: 引用 → 保留原文（浏览器会显示 broken image）
    }
}
```

安全要点：
- `allowsContentJavaScript = false`（邮件里不应该跑 JS）
- `baseURL = nil`（无外链，相对路径解析为 about:blank）
- 不用 `loadHTMLString(baseURL:)` + 任意 URL，**baseURL 必须 nil**
- 不挂 `WKScriptMessageHandler`，避免 JS bridge
- 不挂 `WKURLSchemeHandler`，拦截 scheme 是过度设计
- HTML 里 `<a href="javascript:...">` 不会被执行（JS 关闭），但要确保不会因为某些边角被点开。可以拦截 `navigationAction` 但本期不做（M1.7 候选）

### 3.4 inline images 加载策略

HTML 渲染需要 inline image 字节。`MessageDetailView.loadBody()` 流程：

1. 拿 `MessageBody`（含 attachments 元数据）
2. 同步：找出所有 `disposition == .inline` 且 `mimeType` 起始 `image/` 的 attachment
3. 并发 fetch 它们（最多 5 个并发，避免瞬时打爆 IMAP）
4. 收集 `[String: Data]`（key = contentId 去 `<>` 后的小写）
5. 把 `attachmentsByCid` 喂给 `HTMLMessageView`

非 image 的 inline attachment（罕见，比如 inline PDF）本期不内嵌；仍然出现在附件列表里，用户手动下载。

---

## 4. 测试

### 4.1 Server 单元测试

`Tests/LagoonServerTests/MIMEParserTests.swift`：

- `test_parse_textPlainMultipart_returnsTextAndEmptyHtml` —— 现有
- 新：`test_parse_multipartMixed_textAndPdfAttachment` —— text + PDF 附件
- 新：`test_parse_multipartRelated_inlineImage_cidMatchesContentId`
- 新：`test_parse_attachmentDisposition_evenWithImageMimeType_landsInAttachments`
- 新：`test_parse_textTruncatesAt50KB`（构造大正文）
- 新：`test_parse_htmlCapturesUpTo5MB`（构造大 HTML）

`Tests/LagoonServerTests/GmailBodyExtractorTests.swift`（如果不存在则新建）：

- `test_gmailExtract_textAndHtml_collectedSeparately`
- `test_gmailExtract_attachmentWithAttachmentId_listed`

`Tests/LagoonServerTests/RouteTests.swift`：

- 新：`test_route_attachments_returnsBytes` —— mock provider 返回 attachment，验证 status / content-type / content-disposition
- 新：`test_route_attachments_oversize_returns413`
- 新：`test_route_rawEml_returnsMessageRfc822`

### 4.2 Client 单元测试

`Tests/LagoonTests/HTMLMessageViewTests.swift`（新）：

- `test_resolveCid_replacesImgSrcWithDataUrl`
- `test_resolveCid_missingAttachment_keepsOriginal`（broken image 是预期）
- `test_resolveCid_caseInsensitive`（cid 引用和 Content-ID 可能有大小写差异）

### 4.3 手工冒烟（spec §7.2 增量）

| # | 操作 | 期望 |
|---|---|---|
| M-1 | 打开一封纯文本邮件 | 跟 v0.2.0 一样，Text view 显示 |
| M-2 | 打开一封带格式的 HTML 邮件 | WKWebView 渲染，颜色 / 表格 / 链接可见；点链接不响应（baseURL nil） |
| M-3 | 打开一封带 1 张内嵌 logo 的营销邮件 | logo 显示（cid: 已解析为 data URL） |
| M-4 | 打开一封带 PDF 附件的邮件 | 附件列表显示 PDF icon + filename + size + 下载按钮；点下载保存到本地 |
| M-5 | 打开一封 .eml 下载的邮件 | 下载按钮导出 .eml，QQ 邮箱网页版 reimport 看到内容一致 |
| M-6 | 打开一封纯附件邮件（正文为空） | "此邮件没有正文" + 附件列表 |
| M-7 | 故意构造大正文（5 MB+ HTML） | hasMore = true，UI 显示"内容已截断，下载 .eml 看完整"提示 |

---

## 5. 范围 / 风险

**风险**：
- IMAP 单附件 25 MB 走 base64 → JSON 太慢，**附件路由必须返回二进制，不是 JSON 包装的 base64**（已写明）
- WKWebView 内存模型：每封邮件一个 WKWebView 实例，导航时销毁；不要 retain
- 大 HTML（5 MB）WKWebView 解析可能慢，UI 加 ProgressView 提示
- 邮件里的 `<a href="http://...">` 点击：baseURL nil 会让外链点击不响应（点不动）—— 这是当前决策（v0.2.0 之后优化）
- `Content-ID` 的大小写 / 尖括号处理：服务器返回时保留原样，client 在匹配时统一小写 + 去 `<>`

**显式延后到 M1.7+**：
- 外链图片代理
- HTML 链接点击打开 Safari
- S/MIME、PGP
- 离线缓存
- 多附件并发下载的进度条（v0.2.0 模式，ProgressView 内嵌）
- HTML 内嵌视频 / 音频
- Eml 导出加压缩 zip 多个

---

## 6. 验收 DoD

- [ ] M-1 到 M-7 全部手工通过（真实 QQ 账号）
- [ ] `swift test` 全绿，含新测试 ≥ 6 个
- [ ] 旧 `MessageBody` JSON 解析向后兼容（client 端 `attachments` / `html` 默认 `[]` / `nil`，`hasMore` 默认 `false`）
- [ ] 真实 QQ 跑 7 天无 P0/P1
- [ ] 截断字段在 fixture 里覆盖 1 次以上
- [ ] Lint 脚本仍然全绿
- [ ] M1.6 spec 完成后写实施 plan（沿用 `2026-09-XX-imap-qq-provider.md` 模板）
