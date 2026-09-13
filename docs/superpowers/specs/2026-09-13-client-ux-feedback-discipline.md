# 客户端 UX 反馈纪律规约

**日期**：2026-09-13
**状态**：Draft，待 review
**所属里程碑**：M1.5 后（QQ 邮箱接入完成后的体验收口）

---

## 1. 背景与目标

### 1.1 现状

M1.5 把 QQ 邮箱接入闭环跑通后，从使用者角度看仍有大量「点了没反应」「被骗」「看不到进度」三类体验问题。按痛苦度排序 top 5：

1. `MessageDetailView.archiveAndAdvance` / `unsubscribe` / `overrideClassification` 三个 catch 为空 (`MessageDetailView.swift:429,444,454`)，按 ⌘E/退订/改分组无任何 UI 反馈。
2. 首启简报空态文案 `tapGmailToSync` (`L10n.swift:290`) 写死 "点击 Gmail"，但简报页面无 Gmail 按钮可点；用户连的是 QQ 邮箱。
3. 健康横幅 (`RootView.swift:85-125`) 只对 `needsReconnect` 状态给按钮，`degraded`/`error` 只显示一行字；恢复时横幅瞬间消失无确认。
4. OAuth/Gmail tab 按下 "连接 Gmail" 后若浏览器未拉起 (`ConnectView.swift:142-153`)，按钮被 disable 但无任何错误提示。
5. `APIClient.fetchBriefing` (`APIClient.swift:166`) 无 timeout，LLM 慢时简报转菊花可挂 22s+。

完整问题清单参见 brainstorming chat 阶段调研（共 18 个严重 + 几十个细节）。

### 1.2 目标

完成本 spec 后，使用者在以下场景下**不会再遇到"按了没反应"或"被骗"**：

- 在消息详情按 ⌘E / 退订 / 改分组 / 标已读
- 在简报/列表/搜索任意位置遇到失败
- 在任意视图切账号、刷新、同步异常时

具体可测量目标：

- `git grep "catch { }" Sources/Lagoon/Views/` 命中 0（白名单除外）
- `Sources/Lagoon/Localization/L10n.swift` 不再含 "Gmail" 字样的 user-facing 文案（除 `pushToGmailDrafts` 这种 Gmail-only feature）
- `Sources/Lagoon/Services/APIClient.swift` 所有 fetch 方法显式标注 timeout 档位

### 1.3 不在范围

以下问题**本次不做**，留待后续迭代：

- 进入详情自动 markRead（无法"未读预览"）
- Composer sheet draft 自动暂存
- Summarize/Draft failed 后按钮永久 disable（只做 cooldown）
- 账号菜单 8×8 圆点过小
- 切换账号加 loading 反馈
- QQ 授权码自动 trim 后重试
- M1.5c 写路径 send 路由尚未完成（详见 `docs/superpowers/plans/2026-09-11-imap-qq-provider.md` 缺项）

---

## 2. 错误反馈契约

### 2.1 `ErrorBanner` 数据模型

新增 `Sources/Lagoon/Views/NoticeBanner.swift`：

```swift
public struct ErrorBanner: Identifiable, Equatable {
    public enum Severity: Equatable { case info, warning, error }
    public let id = UUID()
    public let severity: Severity
    public let title: LocalizedStringKey
    public let detail: LocalizedStringKey?
    public let actionLabel: LocalizedStringKey?
    public let action: (() async -> Void)?
    public let dismissible: Bool   // 默认 true
    public let autoDismissAfter: Duration?   // nil = 不自动消失
}
```

`Equatable` 实现忽略 `action` 闭包（用 `id` 判断相等）。

### 2.2 `NoticeBanner` 组件 + modifier

同文件：

