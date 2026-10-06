import SwiftUI
import LagoonKit

// 聚合（归集规则）的三个面板：规则列表、规则命中的邮件、规则编辑器。
// 全部沿用 sheet 自持 NavigationStack 的既有合同（SearchSheet 模式）。

extension SubjectNormalizer {
    /// 从主题里挑一个建议关键词：【营销标签】优先，其次取最长的词块。
    /// 只做建议 —— 用户在编辑器里可以改任何词。
    static func suggestKeyword(in subject: String?) -> String? {
        guard let norm = normalize(subject), !norm.isEmpty else { return nil }
        let pattern = try? NSRegularExpression(pattern: "【([^】]{2,20})】")
        if let pattern {
            let ns = norm as NSString
            if let match = pattern.firstMatch(
                in: norm, range: NSRange(location: 0, length: ns.length)
            ), match.numberOfRanges >= 2 {
                return ns.substring(with: match.range(at: 1))
            }
        }
        let tokens = norm.split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "|" })
        let candidate = tokens.filter { $0.count >= 2 }.max { $0.count < $1.count }
        return candidate.map(String.init)
    }
}

/// 聚合规则管理面板：内置「已归档」档案柜 + 用户规则列表。
struct StackListSheet: View {
    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var accounts: AccountStore
    @State private var stacks: [StackSummary] = []
    @State private var archivedCount = 0
    @State private var isLoading = true
    @State private var errorBanner: ErrorBanner?
    @State private var editor: StackEditorRequest?
    @State private var openStack: StackSummary?
    @State private var showArchived = false
    private let api = APIClient.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Text(l10n.stackListTitle).font(.headline)
                    Spacer()
                    Button(l10n.stackNew) {
                        editor = StackEditorRequest(kind: .keyword, value: "", name: "")
                    }
                    Button(l10n.close) { dismiss() }
                }
                .padding(12)
                Divider()
                if isLoading {
                    ProgressView().padding(20)
                } else {
                    List {
                        Section {
                            Button {
                                showArchived = true
                            } label: {
                                HStack {
                                    Label(l10n.stackArchivedRow, systemImage: "archivebox")
                                    Spacer()
                                    Text(l10n.threadCount(archivedCount))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } header: {
                            Text(l10n.stackBuiltInHeader)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Section {
                            if stacks.isEmpty {
                                Text(l10n.stackEmpty)
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                            ForEach(stacks) { stack in
                                Button {
                                    openStack = stack
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(stack.rule.name).lineLimit(1)
                                            Text("\(l10n.stackKindLabel(stack.rule.kind.displayName)) · \(stack.rule.value)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        Text(l10n.threadCount(stack.count))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .contextMenu {
                                    Button(l10n.stackDeleteRule, role: .destructive) {
                                        Task { await deleteRule(stack) }
                                    }
                                }
                            }
                        } header: {
                            Text(l10n.stackRulesHeader)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .navigationDestination(isPresented: $showArchived) {
                if let accountId = accounts.accountId {
                    StackMailSheet(accountId: accountId, source: .archived)
                }
            }
            .noticeBanner($errorBanner)
            .sheet(item: $openStack) { stack in
                if let accountId = accounts.accountId {
                    StackMailSheet(accountId: accountId, source: .rule(stack))
                }
            }
            .sheet(item: $editor) { request in
                StackRuleEditorSheet(
                    initialKind: request.kind,
                    prefilledValue: request.value,
                    prefilledName: request.name
                ) { _ in
                    Task { await reload() }
                }
            }
            .task { await reload() }
        }
        .frame(width: 520, height: 520)
    }

    private func reload() async {
        isLoading = stacks.isEmpty
        defer { isLoading = false }
        guard let accountId = accounts.accountId else { return }
        do {
            let response = try await api.fetchStacks(accountId: accountId)
            stacks = response.stacks
            // The archived row's badge: the server's `totalCount`
            // ignores LIMIT, so this is the real cabinet size.
            let archived = try await api.fetchMessages(accountId: accountId, limit: 1, archived: true)
            archivedCount = archived.totalCount ?? archived.messages.count
        } catch {
            errorBanner = ErrorBanner(severity: .error, title: l10n.loadFailed, detail: error.lagoonUIMessage)
        }
    }

    private func deleteRule(_ stack: StackSummary) async {
        guard let accountId = accounts.accountId else { return }
        do {
            try await api.deleteStack(id: stack.rule.id, accountId: accountId)
            stacks.removeAll { $0.rule.id == stack.rule.id }
        } catch {
            errorBanner = ErrorBanner(severity: .error, title: l10n.loadFailed, detail: error.lagoonUIMessage)
        }
    }
}

/// 聚合内容：规则（或内置档案柜）命中的全部邮件，含清扫按钮。
struct StackMailSheet: View {
    enum Source {
        case archived
        case rule(StackSummary)
    }

    let accountId: UUID
    let source: Source

    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss
    @State private var messages: [MessageHeader] = []
    /// Rows the filter matches on the server, ignoring the response cap.
    ///
    /// This sheet's 清扫 verb archives everything it matched, so a truncated
    /// list would make the sweep quietly partial — and archiving is remote and
    /// not the kind of failure the undo toast covers well in bulk. `nil` until
    /// the server answers, and non-nil means "we know the full size".
    @State private var serverTotalCount: Int?
    @State private var isLoading = true
    @State private var isSweeping = false
    @State private var errorBanner: ErrorBanner?
    @State private var path: [String] = []
    private let api = APIClient.shared

    private var title: String {
        switch source {
        case .archived: return L10n.current.stackArchivedRow
        case .rule(let stack): return stack.rule.name
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.headline).lineLimit(1)
                        if case .rule(let stack) = source {
                            Text("\(l10n.stackKindLabel(stack.rule.kind.displayName)) · \(stack.rule.value)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    if case .rule = source {
                        Button {
                            Task { await sweep() }
                        } label: {
                            if isSweeping {
                                ProgressView().controlSize(.small)
                            } else {
                                Label(l10n.sweepTitle, systemImage: "tray.and.arrow.down")
                            }
                        }
                        .disabled(isSweeping || messages.isEmpty)
                        .help(l10n.sweepHelp)
                    }
                    Button(l10n.close) { dismiss() }
                }
                .padding(12)
                Divider()
                if isLoading {
                    ProgressView().padding(20)
                } else if messages.isEmpty {
                    Text(l10n.senderMailEmpty).foregroundStyle(.secondary).padding(20)
                } else {
                    List(messages) { m in
                        NavigationLink(value: m.remoteId) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(m.subject ?? L10n.current.noSubject)
                                        .font(.body)
                                        .bold(!m.isRead)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(m.receivedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Text(m.fromName ?? m.fromAddress)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .listStyle(.inset)
                    // A real row at the end of the list, not a toast: it scrolls
                    // with the content so the caveat is still there when the
                    // user comes back to sweep.
                    .safeAreaInset(edge: .bottom) {
                        if let truncatedNotice {
                            Label(truncatedNotice, systemImage: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.bar)
                                .overlay(alignment: .top) { Divider() }
                                .accessibilityLabel(truncatedNotice)
                        }
                    }
                }
            }
            .navigationDestination(for: String.self) { remoteId in
                MessageDetailView(
                    remoteId: remoteId,
                    accountId: accountId,
                    header: messages.first { $0.remoteId == remoteId },
                    initiallyPinned: messages.first { $0.remoteId == remoteId }?.isPinned ?? false,
                    siblings: messages.map(\.remoteId),
                    onArchived: { id, _ in
                        removeRows(matching: id)
                    },
                    onAdvanceTo: { next in path = next.map { [$0] } ?? [] },
                    onDelete: { id in
                        removeRows(matching: id)
                        path = []
                    }
                )
                .id(remoteId)
            }
        }
        .frame(width: 640, height: 560)
        .noticeBanner($errorBanner)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            // No client-side limit (see APIClient.fetchMessages): this sheet's
            // 清扫 verb archives everything it matched, so the list it sweeps
            // has to be the list it shows. `totalCount` comes back regardless of
            // LIMIT, which is what lets the sheet say when the two differ.
            let response: SyncResponse
            switch source {
            case .archived:
                response = try await api.fetchMessages(accountId: accountId, archived: true)
            case .rule(let stack):
                response = try await api.fetchMessages(
                    accountId: accountId, stackId: stack.rule.id
                )
            }
            messages = response.messages
            serverTotalCount = response.totalCount
        } catch {
            errorBanner = ErrorBanner(severity: .error, title: l10n.loadFailed, detail: error.lagoonUIMessage)
        }
    }

    /// Non-nil when the server held more rows than the response could carry.
    ///
    /// Rendered as a row at the end of the list rather than as a toast: it
    /// scrolls with the content, so it stays findable after the user has read
    /// past it — and a one-line caveat that dismisses itself is exactly how a
    /// partial list comes to look like a complete one.
    private var truncatedNotice: String? {
        ListTruncationNotice.text(shown: messages.count, total: serverTotalCount, l10n: l10n)
    }

    /// The one way a row leaves this list, so the count moves with it.
    ///
    /// Without this, archiving one row from the detail pane leaves the total
    /// where it was — and a list that is now *complete* goes on claiming to be
    /// truncated, which is the mirror image of the bug this notice exists to
    /// fix. Same invariant `MessageListView.removeRows` keeps, for the same
    /// reason.
    private func removeRows(matching remoteId: String) {
        removeRow(id: remoteId)
    }

    private func removeRow(id remoteId: String) {
        let removed = messages.filter { $0.remoteId == remoteId }.count
        guard removed > 0 else { return }
        messages.removeAll { $0.remoteId == remoteId }
        if let total = serverTotalCount {
            serverTotalCount = max(0, total - removed)
        }
    }

    /// 清扫：把聚合里当前命中的邮件整批归档（远端逐封、逐项回报）。
    private func sweep() async {
        guard case .rule = source else { return }
        isSweeping = true
        defer { isSweeping = false }
        do {
            let response = try await api.archiveBulk(
                remoteIds: messages.map(\.remoteId), accountId: accountId
            )
            let okCount = response.items.filter(\.ok).count
            let failed = response.items.filter { !$0.ok }
            for item in response.items where item.ok {
                removeRow(id: item.remoteId)
            }
            if failed.isEmpty {
                ErrorCenter.shared.report(.init(
                    severity: .info,
                    title: L10n.current.sweepDone(okCount),
                    autoDismissAfter: .seconds(5)
                ))
            } else {
                ErrorCenter.shared.report(.init(
                    severity: .warning,
                    title: L10n.current.sweepPartial(okCount, failed.count),
                    autoDismissAfter: .seconds(6)
                ))
            }
        } catch {
            errorBanner = ErrorBanner(severity: .error, title: l10n.loadFailed, detail: error.lagoonUIMessage)
        }
    }
}

/// 规则编辑器：从右键入口预填，或从管理面板空白新建。
struct StackRuleEditorSheet: View {
    let initialKind: StackRule.Kind
    let prefilledValue: String
    let prefilledName: String
    var onCreated: (StackSummary) -> Void

    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var accounts: AccountStore
    @State private var kind: StackRule.Kind
    @State private var value: String
    @State private var name: String
    @State private var isCreating = false
    @State private var errorBanner: ErrorBanner?
    private let api = APIClient.shared

    init(
        initialKind: StackRule.Kind,
        prefilledValue: String,
        prefilledName: String,
        onCreated: @escaping (StackSummary) -> Void
    ) {
        self.initialKind = initialKind
        self.prefilledValue = prefilledValue
        self.prefilledName = prefilledName
        self.onCreated = onCreated
        _kind = State(initialValue: initialKind)
        _value = State(initialValue: prefilledValue)
        _name = State(initialValue: prefilledName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(l10n.stackEditorTitle).font(.headline)
            Picker(l10n.stackRuleKind, selection: $kind) {
                Text(l10n.stackKindSender).tag(StackRule.Kind.sender)
                Text(l10n.stackKindKeyword).tag(StackRule.Kind.keyword)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            if kind == .keyword {
                TextField(l10n.stackRuleValue, text: $value)
                    .textFieldStyle(.roundedBorder)
                Text(l10n.keywordHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                TextField(l10n.stackRuleValue, text: $value)
                    .textFieldStyle(.roundedBorder)
                    .disabled(initialKind == .sender)
                Text(l10n.senderHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextField(l10n.stackRuleName, text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button(l10n.cancel) { dismiss() }
                Button {
                    Task { await create() }
                } label: {
                    if isCreating {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(l10n.stackCreate)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(value.trimmingCharacters(in: .whitespaces).isEmpty
                    || name.trimmingCharacters(in: .whitespaces).isEmpty
                    || isCreating)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 440)
        .noticeBanner($errorBanner)
    }

    private func create() async {
        guard let accountId = accounts.accountId else { return }
        isCreating = true
        defer { isCreating = false }
        do {
            let response = try await api.createStack(
                StackCreateRequest(
                    name: name.trimmingCharacters(in: .whitespaces),
                    kind: kind,
                    value: value.trimmingCharacters(in: .whitespaces)
                ),
                accountId: accountId
            )
            onCreated(response.stack)
            ErrorCenter.shared.report(.init(
                severity: .info,
                title: L10n.current.stackCreated(response.stack.rule.name),
                autoDismissAfter: .seconds(5)
            ))
            dismiss()
        } catch {
            errorBanner = ErrorBanner(severity: .error, title: l10n.loadFailed, detail: error.lagoonUIMessage)
        }
    }
}

/// Identifiable wrapper for presenting the editor via `.sheet(item:)`.
struct StackEditorRequest: Identifiable {
    let kind: StackRule.Kind
    let value: String
    let name: String
    var id: String { "\(kind.rawValue)|\(value)" }
}
