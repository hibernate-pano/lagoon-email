import SwiftUI
import LagoonKit

/// Full message reader (spec §3). Loads body, fires markRead on appear,
/// and exposes the M2 actions: pin, archive, summarize, draft (3 variants),
/// override, unsubscribe.
struct MessageDetailView: View {
    let remoteId: String
    let accountId: UUID
    let header: MessageHeader?
    let initiallyPinned: Bool
    /// Optional sibling list for j/k navigation and auto-advance on archive.
    var siblings: [String]? = nil
    /// Called after a successful archive/undo so the list row can disappear/return.
    var onArchived: ((String, Bool) -> Void)? = nil  // (remoteId, isArchived)
    var onReadStateChange: (String, Bool) -> Void = { _, _ in }
    var onPinnedChanged: (Bool) -> Void = { _ in }
    /// Called after a successful archive with the next sibling remoteId.
    var onAdvanceTo: ((String) -> Void)? = nil

    @State private var messageBody: MessageBody?
    @State private var isLoadingBody = true
    @State private var bodyError: String?

    @State private var isRead: Bool
    @State private var didMarkRead = false
    @State private var readError: String?

    @State private var isPinned: Bool
    @State private var isPinBusy = false
    @State private var pinError: String?

    @State private var summaryState: SummaryState = .idle

    @State private var draftState: DraftState = .idle
    @State private var showDraftPicker = false

    @State private var showOverrideMenu = false

    @State private var archivedLocal = false

    @State private var showComposer = false
    @State private var sentNotice: String?
    @State private var sentNoticeDismiss: Task<Void, Never>?

    @Environment(\.l10n) private var l10n
    @EnvironmentObject private var accounts: AccountStore
    @EnvironmentObject private var undo: UndoController
    private let api = APIClient()

    private enum SummaryState: Equatable {
        case idle
        case loading
        case loaded(MessageSummary)
        case unavailable
        case failed(String)
    }

    private enum DraftState: Equatable {
        case idle
        case loading
        case loaded(DraftReply)
        case unavailable
        case failed(String)
    }

    init(
        remoteId: String,
        accountId: UUID,
        header: MessageHeader?,
        initiallyPinned: Bool,
        siblings: [String]? = nil,
        onArchived: ((String, Bool) -> Void)? = nil,
        onAdvanceTo: ((String) -> Void)? = nil,
        onReadStateChange: @escaping (String, Bool) -> Void = { _, _ in },
        onPinnedChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.remoteId = remoteId
        self.accountId = accountId
        self.header = header
        self.initiallyPinned = initiallyPinned
        self.siblings = siblings
        self.onArchived = onArchived
        self.onAdvanceTo = onAdvanceTo
        self.onReadStateChange = onReadStateChange
        self.onPinnedChanged = onPinnedChanged
        _isRead = State(initialValue: header?.isRead ?? false)
        _isPinned = State(initialValue: initiallyPinned)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                metadata
                if let readError { inlineNotice(readError, systemImage: "envelope.badge") }
                if let pinError { inlineNotice(pinError, systemImage: "pin.slash") }
                if archivedLocal { inlineNotice(l10n.archivedLocallyOnly, systemImage: "tray.and.arrow.down") }
                if let sentNotice {
                    inlineNotice(sentNotice, systemImage: "paperplane.fill", color: .green)
                }
                summarySection
                draftSection
                Divider()
                bodySection
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationTitle(subjectText)
        .toolbar { toolbarContent }
        .task { await loadBody() }
        .task { await markReadOnce() }
        .sheet(isPresented: $showDraftPicker) {
            if let draft = draftPick {
                DraftPickerSheet(draft: draft, onPick: handleDraftPick)
            }
        }
        .sheet(isPresented: $showComposer) {
            ComposerSheet(
                remoteId: remoteId,
                accountId: accountId,
                to: header?.fromAddress ?? "",
                subject: subjectText,
                initialBody: draftPick.map { draft in
                    draft.variants.indices.contains(0) ? draft.variants[0] : ""
                } ?? ""
            ) { _ in
                showSentNotice()
            }
        }
        .confirmationDialog(l10n.overrideGroup, isPresented: $showOverrideMenu, titleVisibility: .visible) {
            ForEach(BriefingGroup.allCases.filter { $0 != .pinned }, id: \.self) { group in
                Button(l10n.groupTitle(group)) { overrideClassification(to: group) }
            }
            Button(l10n.retry, role: .cancel) {}
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button { showComposer = true } label: {
                Label(l10n.reply, systemImage: "arrowshape.turn.up.left")
            }
            .help(l10n.replyHelp)

            Button { Task { await togglePin() } } label: {
                Label(isPinned ? l10n.unpin : l10n.pin, systemImage: isPinned ? "pin.slash" : "pin")
            }
            .disabled(isPinBusy)
            .help(isPinned ? l10n.unpinHelp : l10n.pinHelp)
            .keyboardShortcut("p", modifiers: .command)

            Button {
                Task { await loadSummary() }
            } label: {
                if summaryState == .loading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(l10n.summarizing)
                    }
                } else {
                    Label(l10n.summarize, systemImage: "sparkles")
                }
            }
            .disabled(summaryState == .loading)
            .help(l10n.summarizeHelp)
            .keyboardShortcut("d", modifiers: .command)