```swift
struct NoticeBannerView: View {
    let banner: ErrorBanner
    let onDismiss: () -> Void
    @State private var actionInFlight = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: severityIcon).foregroundStyle(severityColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title).font(.callout).bold()
                if let detail = banner.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let label = banner.actionLabel, let action = banner.action {
                Button {
                    Task {
                        actionInFlight = true
                        await action()
                        actionInFlight = false
                    }
                } label: {
                    if actionInFlight { ProgressView().controlSize(.small) }
                    else { Text(label) }
                }
                .disabled(actionInFlight)
                .controlSize(.small)
            }
            if banner.dismissible {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(l10n.dismiss)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minHeight: 36, maxHeight: 36)
        .background(severityColor.opacity(0.12))
        .overlay(Rectangle().fill(severityColor).frame(width: 3), alignment: .leading)
    }
}

struct NoticeBannerModifier: ViewModifier {
    @Binding var banner: ErrorBanner?
    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            if let banner {
                NoticeBannerView(banner: banner, onDismiss: { self.banner = nil })
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            content
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: banner?.id)
        .onChange(of: banner?.autoDismissAfter) { _, duration in
            guard let duration else { return }
            Task {
                try? await Task.sleep(for: duration)
                withAnimation { self.banner = nil }
            }
        }
    }
}

extension View {
    public func noticeBanner(_ banner: Binding<ErrorBanner?>) -> some View {
        modifier(NoticeBannerModifier(banner: banner))
    }
}
```

### 2.3 `ErrorCenter` 全局错误报告

新增 `Sources/Lagoon/Services/ErrorCenter.swift`：

```swift
@MainActor
public final class ErrorCenter: ObservableObject {
    public static let shared = ErrorCenter()
    @Published public var banner: ErrorBanner?
    public func report(_ b: ErrorBanner) {
        self.banner = b
    }
    private init() {}
}
```

`RootView` 顶层套 `.noticeBanner($ErrorCenter.shared.banner)`（@ObservedObject 包装）。

### 2.4 Invariant

| 编号 | 规则 |
|---|---|
| INV-1 | `banner == nil` 时 modifier 渲染零高度（不挤压内容） |
| INV-2 | 默认 `dismissible = true`；`autoDismissAfter` 只用于短暂提示（sentNotice 等），**不用于**用户可能需要读的操作失败 |
| INV-3 | `detail` 不可为空，必须说明「什么失败」+ 「为什么」 |
| INV-4 | 可重试错误（网络错、5xx、timeout）必须带 `actionLabel = l10n.retry` |
| INV-5 | 不可重试错误（archive-unavailable 等）不能带 retry，必须带 help 链接 |
| INV-6 | 同一时刻全局只显示一个 banner（新 banner 顶替旧的） |
| INV-7 | banner 高度固定 36pt（避免 detail 长文本拉爆） |
| INV-8 | banner 出现后焦点不抢（不触发 `@FocusState`） |
| INV-9 | 按 Esc 关闭当前 banner（前提 banner 是 first responder） |

### 2.5 成功反馈走 `SuccessNotice`

不复用 `ErrorBanner(severity:.info)`，避免使用者误以为有问题。`SuccessNotice` 同样组件但：

- 无 `severity` 字段
- 默认 `autoDismissAfter = 4s`
- 无 action 按钮（成功不需要重试）
- 视觉为绿色左边条

实现：同 `NoticeBannerView` 第二个 case，加 `enum BannerKind { case error(ErrorBanner), success(LocalizedStringKey, detail: LocalizedStringKey?) }`。

---

## 3. L10n 改名与新增

### 3.1 key 内容修改（保留 key 名）

| key | 行 | 原 zh | 原 en | 改 zh | 改 en |
|---|---|---|---|---|---|
| `inboxZero` | L10n:289 | 收件箱已清空 🎉 | Inbox zero 🎉 | 收件箱已清空 | Inbox zero |
| `tapGmailToSync` | L10n:290 | 点击 Gmail 让 Lagoon 开始同步。 | Connect Gmail to start syncing. | 添加一个邮箱账号，让 Lagoon 开始同步。 | Add an email account to start syncing with Lagoon. |
| `connectToRead` | L10n:104 | Connect a Gmail account to start reading. | Connect a Gmail account to start reading. | 添加邮箱账号即可开始阅读邮件。 | Add an email account to start reading. |

### 3.2 新增 key

