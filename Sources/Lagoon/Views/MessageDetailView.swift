import SwiftUI
import AppKit
import LagoonKit

/// Full message reader (spec §3). Loads body, fires markRead on appear,
/// and exposes the M2 actions: pin, archive, summarize, draft (3 variants),
/// override, unsubscribe.
struct MessageDetailView: View {
    let remoteId: String
    let accountId: UUID
    let header: MessageHeader?
    let initiallyPinned: Bool
    let initialGroup: BriefingGroup?
    /// Optional sibling list for j/k navigation and auto-advance on archive.
    var siblings: [String]? = nil
    /// Called after a successful archive/undo so the list row can disappear/return.
    var onArchived: ((String, Bool) -> Void)? = nil  // (remoteId, isArchived)
    var onReadStateChange: (String, Bool) -> Void = { _, _ in }
    var onPinnedChanged: (Bool) -> Void = { _ in }
    /// Called after a successful archive with the next sibling, or nil when
    /// the archived message was the last one in the current view.
    var onAdvanceTo: ((String?) -> Void)? = nil

    @State private var messageBody: MessageBody?
    @State private var isLoadingBody = true
    @State private var bodyError: String?
    /// M1.6: inline image attachments already fetched as `Data`, keyed by
    /// their `Content-ID` (angle brackets stripped, lowercased). The HTML
    /// renderer swaps `cid:` references for inline data URLs.
    @State private var inlineImageData: [String: Data] = [:]
    @State private var isLoadingInlineImages = false
    @State private var attachmentInFlight: String?

    @State private var isRead: Bool
    @State private var didMarkRead = false
    @State private var actionBanner: ErrorBanner?

    @State private var isPinned: Bool
    @State private var isPinBusy = false
    @State private var pinBanner: ErrorBanner?

    @State private var summaryState: SummaryState = .idle

    @State private var draftState: DraftState = .idle
    @State private var showDraftPicker = false
    @State private var selectedDraftBody = ""

    @State private var showOverrideMenu = false

    @State private var showComposer = false
    @State private var sentNotice: String?
    @State private var sentNoticeDismiss: Task<Void, Never>?

