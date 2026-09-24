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
    /// The rendered HTML document height, reported by `HTMLMessageView`.
    /// Reset when the message changes so a tall email does not leave a
    /// gap under the next short one.
    @State private var htmlContentHeight: CGFloat = 0
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
    /// Which composer variant the toolbar button opened. `.reply` keeps
    /// the pre-M1.7 single-recipient path; `.replyAll` adds the other
    /// To/Cc addresses minus self; `.forward` opens the new-message
    /// composer pre-filled with the quoted original.
    @State private var composerMode: ComposerMode = .reply
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

    /// Which composer the toolbar opened. Drives the recipient set the
    /// sheet sends: Reply keeps the default envelope; ReplyAll overrides
    /// it with `to` + `cc` minus self; Forward opens the compose sheet.
    private enum ComposerMode: Equatable {
        case reply
        case replyAll
        case forward
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

    /// Reading-column width. Matches Mail.app / Superhuman defaults; anything
    /// wider makes the subject / from / body sit visually disconnected and
    /// the body fill the full window like a stretched banner.
    private static let readingColumnWidth: CGFloat = 900

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
            // Frame order is load-bearing — a frame probe caught the wrong
            // order shipping once: `.frame(maxWidth: 900, alignment:)`
            // only arranges children *inside* the 900pt box, and this
            // VStack always fills that box, so the alignment can never
            // move the column. Cap first (inner frame), then fill the
            // window and center the capped column (outer frame). The cap
            // itself stays: full-bleed text on ultrawide hurts readability
            // — the fix is symmetric whitespace, not wider text. `.top` =
            // horizontal center + vertical pin (height is unbounded inside
            // the ScrollView, so the vertical half is belt-and-braces).
            .frame(maxWidth: Self.readingColumnWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
            switch composerMode {
            case .reply, .replyAll:
                ComposerSheet(
                    remoteId: remoteId,
                    accountId: accountId,
                    to: replyRecipients.joined(separator: ", "),
                    cc: composerMode == .replyAll ? replyCcRecipients : [],
                    subject: subjectText,
                    initialBody: selectedDraftBody,
                    quotedText: messageBody?.text ?? ""
                ) { _ in
                    showSentNotice()
                }
            case .forward:
                // Forward reuses the compose sheet (arbitrary recipient,
                // editable To). The original is quoted so the recipient
                // has the context; the Fwd: prefix follows the same
                // de-dup rule as Re:.
                NewMessageSheet(
                    accountId: accountId,
                    prefillTo: "",
                    prefillSubject: forwardSubject,
                    prefillBody: Self.formatForwardBody(
                        from: messageBody?.fromAddress ?? header?.fromAddress ?? "",
                        date: receivedAt,
                        subject: subjectText,
                        body: messageBody?.text ?? ""
                    )
                ) { _ in
                    showSentNotice()
                }
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
        // Three sections, left-to-right, each visually separated so a power
        // user can park their mouse on the right cluster (Archive & Next) and
        // not lose the thread when the toolbar overflows on narrow windows.
        //
        //   [Pin]  |  [Reply · ReplyAll · Forward]  |  [Archive & Next]  [⋯]
        //
        // Summarize, Generate Drafts, Download .eml, Mark Read, Override and
        // Unsubscribe all move into the ⋯ menu — they remain keyboard-
        // accessible via ⌘D / ⇧⌘D but no longer compete for toolbar space.
        // Less common actions stop costing pixels in the always-visible strip.

        ToolbarItem(placement: .navigation) {
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
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button { composerMode = .reply; showComposer = true } label: {
                Label(l10n.reply, systemImage: "arrowshape.turn.up.left")
            }
            .help(l10n.replyHelp)
            .keyboardShortcut("r", modifiers: .command)

            Button { composerMode = .replyAll; showComposer = true } label: {
                Label(l10n.replyAll, systemImage: "arrowshape.turn.up.left.2")
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(messageBody == nil)
            .help(l10n.replyAllHelp)

            Button { composerMode = .forward; showComposer = true } label: {
                Label(l10n.forward, systemImage: "arrowshape.turn.up.right")
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(messageBody == nil)
            .help(l10n.forwardHelp)
        }

        ToolbarItem(placement: .primaryAction) {
            // Archive & Next is the rightmost (primary) action: when the
            // toolbar overflows, this is the last button to disappear.
            Button { Task { await archiveAndAdvance() } } label: {
                Label(l10n.archiveAndNext, systemImage: "tray.and.arrow.down")
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(!canArchive)
            .help(canArchive ? l10n.shortcutArchiveNext : l10n.archiveUnavailable)
        }

        ToolbarItem(placement: .primaryAction) {
            // The overflow menu gathers Summarize / Drafts / Download /
            // Mark Read / Override / Unsubscribe. Each keeps its keyboard
            // shortcut so a power user never has to open it.
            Menu {
                Button { Task { await loadSummary() } } label: {
                    if summaryState == .loading {
                        Label(l10n.summarizing, systemImage: "sparkles")
                    } else {
                        Label(l10n.summarize, systemImage: "sparkles")
                    }
                }
                .disabled(summaryState == .loading)
                .keyboardShortcut("d", modifiers: .command)

                Button { Task { await generateDrafts() } } label: {
                    if draftState == .loading {
                        Label(l10n.generatingDrafts, systemImage: "text.bubble")
                    } else {
                        Label(l10n.draftVariants, systemImage: "text.bubble")
                    }
                }
                .disabled(draftState == .loading)
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Divider()

                Button(l10n.markRead) { Task { await markReadOnce(force: true) } }
                    .disabled(isRead)
                Button(l10n.overrideGroup) { showOverrideMenu = true }
                Button(l10n.unsubscribe, role: .destructive) { Task { await unsubscribe() } }
                    .disabled(header == nil)

                Divider()

                Button(l10n.downloadEml) { Task { await downloadRawEml() } }
                    .help(l10n.downloadEmlHelp)
            } label: {
                Label(l10n.moreActions, systemImage: "ellipsis.circle")
            }
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

    /// The recipient line in the metadata block. Prefers the parsed `to`
    /// array (M1.7); falls back to the legacy single `toAddress` so a
    /// response from an older server still renders something.
    private var toDisplay: String? {
        if let body = messageBody, !body.to.isEmpty {
            return body.to.joined(separator: ", ")
        }
        guard let to = messageBody?.toAddress, !to.isEmpty else { return nil }
        return to
    }

    /// The Cc line, when the message has one. Rendered as its own row so a
    /// long Cc list wraps without pushing the To line off screen.
    private var ccDisplay: String? {
        guard let body = messageBody, !body.cc.isEmpty else { return nil }
        return body.cc.joined(separator: ", ")
    }

    private var receivedAt: Date? {
        messageBody?.receivedAt ?? header?.receivedAt
    }

    private var metadata: some View {
        // Header card: same GroupBox language as the AI summary below, so
        // the top of the page looks designed instead of naked text on glass.
        // Width comes from the parent `body`'s reading-column frame — no
        // need to repeat it here.
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                // Sender not loaded yet (body still in flight, header nil):
                // skip the avatar — SenderAvatar's "?" fallback reads as
                // an error state; this is just "not loaded yet".
                if !senderEmail.isEmpty {
                    SenderAvatar(email: senderEmail, displayName: senderName)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(subjectText).font(.title2).bold().textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Text(fromDisplay).font(.callout).textSelection(.enabled)
                    if let toDisplay { Text(l10n.recipient(toDisplay)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    if let ccDisplay { Text("\(l10n.replyCc): \(ccDisplay)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    if let receivedAt {
                        Text(receivedAt.formatted(date: .complete, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let snippet = header?.snippet ?? messageBody?.text {
                        Text(snippet.prefix(140)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// Raw sender identity for the avatar (fromDisplay folds name+address
    /// into one string, which the avatar cannot use).
    private var senderEmail: String {
        messageBody?.fromAddress ?? header?.fromAddress ?? ""
    }

    private var senderName: String? {
        messageBody?.fromName ?? header?.fromName
    }

    private var subjectText: String {
        messageBody?.subject ?? header?.subject ?? l10n.noSubject
    }

    /// Reply-all `To:` — the original sender first (that is who a reply
    /// goes to), then every other `To` address minus ourselves. The
    /// server does the self-filtering again on its side; doing it here
    /// too keeps the composer's read-only display honest.
    private var replyRecipients: [String] {
        let sender = messageBody?.fromAddress ?? header?.fromAddress ?? ""
        guard composerMode == .replyAll, let body = messageBody else {
            return sender.isEmpty ? [] : [sender]
        }
        let selfAddress = directory.active?.email.lowercased() ?? ""
        var seen = Set<String>()
        var result: [String] = []
        for address in [sender] + body.to {
            let lower = address.lowercased()
            guard !lower.isEmpty, lower != selfAddress, !seen.contains(lower) else { continue }
            seen.insert(lower)
            result.append(address)
        }
        return result
    }

    /// Reply-all `Cc:` — the original Cc list minus self and minus anyone
    /// already on the To line.
    private var replyCcRecipients: [String] {
        guard composerMode == .replyAll, let body = messageBody else { return [] }
        let selfAddress = directory.active?.email.lowercased() ?? ""
        let toSet = Set(replyRecipients.map { $0.lowercased() })
        return body.cc.filter {
            let lower = $0.lowercased()
            return lower != selfAddress && !toSet.contains(lower)
        }
    }

    private var forwardSubject: String {
        let base = messageBody?.subject ?? header?.subject ?? ""
        if base.lowercased().hasPrefix("fwd:") { return base }
        return base.isEmpty ? "Fwd:" : "Fwd: \(base)"
    }

    /// The quoted block a forward carries. Mirrors the reply quote
    /// convention (`> ` prefix) but with a header block naming the
    /// original sender and date — a forwarded message usually lands in
    /// front of someone who has no context.
    static func formatForwardBody(
        from: String,
        date: Date?,
        subject: String,
        body: String
    ) -> String {
        var header = "\n\n---------- Forwarded message ----------\n"
        header += "From: \(from)\n"
        if let date {
            header += "Date: \(date.formatted(date: .complete, time: .standard))\n"
        }
        header += "Subject: \(subject)\n\n"
        let quoted = body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? ">" : "> \($0)" }
            .joined(separator: "\n")
        return header + quoted
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
                // The WebView reports its rendered document height back so
                // this frame matches content exactly — one outer scroller.
                // The 80pt floor covers only the layout pass before the
                // first measurement lands. If measurement fails
                // *permanently*, HTMLMessageView restores its own internal
                // scrolling after a 1s grace period rather than clipping
                // content behind an invisible wall.
                HTMLMessageView(
                    html: html,
                    attachmentsByCid: inlineImageData,
                    contentHeight: $htmlContentHeight
                )
                .frame(height: max(80, htmlContentHeight))
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
        GroupBox {
            ForEach(Array(attachments.enumerated()), id: \.element.id) { index, attachment in
                if index > 0 { Divider() }
                attachmentRow(attachment)
            }
        } label: {
            Label(l10n.attachments, systemImage: "paperclip")
        }
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
        } catch let apiError as APIError {
            switch Self.aiFailureKind(for: apiError) {
            case .notConfigured:
                summaryState = .unavailable
            case .specific(let message):
                summaryState = .failed(message)
            case .none:
                summaryState = .failed(l10n.summaryFailed + apiError.lagoonUIMessage)
            }
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
        } catch let apiError as APIError {
            switch Self.aiFailureKind(for: apiError) {
            case .notConfigured:
                // AI is off by config; render the muted "AI not configured"
                // hint rather than a red error.
                draftState = .unavailable
            case .specific(let message):
                draftState = .failed(message)
            case .none:
                draftState = .failed(l10n.draftFailed + apiError.lagoonUIMessage)
            }
        } catch {
            draftState = .failed(l10n.draftFailed + error.lagoonUIMessage)
        }
    }

    /// The AI endpoints answer 503 with three distinct, actionable codes
    /// (`ai-credit-exhausted` / `ai-budget-exceeded` / `ai-circuit-open`)
    /// plus the benign `ai-not-configured`. Before this, every 503 was
    /// folded into "AI not configured" — so a billing failure looked
    /// like a configuration switch and the user never saw the reason.
    private enum AIFailureKind {
        case notConfigured
        case specific(String)
        case none
    }

    private static func aiFailureKind(for error: APIError) -> AIFailureKind {
        switch error.serverErrorCode {
        case "ai-not-configured": return .notConfigured
        case "ai-credit-exhausted": return .specific(L10n.current.aiCreditExhausted)
        case "ai-budget-exceeded": return .specific(L10n.current.aiBudgetExceeded)
        case "ai-circuit-open": return .specific(L10n.current.aiCircuitOpen)
        default: return .none
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