| key | zh | en |
|---|---|---|
| `moreActions` | 更多操作 | More actions |
| `retry` | 重试 | Retry |
| `dismiss` | 关闭 | Dismiss |
| `syncRecovered` | 同步已恢复 | Sync recovered |
| `archiveFailedTitle` | 归档失败 | Archive failed |
| `archiveFailedDetail` | 归档未完成，请重试或检查网络。 | Archive didn't complete — retry or check your network. |
| `markReadFailedTitle` | 标记已读失败 | Couldn't mark as read |
| `markReadFailedDetail` | 标记已读失败，请重试。 | Mark-as-read didn't complete — retry. |
| `unsubscribeFailedTitle` | 退订请求未完成 | Unsubscribe didn't complete |
| `unsubscribeFailedDetail` | 请到原邮件里手动退订，或稍后重试。 | Try again or unsubscribe from the original email. |
| `overrideGroupFailedTitle` | 分组调整未记录 | Group preference wasn't saved |
| `overrideGroupFailedDetail` | 请重试，或检查网络。 | Retry or check your network. |
| `searchFailedTitle` | 搜索失败 | Search failed |
| `searchFailedDetail` | 请检查网络后重试。 | Check your network and retry. |
| `undoFailedTitle` | 撤销失败 | Undo failed |
| `undoFailedDetail` | 操作可能已完成，请刷新确认。 | The action may have already completed — refresh to verify. |
| `openOriginal` | 打开原邮件 | Open original email |
| `briefingTimeoutTitle` | 简报生成较慢 | Briefing is taking longer than usual |
| `briefingTimeoutDetail` | 已自动重试一次仍未完成，请检查网络。 | One auto-retry didn't complete — check your network. |
| `pushToGmailDrafts` | 保存到 Gmail 草稿 | Save to Gmail drafts |
| `qqEmail` | 邮箱地址 | Email address |
| `qqAuthCode` | 授权码 | Authorization code |
| `qqAuthCodeHelp` | 在 QQ 邮箱 → 设置 → 账户 → POP3/IMAP 服务 → 开启 → 短信验证 → 生成授权码 | In QQ Mail: Settings → Account → POP3/IMAP service → Enable → SMS verify → Generate code |
| `emptyInboxZero` | 邮箱是空的 | Inbox is empty |
| `syncingFirstTime` | 首次同步中…（已收到 \(count) 封） | First sync in progress… (got \(count) so far) |
| `healthDegradedDetail` | 同步不稳定：\(reason) | Sync is unstable: \(reason) |
| `healthErrorDetail` | 同步失败：\(reason) | Sync failed: \(reason) |
| `healthReconnectDetail` | 授权码错误或已失效：\(reason) | Authorization code is invalid or expired: \(reason) |
| `viewDetails` | 查看详情 | View details |
| `reconnect` | 重新连接 | Reconnect |
| `lastSyncAt` | 上次同步 | Last sync |
| `lastError` | 最后错误 | Last error |
| `capabilities` | 能力 | Capabilities |
| `idleSupported` | IDLE 推送 | IDLE push |
| `moveSupported` | MOVE 归档 | MOVE archive |
| `archiveFolderName` | 归档目录 | Archive folder |

### 3.3 `l10n.refresh` 重新分配

`l10n.refresh` 当前引用处（实施前需全仓搜一遍确认）：
- `MessageDetailView.swift:186`（菜单 label —— 错的）

实施步骤：
1. 全仓 `grep -rn "l10n.refresh\b" Sources/` 列出所有引用
2. `MessageDetailView.swift:186` 改为 `l10n.moreActions`
3. 真实 refresh 按钮（如 `BriefingFeedView.swift:78` 头部刷新按钮）保持 `l10n.refresh`
4. 如有遗漏引用，统一改 `l10n.moreActions`

### 3.4 `DraftPickerSheet` 走 L10n + provider 门控

`Sources/Lagoon/Views/DraftPickerSheet.swift:37`：
- 当前：`Toggle("存到 Gmail Drafts", isOn: $pushToGmail)`
- 改为：`Toggle(l10n.pushToGmailDrafts, isOn: $pushToGmail)`
- **门控**：当 `account.provider != .gmail` 时，**整个 Toggle 不渲染**（QQ 账号无 Gmail draft 概念）