    @Environment(\.l10n) private var l10n
    @EnvironmentObject private var accounts: AccountStore
    @EnvironmentObject private var undo: UndoController
    @EnvironmentObject private var directory: DirectoryStore
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
        initialGroup: BriefingGroup? = nil,
        siblings: [String]? = nil,
        onArchived: ((String, Bool) -> Void)? = nil,
        onAdvanceTo: ((String?) -> Void)? = nil,
        onReadStateChange: @escaping (String, Bool) -> Void = { _, _ in },
        onPinnedChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.remoteId = remoteId
        self.accountId = accountId
        self.header = header
        self.initiallyPinned = initiallyPinned
        self.initialGroup = initialGroup
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
                if let sentNotice {
                    inlineNotice(sentNotice, systemImage: "paperplane.fill", color: .green)
                }
                summarySection
                draftSection
                Divider()
                bodySection
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationTitle(subjectText)
        .toolbar { toolbarContent }
        .noticeBanner($actionBanner)
        .noticeBanner($pinBanner)
        .task {
            await loadBody()
            if bodyError == nil {
                await markReadOnce()
            }
        }
        .sheet(isPresented: $showDraftPicker) {
            if let draft = draftPick {
                DraftPickerSheet(
                    draft: draft,
                    provider: directory.active?.provider ?? .gmail,
                    onPick: handleDraftPick
                )
            }
        }
        .sheet(isPresented: $showComposer) {
            ComposerSheet(
                remoteId: remoteId,
                accountId: accountId,
                to: messageBody?.fromAddress ?? header?.fromAddress ?? "",
                subject: subjectText,
                initialBody: selectedDraftBody,
                quotedText: messageBody?.text ?? ""
            ) { _ in
                showSentNotice()
            }
        }
        .confirmationDialog(l10n.overrideGroup, isPresented: $showOverrideMenu, titleVisibility: .visible) {
            ForEach(
                BriefingGroup.allCases.filter { $0 != .pinned && $0 != initialGroup },
                id: \.self
            ) { group in
                Button(l10n.groupTitle(group)) { overrideClassification(to: group) }
            }
            Button(l10n.cancel, role: .cancel) {}
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
                if isPinBusy {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(l10n.pinning)
                    }
                } else {
                    Label(isPinned ? l10n.unpin : l10n.pin, systemImage: isPinned ? "pin.slash" : "pin")
                }
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
                    .frame(minWidth: 110, alignment: .leading)
                } else {
                    Label(l10n.summarize, systemImage: "sparkles")
                        .frame(minWidth: 110, alignment: .leading)
                }
            }
            .disabled(summaryState == .loading)
            .help(l10n.summarizeHelp)
            .keyboardShortcut("d", modifiers: .command)

            Button { Task { await generateDrafts() } } label: {
                if draftState == .loading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(l10n.generatingDrafts)
                    }
                } else {
                    Label(l10n.draftVariants, systemImage: "text.bubble")
                }
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
                Label(l10n.moreActions, systemImage: "ellipsis.circle")
            }

            Button { Task { await archiveAndAdvance() } } label: {
                Label(l10n.archiveAndNext, systemImage: "tray.and.arrow.down")
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(!canArchive)
            .help(canArchive ? l10n.shortcutArchiveNext : l10n.archiveUnavailable)

            Button { Task { await downloadRawEml() } } label: {
                Label(l10n.downloadEml, systemImage: "square.and.arrow.down")
            }
            .help(l10n.downloadEmlHelp)
        }
    }

    // MARK: - Sections

    /// Negotiated on the server and read from the account row. While the
    /// directory has not loaded yet (or no account is connected) we do not
    /// pretend archiving is impossible: the server is the authority and
    /// answers 409 archive-unavailable if it really is.
    private var canArchive: Bool {
        directory.active?.capabilities.archiveFolder ?? true
    }

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
                Text(snippet.prefix(140)).font(.caption).foregroundStyle(.secondary)
            }
        }
        // Metadata is a header strip — wide subject lines look broken when
        // they wrap, so cap the column at 900pt. The body below gets the
        // full window width; HTML email clients expect that.
        .frame(maxWidth: 900, alignment: .leading)
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
            } else if let messageBody {
                bodyContent(for: messageBody)
                if !messageBody.attachments.isEmpty {
                    attachmentsSection(messageBody.attachments)
                }
            } else {
                Text(l10n.noPlainTextBody).foregroundStyle(.secondary)
            }
        }
    }

    /// HTML when present, otherwise the plain-text fallback. HTML renders in
    /// a sandboxed WKWebView (no JS, no baseURL); the inline-image cid
    /// references are resolved client-side via `inlineImageData`. The
    /// WebView grows with its content — a long HTML email fills the
    /// window, a short one is short; the surrounding `ScrollView` handles
    /// scrolling either way.
    @ViewBuilder
    private func bodyContent(for body: MessageBody) -> some View {
        if let html = body.html, !html.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HTMLMessageView(html: html, attachmentsByCid: inlineImageData)
                    .frame(minHeight: 200)
                if isLoadingInlineImages {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(l10n.loadingInlineImages)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else if !body.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(body.text)
                .font(.body)
                .lineSpacing(3)
                .textSelection(.enabled)
        } else {
            Text(l10n.noPlainTextBody).foregroundStyle(.secondary)
        }
    }

    private func attachmentsSection(_ attachments: [Attachment]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().padding(.vertical, 4)
            Text(l10n.attachments)
                .font(.headline)
            ForEach(attachments) { attachment in
                attachmentRow(attachment)
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func attachmentRow(_ attachment: Attachment) -> some View {
        HStack(spacing: 10) {
            Image(systemName: iconName(for: attachment.mimeType))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.filename ?? attachment.mimeType)
                    .font(.callout)
                    .lineLimit(1)
                Text(humanReadableSize(attachment.size))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if attachmentInFlight == attachment.id {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await downloadAttachment(attachment) }
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(l10n.download)
                .help(l10n.download)
            }
        }
        .padding(.vertical, 2)
    }

    private func iconName(for mimeType: String) -> String {
        if mimeType.hasPrefix("image/") { return "photo" }
        if mimeType.hasPrefix("video/") { return "film" }
        if mimeType.hasPrefix("audio/") { return "waveform" }
        if mimeType.hasPrefix("text/") { return "doc.text" }
        if mimeType == "application/pdf" { return "doc.richtext" }
        if mimeType.contains("zip") || mimeType.contains("compressed") { return "doc.zipper" }
        return "paperclip"
    }

    private func humanReadableSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    /// User chose an attachment: fetch its bytes, prompt for save path,
    /// write the file. Uses `NSSavePanel` so the user gets the native
    /// macOS file dialog and can route the file into Downloads, iCloud,
    /// an SMB share, or a project folder.
    private func downloadAttachment(_ attachment: Attachment) async {
        guard attachmentInFlight == nil else { return }
        attachmentInFlight = attachment.id
        defer { attachmentInFlight = nil }
        do {
            let result = try await api.downloadAttachment(
                accountId: accountId,
                remoteId: remoteId,
                attachmentId: attachment.id
            )
            let panel = NSSavePanel()
            panel.allowedContentTypes = []
            panel.nameFieldStringValue = result.filename ?? "attachment"
            panel.canCreateDirectories = true
            let response = await panel.beginSheetModal(for: NSApp.keyWindow ?? NSApp.mainWindow!)
            guard response == .OK, let url = panel.url else { return }
            try result.data.write(to: url)
        } catch {
            actionBanner = ErrorBanner(
                severity: .error,
                title: l10n.downloadFailed,
                detail: error.lagoonUIMessage
            )
        }
    }

    /// Export the original `.eml` source for the message. Same download
    /// path as attachments but the bytes come from `/raw.eml`.
    private func downloadRawEml() async {
        do {
            let data = try await api.downloadRawMessage(
                accountId: accountId,
                remoteId: remoteId
            )
            let panel = NSSavePanel()
            panel.nameFieldStringValue = (messageBody?.subject ?? "message") + ".eml"
            panel.canCreateDirectories = true
            let response = await panel.beginSheetModal(for: NSApp.keyWindow ?? NSApp.mainWindow!)
            guard response == .OK, let url = panel.url else { return }
            try data.write(to: url)
        } catch {
            actionBanner = ErrorBanner(
                severity: .error,
                title: l10n.downloadFailed,
                detail: error.lagoonUIMessage
            )
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
                selectedDraftBody = draft.variants.indices.contains(variant)
                    ? draft.variants[variant]
                    : ""
                showComposer = true
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
        // M1.6: pull inline image bytes so the WKWebView can resolve
        // `cid:` references. Fire-and-forget — body text is already
        // visible; this just upgrades HTML rendering once bytes arrive.
        if let body = messageBody, !body.inlineImageAttachments.isEmpty {
            await loadInlineImages(body.inlineImageAttachments)
        }
    }

    private func loadInlineImages(_ attachments: [Attachment]) async {
        isLoadingInlineImages = true
        defer { isLoadingInlineImages = false }
        await withTaskGroup(of: (String, Data?).self) { group in
            for attachment in attachments {
                let cidKey = attachment.contentId?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let key = cidKey, !key.isEmpty else { continue }
                group.addTask { [accountId, remoteId, attachment] in
                    do {
                        let result = try await api.downloadAttachment(
                            accountId: accountId,
                            remoteId: remoteId,
                            attachmentId: attachment.id
                        )
                        return (key, result.data)
                    } catch {
                        return (key, nil)
                    }
                }
            }
            for await (key, data) in group {
                if let data {
                    inlineImageData[key.lowercased()] = data
                }
            }
        }
    }

    private func markReadOnce(force: Bool = false) async {
        if !force && didMarkRead { return }
        didMarkRead = true
        guard !isRead else { return }
        isRead = true
        onReadStateChange(remoteId, true)
        do {
            try await api.markRead(remoteId: remoteId, accountId: accountId)
        } catch {
            isRead = false
            onReadStateChange(remoteId, false)
            actionBanner = ErrorBanner(
                severity: .error,
                title: l10n.markReadFailedTitle,
                detail: l10n.markReadFailedDetail,
                actionLabel: l10n.retry,
                action: { [self] in await self.markReadOnce(force: true) }
            )
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
            pinBanner = ErrorBanner(
                severity: .error,
                title: target ? l10n.pinFailed : l10n.unpinFailed,
                actionLabel: l10n.retry,
                action: { [self] in await self.togglePin() }
            )
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
            // Find the next sibling for auto-advance. A nil tells the parent
            // to close the detail view instead of leaving an archived message onscreen.
            var next: String?
            if let siblings, let index = siblings.firstIndex(of: remoteId) {
                let nextIndex = siblings.index(after: index)
                if nextIndex < siblings.endIndex {
                    next = siblings[nextIndex]
                }
            }
            onAdvanceTo?(next)
            undo.show(UndoItem(
                id: response.actionId,
                message: l10n.archived,
                systemImage: "tray.and.arrow.down"
            ))
        } catch {
            actionBanner = ErrorBanner(
                severity: .error,
                title: l10n.archiveFailedTitle,
                detail: l10n.archiveFailedDetail,
                actionLabel: l10n.retry,
                action: { [self] in await self.archiveAndAdvance() }
            )
        }
    }

    private func unsubscribe() async {
        do {
            let response = try await api.unsubscribeMessage(remoteId: remoteId, accountId: accountId)
            let msg = response.unsubscribed
                ? "\(l10n.unsubscribed) · \(response.publisher)"
                : "\(response.publisher) \(l10n.unsubscribed.lowercased()) — server kept it"
            undo.show(UndoItem(
                id: response.actionId,
                message: msg,
                systemImage: "minus.circle"
            ))
        } catch {
            if let code = (error as? APIError)?.serverErrorCode {
                if code == "unsubscribe-manual-required" {
                    actionBanner = ErrorBanner(
                        severity: .error,
                        title: l10n.unsubscribeFailedTitle,
                        detail: l10n.unsubscribeManualRequired,
                        actionLabel: l10n.openOriginal,
                        action: { [self] in self.openOriginalMail() }
                    )
                } else if code == "unsubscribe-unavailable" {
                    actionBanner = ErrorBanner(
                        severity: .error,
                        title: l10n.unsubscribeFailedTitle,
                        detail: l10n.unsubscribeUnavailable
                    )
                } else {
                    actionBanner = ErrorBanner(
                        severity: .error,
                        title: l10n.unsubscribeFailedTitle,
                        detail: l10n.unsubscribeFailedDetail,
                        actionLabel: l10n.retry,
                        action: { [self] in await self.unsubscribe() }
                    )
                }
            } else {
                actionBanner = ErrorBanner(
                    severity: .error,
                    title: l10n.unsubscribeFailedTitle,
                    detail: l10n.unsubscribeFailedDetail,
                    actionLabel: l10n.retry,
                    action: { [self] in await self.unsubscribe() }
                )
            }
        }
    }

    private func openOriginalMail() {
        // No-op stub: the original-message URL would come from the message
        // header. Wiring this requires a `MessageHeader.messageWebLink`
        // the server doesn't yet emit. Spec §6.2 keeps the affordance so
        // the user can find the path; the action itself is a follow-up.
    }

    private func overrideClassification(to group: BriefingGroup) {
        Task {
            do {
                try await api.overrideClassification(
                    remoteId: remoteId, accountId: accountId,
                    from: initialGroup,
                    to: group
                )
                actionBanner = nil
                showTransientNotice(l10n.overrideApplied)
                NotificationCenter.default.post(name: .lagoonDidChangeData, object: nil)
            } catch {
                actionBanner = ErrorBanner(
                    severity: .error,
                    title: l10n.overrideGroupFailedTitle,
                    detail: l10n.overrideGroupFailedDetail,
                    actionLabel: l10n.retry,
                    action: { [self] in await self.overrideClassification(to: group) }
                )
            }
        }
    }

    /// Announce the reply and clear itself: sending is final, so there is
    /// nothing to undo — only to confirm.
    private func showSentNotice() {
        showTransientNotice(l10n.sentTo(messageBody?.fromAddress ?? header?.fromAddress ?? ""))
    }

    private func showTransientNotice(_ message: String) {
        sentNoticeDismiss?.cancel()
        sentNotice = message
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
