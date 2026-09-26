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
    private let api = APIClient()

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
            let archived = try await api.fetchMessages(accountId: accountId, limit: 1, archived: true)
            archivedCount = archived.cursor.totalUnread == 0 ? archived.messages.count : archived.cursor.totalUnread
            // totalUnread is unread-specific; the archived count needs its own
            // source — the cursor is not it. Use the fetched window count.
            archivedCount = archived.messages.count < 200 ? archived.messages.count : 200
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
    @State private var isLoading = true
    @State private var isSweeping = false
    @State private var errorBanner: ErrorBanner?
    @State private var path: [String] = []
    private let api = APIClient()

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
                }
            }
            .navigationDestination(for: String.self) { remoteId in
                MessageDetailView(
                    remoteId: remoteId,
                    accountId: accountId,
                    header: messages.first { $0.remoteId == remoteId },
                    initiallyPinned: false,
                    siblings: messages.map(\.remoteId),
                    onArchived: { id, _ in
                        messages.removeAll { $0.remoteId == id }
                    },
                    onAdvanceTo: { next in path = next.map { [$0] } ?? [] },
                    onDelete: { id in
                        messages.removeAll { $0.remoteId == id }
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
            switch source {
            case .archived:
                messages = try await api.fetchMessages(accountId: accountId, limit: 200, archived: true).messages
            case .rule(let stack):
                messages = try await api.fetchMessages(accountId: accountId, limit: 200, stackId: stack.rule.id).messages
            }
        } catch {
            errorBanner = ErrorBanner(severity: .error, title: l10n.loadFailed, detail: error.lagoonUIMessage)
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
            messages.removeAll { m in
                response.items.contains { $0.remoteId == m.remoteId && $0.ok }
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
    private let api = APIClient()

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