### 3.5 `ConnectView` 字段标题化

`Sources/Lagoon/Views/ConnectView.swift:160-167`：
- 两个 `TextField` 上方各加一个 `Text(l10n.qqEmail)` / `Text(l10n.qqAuthCode)` label
- 保留 placeholder
- `qqAuthCode` 字段右侧加 ⓘ `help` button，点击弹 sheet 显示 `l10n.qqAuthCodeHelp` + 跳链接按钮（指向 `docs/使用说明.md`）

---

## 4. RootView 健康横幅

### 4.1 `SyncHealthViewState` 模型

新增 `Sources/LagoonKit/SyncHealthViewState.swift`：

```swift
public enum SyncHealthViewState: Equatable {
    case ok
    case syncing
    case degraded(reason: String)
    case error(reason: String)
    case needsReconnect(reason: String)

    public static func from(_ health: SyncHealth, lastSyncAt: Date?) -> SyncHealthViewState {
        switch health.status {
        case .ok where lastSyncAt == nil: return .syncing
        case .ok: return .ok
        case .degraded: return .degraded(reason: health.lastError ?? "—")
        case .error: return .error(reason: health.lastError ?? "—")
        case .needsReconnect: return .needsReconnect(reason: health.lastError ?? "—")
        }
    }
}
```

### 4.2 视觉与按钮

复用 §2.2 `NoticeBanner`，按 state 映射 severity + action：

| state | severity | title | action |
|---|---|---|---|
| `ok` | — | — | —（不显示） |
| `syncing` | info | l10n.syncingFirstTime | 仅 ✕ |
| `degraded` | warning | l10n.healthDegradedDetail | 重试、查看详情、✕ |
| `error` | error | l10n.healthErrorDetail | 重试、查看详情、✕ |
| `needsReconnect` | error + 边框加粗 | l10n.healthReconnectDetail | **重新连接**（打开 ConnectView 预填 email）、查看详情、✕ |

### 4.3 行为契约

| 编号 | 规则 |
|---|---|
| HEALTH-1 | `ok` 状态完全不渲染 banner |
| HEALTH-2 | 关闭 `syncing` banner 后，下次 `directory.refresh()` 仍会重新出现，直到 `lastSyncAt != nil` |
| HEALTH-3 | `degraded`/`error` 的「重试」按钮触发 `directory.refresh()` + `SyncEngine.requestImmediateTick()` |
| HEALTH-4 | `needsReconnect` 的「重新连接」打开 `ConnectView`，传入 email 让字段预填 |
| HEALTH-5 | 「查看详情」打开 `SyncHealthDetailSheet`（§4.5） |

### 4.4 恢复确认动画

`RootView` 持有 `@State previousHealth: SyncHealthViewState?`：

```swift
.onChange(of: activeHealth) { old, new in
    let wasUnhealthy = old.map { $0 != .ok } ?? false
    let isHealthy = new == .ok
    if wasUnhealthy && isHealthy {
        ErrorCenter.shared.report(.init(
            severity: .info,
            title: "syncRecovered",
            dismissible: true,
            autoDismissAfter: .seconds(4)
        ))
    }
    previousHealth = new
}
```

### 4.5 `SyncHealthDetailSheet`

新增 `Sources/Lagoon/Views/SyncHealthDetailSheet.swift`：

字段：
- `lastSyncAt`：相对时间（"2 分钟前"）+ 绝对时间
- `lastError`：完整字符串，等宽字体（让用户能复制）
- `capabilities` 三项：`idleSupported` / `moveSupported` / `archiveFolderName`

### 4.6 测试

`Tests/LagoonTests/SyncHealthViewStateTests.swift`：

- `from(.ok, lastSyncAt:nil) == .syncing`
- `from(.ok, lastSyncAt:now) == .ok`
- `from(.degraded("x"), lastSyncAt:now) == .degraded("x")`
- `from(.error("y"), lastSyncAt:now) == .error("y")`
- `from(.needsReconnect("z"), nil) == .needsReconnect("z")`

