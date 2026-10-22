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

/// 聚合管理面板：内置「已归档」档案柜 + 用户分组列表。
struct StackListSheet: View {
    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var accounts: AccountStore
    @State private var stacks: [StackSummary] = []
    @State private var archivedCount = 0
    @State private var isLoading = true
    @State private var errorBanner: ErrorBanner?
    @State private var editor: StackEditorRequest?
    /// The group being edited, when the user picked 「编辑」 from a row's
    /// context menu. nil means "creating a new one".
    @State private var editing: StackEditRequest?
    @State private var openStack: StackSummary?
    @State private var showArchived = false
    /// The group waiting for the user to confirm its deletion.
    ///
    /// A group is not a message: deleting one does not remove mail, it
    /// re-routes an endless future stream of it, and there is no undo for
    /// it. That is a bigger blast radius than deleting a single mail, and
    /// it used to have a smaller safety net — one right-click and no
    /// confirmation at all.
    @State private var pendingDeleteRule: StackSummary?
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
                .padding(LagoonMetrics.spaceMD)
                Divider()
                if isLoading {
                    ProgressView().padding(LagoonMetrics.spaceXL)
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
                                        VStack(alignment: .leading, spacing: LagoonMetrics.spaceXS) {
                                            Text(stack.rule.name).lineLimit(1)
                                            Text("\(l10n.stackKindLabel(l10n.stackKindName(stack.rule.kind))) · \(stack.rule.value)")
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
                                    // The exit from "I built it on the wrong
                                    // keyword". The menu used to offer only
                                    // 删除, so a group could be created and
                                    // destroyed but never changed — the one
                                    // thing a user wants to do with a filter
                                    // they got slightly wrong.
                                    Button(l10n.stackEditRule) {
                                        editing = StackEditRequest(rule: stack.rule)
                                    }
                                    Button(l10n.stackDeleteRule, role: .destructive) {
                                        pendingDeleteRule = stack
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
            // The same editor, opened on a group that already exists. It is
            // the *same* sheet rather than a second one so the two paths
            // cannot drift apart in what they accept.
            .sheet(item: $editing) { request in
                StackRuleEditorSheet(
                    initialKind: request.rule.kind,
                    prefilledValue: request.rule.value,
                    prefilledName: request.rule.name,
                    editing: request.rule.id
                ) { _ in
                    Task { await reload() }
                }
            }
            .task { await reload() }
            // The delete confirmation. It names the group and how much mail
            // is currently matching it, because the number is what tells
            // the user how much re-routing they are about to cause.
            .confirmationDialog(
                l10n.stackDeleteRuleConfirmTitle(name(of: pendingDeleteRule)),
                isPresented: Binding(
                    get: { pendingDeleteRule != nil },
                    set: { if !$0 { pendingDeleteRule = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button(l10n.stackDeleteRule, role: .destructive) {
                    guard let stack = pendingDeleteRule else { return }
                    pendingDeleteRule = nil
                    Task { await deleteRule(stack) }
                }
                .tint(LagoonTheme.danger)
                Button(l10n.cancel, role: .cancel) { pendingDeleteRule = nil }
            } message: {
                Text(
                    l10n.stackDeleteRuleConfirmMessage(
                        name(of: pendingDeleteRule),
                        count(of: pendingDeleteRule)
                    )
                )
            }
        }
        .frame(
            width: LagoonSheetSize.standard.width,
            height: LagoonSheetSize.standard.height
        )
    }

    /// The group's name, for the confirmation that deletes it.
    private func name(of stack: StackSummary?) -> String {
        guard let stack else { return "" }
        return stack.rule.name
    }

    /// How many mails the group currently matches, for the same
    /// confirmation. The count is already on the row — the sheet does not
    /// have to go and ask the server again.
    private func count(of stack: StackSummary?) -> Int {
        guard let stack else { return 0 }
        return stack.count
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
            errorBanner = ErrorBanner(
                severity: .error,
                title: l10n.loadFailed,
                detail: error.lagoonUIMessage,
                // A failed load is a network / server failure — the same
                // fetch can succeed a second later. Spec INV-4: a retryable
                // failure gets a retry, and the retry re-runs *this* load.
                actionLabel: l10n.retry,
                action: { [self] in await self.reload() }
            )
        }
    }

    private func deleteRule(_ stack: StackSummary) async {
        guard let accountId = accounts.accountId else { return }
        do {
            try await api.deleteStack(id: stack.rule.id, accountId: accountId)
            stacks.removeAll { $0.rule.id == stack.rule.id }
        } catch {
            errorBanner = ErrorBanner(
                severity: .error,
                title: l10n.deleteRuleFailed,
                detail: error.lagoonUIMessage,
                // A write the user asked for failed on the network, and the
                // rule is still in the list (it is only removed on success),
                // so the same delete can simply be tried again. Spec INV-4.
                actionLabel: l10n.retry,
                action: { [self] in await self.deleteRule(stack) }
            )
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
    @EnvironmentObject private var undo: UndoController
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
                    VStack(alignment: .leading, spacing: LagoonMetrics.spaceXS) {
                        Text(title).font(.headline).lineLimit(1)
                        if case .rule(let stack) = source {
                            Text("\(l10n.stackKindLabel(l10n.stackKindName(stack.rule.kind))) · \(stack.rule.value)")
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
                .padding(LagoonMetrics.spaceMD)
                Divider()
                if isLoading {
                    ProgressView().padding(LagoonMetrics.spaceXL)
                } else if messages.isEmpty {
                    ContentUnavailableView {
                        Label(emptyStateText, systemImage: emptyStateIcon)
                    }
                } else {
                    List(messages) { m in
                        NavigationLink(value: m.remoteId) {
                            VStack(alignment: .leading, spacing: LagoonTypography.rowSpacing) {
                                HStack(alignment: .firstTextBaseline, spacing: LagoonMetrics.spaceSM) {
                                    UnreadMarker(isUnread: !m.isRead)
                                    Text(m.subject ?? L10n.current.noSubject)
                                        .font(LagoonTypography.rowSubject)
                                        .bold(!m.isRead)
                                        .lineLimit(LagoonTypography.rowSubjectLines)
                                    Spacer()
                                    Text(LagoonTypography.rowTimestamp(m.receivedAt))
                                        .font(LagoonTypography.rowTime)
                                        .foregroundStyle(.secondary)
                                }
                                Text(m.fromName ?? m.fromAddress)
                                    .font(LagoonTypography.rowSender)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(LagoonTypography.rowSubjectLines)
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
                                .padding(.horizontal, LagoonMetrics.spaceMD)
                                .padding(.vertical, LagoonMetrics.spaceSM)
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
                    siblings: messages.map {
                        MessageRef(accountId: accountId, remoteId: $0.remoteId)
                    },
                    onArchived: { id, _ in
                        removeRows(matching: id)
                    },
                    onAdvanceTo: { next in path = next.map { [$0.remoteId] } ?? [] },
                    onDelete: { id in
                        removeRows(matching: id)
                        path = []
                    }
                )
                .id(remoteId)
            }
        }
        .frame(
            width: LagoonSheetSize.wide.width,
            height: LagoonSheetSize.wide.height
        )
        .noticeBanner($errorBanner)
        .task { await load() }
    }

    /// The empty state, in the words of what is actually empty.
    ///
    /// The sheet used to say 「没有来自此发件人的邮件」 for both of its
    /// sources — but one of them is the built-in archive cabinet and the
    /// other is a group the user wrote, which may match on a *keyword*. A
    /// user who just created a keyword group was told, in those words,
    /// that they have no mail from a sender: an explanation of something
    /// that was never asked, and one that is simply false.
    private var emptyStateText: String {
        switch source {
        case .archived:
            return l10n.stackArchivedEmpty
        case .rule(let stack):
            return l10n.stackGroupEmpty(stack.rule.name)
        }
    }

    /// The symbol that goes with the empty state: the cabinet for the
    /// built-in archive, a folder for a group the user wrote.
    private var emptyStateIcon: String {
        switch source {
        case .archived: return "archivebox"
        case .rule: return "folder"
        }
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
            errorBanner = ErrorBanner(
                severity: .error,
                title: l10n.loadFailed,
                detail: error.lagoonUIMessage,
                // The list is a pure read: nothing about it changed while it
                // failed, so re-running the same fetch is the whole fix.
                // Spec INV-4.
                actionLabel: l10n.retry,
                action: { [self] in await self.load() }
            )
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
            // 清扫 gets an undo toast too, with **every** action id the
            // sweep wrote.
            //
            // The sweep used to report a count and offer nothing to undo,
            // while the user guide promised that every change could be
            // undone. The promise matters most where the sweep is
            // biggest: "archive everything this rule matched" is one
            // click that can move a hundred messages, and it needs a way
            // back.
            let actionIds = response.items.compactMap { $0.ok ? $0.actionId : nil }
            if let first = actionIds.first {
                undo.show(UndoItem(
                    id: first,
                    message: L10n.current.sweepDone(okCount),
                    systemImage: "archivebox",
                    extraIds: Array(actionIds.dropFirst())
                ))
            }
            if failed.isEmpty, let truncated = response.truncatedCount, truncated > 0 {
                // The sweep hit the server's per-call cap: the messages it
                // archived are gone, but the group is NOT clear. Reporting
                // "已归档 N 封" here would tell the user the group is empty
                // while messages are still sitting in the inbox — the one
                // outcome this banner must not produce.
                ErrorCenter.shared.report(.init(
                    severity: .warning,
                    title: L10n.current.sweepTruncated(okCount, truncated),
                    autoDismissAfter: .seconds(8)
                ))
            } else if failed.isEmpty {
                ErrorCenter.shared.report(.init(
                    // Green, not blue: the sweep worked. A blue banner reads
                    // as "something went wrong", which is the opposite of
                    // what the user just did.
                    severity: .success,
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
            errorBanner = ErrorBanner(
                severity: .error,
                title: l10n.loadFailed,
                detail: error.lagoonUIMessage,
                // 清扫 is a user-triggered write over a list that did not
                // change, so the same sweep can simply run again.
                // Spec INV-4.
                actionLabel: l10n.retry,
                action: { [self] in await self.sweep() }
            )
        }
    }
}

/// 分组编辑器：从右键入口预填，或从管理面板空白新建。
///
/// The same sheet edits an existing group: pass `editing` (the group's id)
/// and the title, the button and the write all change to the edit path. One
/// editor rather than two, because two editors would eventually disagree
/// about what a valid group is — and the *edit* path is the one that used
/// not to exist at all, so it is the one that has to be the same code.
struct StackRuleEditorSheet: View {
    let initialKind: StackRule.Kind
    let prefilledValue: String
    let prefilledName: String
    /// The group being edited, or nil when creating a new one.
    var editing: UUID?
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
        editing: UUID? = nil,
        onCreated: @escaping (StackSummary) -> Void
    ) {
        self.initialKind = initialKind
        self.prefilledValue = prefilledValue
        self.prefilledName = prefilledName
        self.editing = editing
        self.onCreated = onCreated
        _kind = State(initialValue: initialKind)
        _value = State(initialValue: prefilledValue)
        _name = State(initialValue: prefilledName)
    }

    /// Whether this sheet creates a new group or edits an existing one.
    private var isEditing: Bool { editing != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: LagoonMetrics.spaceLG) {
            Text(isEditing ? l10n.stackEditorEditTitle : l10n.stackEditorTitle).font(.headline)
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
                    // A sender group created from a right-click already knows
                    // its address, so the field is locked — the user did not
                    // type it and should not be invited to. An *edited* group
                    // is the opposite case: the user opened it precisely to
                    // change what it matches, so the field has to be editable
                    // or "edit" is a lie.
                    .disabled(initialKind == .sender && !isEditing)
                Text(l10n.senderHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextField(l10n.stackRuleName, text: $name)
                .textFieldStyle(.roundedBorder)
            // The one place the difference has to be stated before the user
            // commits: they are about to create a group, and the group they
            // are creating will not change the Briefing's groups. Without
            // this, the moment they most expect their rule to take effect —
            // right after saving it — is the moment the product could have
            // said so and did not.
            //
            // Shown only when *creating*. An existing group is already
            // understood as a filter; re-stating the boundary on every edit
            // would be noise.
            if !isEditing {
                Text(l10n.stackEditorScopeNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(l10n.cancel) { dismiss() }
                Button {
                    Task { await save() }
                } label: {
                    if isCreating {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(isEditing ? l10n.stackSave : l10n.stackCreate)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(value.trimmingCharacters(in: .whitespaces).isEmpty
                    || name.trimmingCharacters(in: .whitespaces).isEmpty
                    || isCreating)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(LagoonMetrics.spaceLG)
        .frame(width: LagoonSheetSize.compact.width)
        .noticeBanner($errorBanner)
    }

    /// Create or update, depending on what the sheet was opened for.
    private func save() async {
        guard let accountId = accounts.accountId else { return }
        isCreating = true
        defer { isCreating = false }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedValue = value.trimmingCharacters(in: .whitespaces)
        do {
            let stack: StackSummary
            if let editing {
                let response = try await api.updateStack(
                    id: editing,
                    name: trimmedName,
                    kind: kind,
                    value: trimmedValue,
                    accountId: accountId
                )
                stack = response.stack
            } else {
                let response = try await api.createStack(
                    StackCreateRequest(name: trimmedName, kind: kind, value: trimmedValue),
                    accountId: accountId
                )
                stack = response.stack
            }
            onCreated(stack)
            ErrorCenter.shared.report(.init(
                // Green, not blue: the group was saved.
                severity: .success,
                title: isEditing
                    ? L10n.current.stackUpdated(stack.rule.name)
                    : L10n.current.stackCreated(stack.rule.name),
                autoDismissAfter: .seconds(5)
            ))
            // The sidebar lists the user's groups with their live counts, and
            // the list surfaces listen for the same notification. A renamed
            // group that only changed in the panel it was edited in would
            // leave the sidebar showing the old name — which is the "I
            // renamed it and nothing happened" dead end this feature exists
            // to remove.
            NotificationCenter.default.post(name: .lagoonDidChangeData, object: nil)
            dismiss()
        } catch {
            errorBanner = ErrorBanner(
                severity: .error,
                title: isEditing ? l10n.updateRuleFailed : l10n.loadFailed,
                detail: error.lagoonUIMessage,
                // The group was not saved (the sheet is still open), so the
                // same write can be sent again. Spec INV-4.
                actionLabel: l10n.retry,
                action: { [self] in await self.save() }
            )
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

/// The group being edited, for `.sheet(item:)`.
///
/// Identified by the group's id, so opening the editor on a different group
/// re-presents the sheet with the new group's values rather than keeping the
/// ones the sheet was last opened with.
struct StackEditRequest: Identifiable {
    let rule: StackRule
    var id: UUID { rule.id }
}