            Button { Task { await generateDrafts() } } label: {
                Label(l10n.draftVariants, systemImage: "text.bubble")
            }
            .disabled(draftState == .loading)
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .help(l10n.shortcutDraft)

            Menu {
                Button(l10n.markRead) { Task { await markReadOnce(force: true) } }
                    .disabled(isRead)
                Button(l10n.overrideGroup) { showOverrideMenu = true }
                Button(l10n.unsubscribe, role: .destructive) { Task { await unsubscribe() } }
                    .disabled(header == nil)
            } label: {
                Label(l10n.refresh, systemImage: "ellipsis.circle")
            }

            Button { Task { await archiveAndAdvance() } } label: {
                Label(l10n.archiveAndNext, systemImage: "tray.and.arrow.down")
            }
            .keyboardShortcut("e", modifiers: .command)
            .help(l10n.shortcutArchiveNext)
        }
    }

    // MARK: - Sections

    private var toDisplay: String? {
        guard let to = messageBody?.toAddress, !to.isEmpty else { return nil }
        return to
    }

    private var receivedAt: Date? {
        messageBody?.receivedAt ?? header?.receivedAt
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(subjectText).font(.title2).bold().textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Text(fromDisplay).font(.callout).textSelection(.enabled)
            if let toDisplay { Text(l10n.recipient(toDisplay)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            if let receivedAt {
                Text(receivedAt.formatted(date: .complete, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let snippet = header?.snippet ?? messageBody?.text {
                Text(snippet.prefix(140)).font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private var subjectText: String {
        messageBody?.subject ?? header?.subject ?? l10n.noSubject
    }

    private var fromDisplay: String {
        if let messageBody {
            return messageBody.fromName.map { "\($0) <\(messageBody.fromAddress)>" } ?? messageBody.fromAddress
        }
        if let header {
            return header.fromName.map { "\($0) <\(header.fromAddress)>" } ?? header.fromAddress
        }
        return l10n.unknownSender
    }

    private var bodySection: some View {
        Group {
            if isLoadingBody && messageBody == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(l10n.opening).foregroundStyle(.secondary)
                }
            } else if let bodyError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(bodyError).font(.headline)
                    Text(l10n.couldNotLoadMessage).font(.callout).foregroundStyle(.secondary)
                    Button(l10n.retry) { Task { await loadBody() } }
                }
            } else if let messageBody, !messageBody.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(messageBody.text).font(.body).lineSpacing(3).textSelection(.enabled)
            } else {
                Text(l10n.noPlainTextBody).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var summarySection: some View {
        switch summaryState {
        case .idle, .loading: EmptyView()
        case .unavailable:
            Text(l10n.aiNotConfigured).font(.callout).foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled)
        case .loaded(let summary):
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text(summary.summary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    if !summary.actionItems.isEmpty {
                        Divider()
                        Text(l10n.actionItems).font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(summary.actionItems.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 6) { Text("•"); Text(item).textSelection(.enabled) }
                        }
                    }
                    if let provider = summary.provider, !provider.isEmpty {
                        Text(l10n.viaProvider(provider)).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            } label: { Label(l10n.aiSummary, systemImage: "sparkles") }
        }
    }

    @ViewBuilder
    private var draftSection: some View {
        switch draftState {
        case .idle, .loading, .unavailable: EmptyView()
        case .failed(let message):
            Text(message).font(.callout).foregroundStyle(.red)
        case .loaded(let draft):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(l10n.draftVariants, systemImage: "text.bubble").font(.headline)
                    Spacer()
                    Button(l10n.pickOne) { showDraftPicker = true }
                        .buttonStyle(.borderedProminent)
                }
                ForEach(Array(draft.variants.enumerated()), id: \.offset) { index, variant in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(l10n.variant + " " + "\(index + 1)").font(.caption2).foregroundStyle(.secondary)
                        Text(variant).font(.callout).textSelection(.enabled).padding(8)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .padding(12)
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var draftPick: DraftReply? {
        if case .loaded(let d) = draftState { return d }
        return nil
    }

    private func handleDraftPick(variant: Int, pushToGmail: Bool) {
        guard let draft = draftPick else { return }
        showDraftPicker = false
        Task {
            do {
                _ = try await api.chooseDraft(
                    draftId: draft.id, variant: variant, pushToGmail: pushToGmail
                )
            } catch {
                draftState = .failed(l10n.draftFailed + error.lagoonUIMessage)
            }
        }
    }

    // MARK: - Actions

    private func loadBody() async {
        isLoadingBody = true
        bodyError = nil
        do {
            messageBody = try await api.fetchBody(remoteId: remoteId, accountId: accountId)
        } catch {
            bodyError = error.lagoonUIMessage
        }
        isLoadingBody = false
    }

    private func markReadOnce(force: Bool = false) async {
        if !force && didMarkRead { return }
        didMarkRead = true
        guard !isRead else { return }
        isRead = true
        onReadStateChange(remoteId, true)
        do { try await api.markRead(remoteId: remoteId, accountId: accountId) } catch {
            isRead = false
            onReadStateChange(remoteId, false)
            readError = l10n.markReadFailed + error.lagoonUIMessage
        }
    }

    private func togglePin() async {
        let target = !isPinned
        isPinned = target
        onPinnedChanged(target)
        isPinBusy = true
        do {
            try await api.setPinned(remoteId: remoteId, accountId: accountId, pinned: target)
        } catch {
            isPinned = !target
            onPinnedChanged(!target)
            pinError = (target ? l10n.pinFailed : l10n.unpinFailed) + error.lagoonUIMessage
        }
        isPinBusy = false
    }

    private func loadSummary() async {
        summaryState = .loading
        do {
            let summary = try await api.fetchSummary(
                remoteId: remoteId, accountId: accountId,
                language: l10n.language.rawValue
            )
            summaryState = .loaded(summary)
        } catch APIError.badStatus(let code, _) where code == 503 {
            summaryState = .unavailable
        } catch {
            summaryState = .failed(l10n.summaryFailed + error.lagoonUIMessage)
        }
    }

    private func generateDrafts() async {
        draftState = .loading
        do {
            let draft = try await api.generateDrafts(
                remoteId: remoteId, accountId: accountId,
                language: l10n.language.rawValue
            )
            draftState = .loaded(draft)
            showDraftPicker = true
        } catch APIError.badStatus(let code, _) where code == 503 {
            draftState = .unavailable
        } catch {
            draftState = .failed(l10n.draftFailed + error.lagoonUIMessage)
        }
    }

    private func archiveAndAdvance() async {
        do {
            let response = try await api.archiveMessage(remoteId: remoteId, accountId: accountId)
            onArchived?(remoteId, true)
            // Find the next sibling for auto-advance.
            if let siblings, let index = siblings.firstIndex(of: remoteId) {
                let nextIndex = siblings.index(after: index)
                if nextIndex < siblings.endIndex {
                    onAdvanceTo?(siblings[nextIndex])
                }
            }
            // Fetch the latest action so undo targets the right row.
            if let actions = try? await api.fetchActions(accountId: accountId, since: Date().addingTimeInterval(-30)),
               let latest = actions.first {
                let msg = response.remote ? l10n.archived : l10n.archivedLocallyOnly
                undo.show(UndoItem(id: latest.id, message: msg, systemImage: "tray.and.arrow.down"))
            }
        } catch {
            // leave the row in place; user can retry
        }
    }

    private func unsubscribe() async {
        do {
            let response = try await api.unsubscribeMessage(remoteId: remoteId, accountId: accountId)
            let msg = response.unsubscribed
                ? "\(l10n.unsubscribed) · \(response.publisher)"
                : "\(response.publisher) \(l10n.unsubscribed.lowercased()) — server kept it"
            if let actions = try? await api.fetchActions(accountId: accountId, since: Date().addingTimeInterval(-30)),
               let latest = actions.first {
                undo.show(UndoItem(id: latest.id, message: msg, systemImage: "minus.circle"))
            }
        } catch { }
    }

    private func overrideClassification(to group: BriefingGroup) {
        Task {
            do {
                try await api.overrideClassification(
                    remoteId: remoteId, accountId: accountId,
                    to: group
                )
            } catch { /* non-fatal */ }
        }
    }

    /// Announce the reply and clear itself: sending is final, so there is
    /// nothing to undo — only to confirm.
    private func showSentNotice() {
        sentNoticeDismiss?.cancel()
        sentNotice = l10n.sentTo(header?.fromAddress ?? "")
        sentNoticeDismiss = Task {
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            sentNotice = nil
        }
    }

    private func inlineNotice(
        _ message: String, systemImage: String, color: Color = .orange
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(color)
            Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Spacer()
        }
    }
}