`Tests/LagoonTests/RootViewHealthBannerTests.swift`（如 SwiftUI 可测）：
- `previous=.degraded, current=.ok` → `ErrorCenter.shared.banner` 非 nil 且 title = syncRecovered
- 4s 后 `ErrorCenter.shared.banner` 自动 nil

### 4.7 `SyncEngine.requestImmediateTick()`

`Sources/LagoonServer/Sync/SyncEngine.swift` 需新增：

```swift
private let immediateTickSignal = AsyncStream<Void>.makeStream()
public func requestImmediateTick() {
    immediateTickSignal.continuation.yield()
}
```

`SyncEngine.loop` 增加监听该信号，收到后立即 `tickOnce()`（不等 5min）。该改动**不在本 spec 范围**——列在这里是为了让 §4.3 HEALTH-3 不留歧义；实施时如无此 hook，「重试」按钮仅触发 `directory.refresh()` 即可（不强制要求 server 立即拉取）。

---

## 5. APIClient 超时 + Loading

### 5.1 三档 timeout

新增 `Sources/Lagoon/Services/APIClient.swift`：

```swift
public enum APITimeout: Sendable {
    case fast       // 10s
    case interactive // 30s
    case slow       // 75s

    public var seconds: TimeInterval {
        switch self {
        case .fast: return 10
        case .interactive: return 30
        case .slow: return 75
        }
    }
}
```

### 5.2 URLSession 配置

`APIClient.swift:71-76` 当前：

```swift
let config = URLSessionConfiguration.default
config.timeoutIntervalForRequest = 10
config.timeoutIntervalForResource = 75
```

改为：

```swift
let config = URLSessionConfiguration.default
config.timeoutIntervalForRequest = 60   // 兜底（远大于 .slow）
config.timeoutIntervalForResource = 90
// 每个 request 自己用 URLRequest.timeoutInterval
```

### 5.3 每个 fetch 方法显式标注 timeout

| 方法 | 档位 |
|---|---|
| `fetchAccounts` | `.fast` |
| `fetchMessages` | `.fast` |
| `fetchMessageBody` | `.fast` |
| `markRead` / `pin` / `archive` / `unsubscribe` / `overrideClassification` | `.fast` |
| `connect` (POST /api/accounts/imap) | `.slow`（QQ 探测 1-3s，但失败重试 + 慢路径留余量） |
| `fetchBriefing` | `.interactive` |
| `fetchSummary` | `.interactive` |
| `generateDrafts` | `.interactive` |
| `sendReply` | `.interactive` |
| `fetchUsage` | `.interactive` |
| `search` | `.fast` |

### 5.4 Retry 一次（仅 .fast 档）

`APIClient` 内部：

```swift
private func request<T: Decodable>(
    _ method: String, path: String, timeout: APITimeout,
    body: Data? = nil, as: T.Type
) async throws -> T {
    let primaryResult: Result<T, Error> = await Result { try await rawRequest(method, path: path, timeout: timeout, body: body) }
    switch primaryResult {
    case .success(let v): return v
    case .failure(let e):
        guard timeout == .fast, Self.shouldAutoRetry(e) else { throw e }
        return try await rawRequest(method, path: path, timeout: timeout, body: body)
    }
}

private static func shouldAutoRetry(_ error: Error) -> Bool {
    if let urlError = error as? URLError {
        return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed].contains(urlError.code)
    }
    if let apiError = error as? APIError, (500...599).contains(apiError.httpStatus) {
        return true
    }
    return false
}
```

`.interactive` / `.slow` 不自动 retry。

### 5.5 `APIError.errorDescription` 不暴露 server body

`APIClient.swift:25-27` 当前把 `bodySnippet` 拼进 `localizedDescription`。改为：

```swift
public var errorDescription: String? {
    switch self {
    case .http(let status, let code, _, _):
        return "\(status) \(code ?? "")"  // 不拼 body
    case .transport:
        return "transport error"
    case .decode:
        return "decode error"
    case .notConfigured:
        return "not configured"
    }
}
```

`lagoonUIMessage` 同步改为只暴露稳定 `error code` + http status。**调试信息走 `os.Logger`，不进 `localizedDescription`**。

INVARIANT: server 侧路由已确认不回显上游 provider 文本（spec §5.2 from `MessageRoutes.swift:481-502`），client 侧不再暴露 body 后，server body 永远不会到达 UI。

### 5.6 Loading 三态 + `RefreshIndicator`

新增 `Sources/Lagoon/Views/RefreshIndicator.swift`：

```swift
public enum LoadingState: Equatable {
    case idle
    case loading       // 用户按了刷新
    case refreshing    // 30s 轮询后台刷新
}

struct RefreshIndicatorModifier: ViewModifier {
    let state: LoadingState
    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                if state == .refreshing {
                    Circle()
                        .fill(.orange)
                        .frame(width: 4, height: 4)
                        .padding(4)
                        .transition(.opacity)
                }
            }
            .disabled(state == .loading)
            .help(state == .refreshing ? l10n.alreadyRefreshing : "")
    }
}

extension View {
    public func refreshIndicator(_ state: LoadingState) -> some View {
        modifier(RefreshIndicatorModifier(state: state))
    }
}
```

新增 L10n key：
- `alreadyRefreshing = pick("已在刷新中…", "Already refreshing…")`

### 5.7 测试

`Tests/LagoonTests/APIClientTests.swift`（在 modified +16 行基础上扩展）：

| 测试 | 覆盖 |
|---|---|
| `test_fastTimeoutFiresAfter10s` | URLProtocol mock 10s 不返回 → 抛 `.timedOut` |
| `test_fastAutoRetriesOnce` | 第一次超时 → 第二次成功 → 返回结果 |
| `test_fastAutoRetriesGivesUpAfterSecondTimeout` | 两次都超时 → 抛 `.timedOut` |
| `test_interactiveNoAutoRetry` | 30s 超时 → 不 retry，直接抛 |
| `test_5xxAutoRetries` | mock 返回 503 → retry → 第二次 200 → 返回 |
| `test_4xxNoRetry` | mock 返回 401 → 不 retry |
| `test_errorDescriptionExcludesBody` | 构造 APIError.http(500, "internal", body: "secret", nil) → `errorDescription` 不含 "secret" |

---

## 6. 错误反馈纪律

### 6.1 总纪律（catch 白名单）

任何 view 内 `catch { }` / `catch { /* silently */ }` / `catch { /* non-fatal */ }` **禁止保留**，除以下白名单：

| 白名单 | 原因 |
|---|---|
| `Task { ... }.cancel()` 内部 | 取消是 expected |
| `URLSession dataTask` 已被取消 | 同上 |
| 卸载/退出 App 时的 finalizer | 进程都退了，无 UI 渲染 |

其他 catch 必须三选一：
1. `errorBanner = ErrorBanner(...)` —— 写状态、显示反馈
2. `ErrorCenter.shared.report(...)` —— 适合 helper/manager 不在 view 内
3. `throw` —— 适合被 view 调用的纯函数，让上层处理

### 6.2 文件级改动清单

| 文件:行 | 原代码 | 改为 |
|---|---|---|
| `MessageDetailView.swift:429-431` | `catch { /* leave the row in place */ }` (archiveAndAdvance) | `catch { errorBanner = ErrorBanner(severity:.error, title: l10n.archiveFailedTitle, detail: l10n.archiveFailedDetail, actionLabel: l10n.retry) { await archiveAndAdvance() } }` |
| `MessageDetailView.swift:444` | `catch { }` (unsubscribe) | `catch { errorBanner = ErrorBanner(severity:.error, title: l10n.unsubscribeFailedTitle, detail: l10n.unsubscribeFailedDetail, actionLabel: l10n.openOriginal) { openOriginalMail() } }` |
| `MessageDetailView.swift:454` | `catch { /* non-fatal */ }` (overrideGroup) | `catch { errorBanner = ErrorBanner(severity:.error, title: l10n.overrideGroupFailedTitle, detail: l10n.overrideGroupFailedDetail, actionLabel: l10n.retry) { await overrideClassification(group) } }` |
| `MessageDetailView.swift:359-363` | markRead 失败红字条 | 改用 ErrorBanner，文案 `markReadFailedTitle/Detail` + retry |
| `MessageDetailView.swift:167-170` | `loadSummary` failed 后按钮仍可点 | 在 `summaryState.failed(message)` 路径加 `summaryCooldownUntil = now + 10s`；按钮在 cooldown 期间 disable |
| `MessageDetailView.swift:186` | 菜单 label `l10n.refresh` | 改 `l10n.moreActions`（§3.3）|
| `BriefingFeedView.swift:39,191-207` | 顶部 noticeBanner 裸 String | 改用 `errorBanner: ErrorBanner?` + `noticeBanner(...)` modifier |
| `BriefingFeedView.swift:455-462` | archive 失败错误信息 | 同 MessageDetailView 模板 |
| `BriefingFeedView.swift:77` | `disabled(isLoading)` 让 ⌘R 静默吞 | 改用 `.refreshIndicator(.loading)` —— 已在刷新时按钮 disable + 红点提示而非 silently |
| `BriefingFeedView.swift:487` | `errorMessage = l10n.briefingFailed + error.lagoonUIMessage` | 区分：URLSession `.timedOut` → `briefingTimeoutTitle/Detail`；其他 → 普通 retry ErrorBanner |
| `BriefingFeedView.swift:155-167` | 空态复用 `tapGmailToSync` | 改用 `emptyInboxZero` / `syncingFirstTime` 按 `lastSyncAt` 二选一 |
| `MessageListView.swift:45-50` | 错误条不消失 | 改用 `errorBanner` + `noticeBanner` |
| `MessageListView.swift:52-55` | 空列表只显示「还没有邮件」 | 改用 `emptyInboxZero` / `syncingFirstTime` 分流 |
| `MessageListView.swift:31-37` | toolbar Briefing 按钮 `rectangle.grid.1x2` | icon 改为 `rectangle.grid.2x2` 与 BriefingFeedView 区分 |
| `SearchSheet.swift:62` | `catch {}` | `catch { errorBanner = ErrorBanner(... searchFailedTitle/Detail, retry) { await runSearch() } }` |
| `UndoController.swift:101-105` | `catch {}` | `ErrorCenter.shared.report(.init(severity:.warning, title: l10n.undoFailedTitle, detail: l10n.undoFailedDetail))` |
| `DraftPickerSheet.swift:37` | `Toggle("存到 Gmail Drafts", ...)` | `Toggle(l10n.pushToGmailDrafts, ...)` + provider 门控（§3.4） |
| `ConnectView.swift:262-279` `failureCopy(...)` | 输出 `String?` | 输出 `ErrorBanner?`；`failureCopy` 仍是纯函数（已有测试锁），包成 ErrorBanner 用 adapter |

### 6.3 server body 不暴露安全契约

- server 侧 `Routes/*Routes.swift` 不回显 provider 文本（已有，spec §5.2）
- client 侧 `APIError.errorDescription` 不拼接 body（§5.5）
- 调试走 `os.Logger`，不进 UI
- 真正需要诊断时：**Log → Console.app**，不靠 banner

### 6.4 测试策略

每个被改的 view 加测试，按下到上：

1. **优先**：纯函数抽离（如 `errorBanner(for: APIError, l10n: L10n) -> ErrorBanner?`）单测覆盖
2. **其次**：Snapshot test 整个 view 的 banner 出现/消失
3. **最后**：写进 `docs/superpowers/m1-5-smoke.md` 手动冒烟

### 6.5 Invariant（CI lint）

- **§6.5 Invariant**：本 spec 实施完成后，`git grep -E "catch \{\s*\}|catch \{ /\* " Sources/Lagoon/Views/` 应为 0 命中（白名单除外）
- 新增 `scripts/lint-no-silent-catch.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail
hits=$(grep -rnE 'catch \{\s*\}|catch \{ /\* (silently|non-fatal|leave the row|swallow) ' \
    Sources/Lagoon/Views/ 2>/dev/null || true)
if [[ -n "$hits" ]]; then
    echo "❌ Silent catch detected in Views:"
    echo "$hits"
    exit 1
fi
echo "✅ No silent catches in Views"
```

- Xcode Build Phase 添加 Run Script 调用此脚本，失败时构建失败
- 新增 L10n 字面量也加 lint：

```bash
hits=$(grep -rn 'Gmail\|gmail' Sources/Lagoon/Localization/L10n.swift | \
    grep -v 'pushToGmailDrafts\|gmailProvider\|connectGmail' || true)
```

---

## 7. 验收

### 7.1 单元测试覆盖率

- `NoticeBannerTests.swift`：组件 / modifier / action / autoDismiss
- `SyncHealthViewStateTests.swift`：5 个 state 映射 case
- `ErrorCenterTests.swift`：report 触发 @Published
- `APIClientTests.swift`：7 个 timeout/retry case（§5.7）

### 7.2 M1.5 冒烟清单新增项

`docs/superpowers/m1-5-smoke.md` 新增 §X "UX 反馈冒烟"：

| # | 操作 | 期望 |
|---|---|---|
| X-1 | 连 QQ 账号后立刻按 ⌘R 多次 | 第二次起按钮红点 + tooltip "已在刷新中" |
| X-2 | 故意输入错误授权码 | 红色 banner 显示 `qqAuthFailed`，可点 ✕ 关闭，可点重试 |
| X-3 | 拔网 60s | 健康横幅从 `degraded` 切到 `error`；恢复后短暂 `syncRecovered` toast |
| X-4 | 详情页按 ⌘E，模拟 archive 失败 | ErrorBanner 出现，可点 ✕，可点重试 |
| X-5 | 简报页打开后停网 30s | ErrorBanner 显示 `briefingTimeoutDetail`，按钮 disable 不再 retry |
| X-6 | 搜索时停网 | SearchSheet 顶部 ErrorBanner，文案 `searchFailedDetail`，可重试 |

### 7.3 DoD

- §7.1 全部测试通过
- §6.5 lint 脚本通过
- `bash scripts/run-all-tests.sh` 全绿，无新增 warning
- §7.2 6 条手动冒烟全部 PASS
- 真实 QQ 账号 7 天浸泡无 P0/P1 回归

---

## 8. 开放问题

| # | 问题 | 决策 |
|---|---|---|
| OPEN-1 | `SyncEngine.requestImmediateTick()` 是否本 spec 实施？ | §4.7 注明不在范围；如需，重开 spec |
| OPEN-2 | `ComposerSheet` 错误反馈是否一并改？ | §6.2 未列；如 ComposerSheet 有空 catch，需追加 |
| OPEN-3 | `SuccessNotice` 是否实现？ | §2.5 列入但不强制；仅当发现确实需要时再实现 |
| OPEN-4 | 是否把 banner 抽成 macOS Notification 风格（顶部 toast）？ | 当前选 inline banner；如设计需要再改 |
| OPEN-5 | `MarkRead` 在 Brief/Detail 列表项上 hover 时是否能预览而不 markRead？ | 不在本 spec；后续 spec |

---

## 9. 实施拆分建议

PR 顺序（最小风险到最大风险）：

1. **PR1**：NoticeBanner + ErrorCenter 基础（§2）—— 不动任何业务，单测 100% 覆盖
2. **PR2**：APIClient 超时 + retry + errorDescription 改（§5）—— 服务端 + 客户端协议层独立
3. **PR3**：L10n 改名 + 新增 key + DraftPicker 走 L10n + ConnectView 字段标题化（§3）—— 文案独立 PR，影响范围小
4. **PR4**：RootView 健康横幅 + 所有 view catch → ErrorBanner 接入（§4 + §6.2）—— 业务接入，最大也最重；最后跑 §6.5 lint

每个 PR 跑 `bash scripts/run-all-tests.sh` + lint 全绿才合并。
