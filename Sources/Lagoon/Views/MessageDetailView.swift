import SwiftUI
import LagoonKit

/// Full message reader (spec §3): subject, sender, date and the plain-text body
/// in a readable column. Fires `markRead` once on appear, offers pin/unpin, and
/// can ask the server for an AI summary + action items.
struct MessageDetailView: View {
    let gmailId: String
    let accountId: UUID
    let header: MessageHeader?
    let initiallyPinned: Bool

    /// Called when the optimistic read flip succeeds or is reverted, so the
    /// feed row reflects the change without a full refresh.
    var onReadStateChange: (String, Bool) -> Void = { _, _ in }
    /// Called after a successful pin change so the feed can re-group.
    var onPinnedChanged: (Bool) -> Void = { _ in }

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

    @Environment(\.l10n) private var l10n
    private let api = APIClient()

    private enum SummaryState: Equatable {
        case idle
        case loading
        case loaded(MessageSummary)
        /// Server answered 503: no LLM provider configured.
        case unavailable
        case failed(String)
    }

    init(
        gmailId: String,
        accountId: UUID,
        header: MessageHeader?,
        initiallyPinned: Bool,
        onReadStateChange: @escaping (String, Bool) -> Void = { _, _ in },
        onPinnedChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.gmailId = gmailId
        self.accountId = accountId
        self.header = header
        self.initiallyPinned = initiallyPinned
        self.onReadStateChange = onReadStateChange
        self.onPinnedChanged = onPinnedChanged
        _isRead = State(initialValue: header?.isRead ?? false)
        _isPinned = State(initialValue: initiallyPinned)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                metadata
                if let readError {
                    inlineNotice(readError, systemImage: "envelope.badge")
                }
                if let pinError {
                    inlineNotice(pinError, systemImage: "pin.slash")
                }
                summarySection
                Divider()
                bodySection
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .navigationTitle(subjectText)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await togglePin() }
                } label: {
                    Label(isPinned ? l10n.unpin : l10n.pin, systemImage: isPinned ? "pin.slash" : "pin")
                }
                .disabled(isPinBusy)
                .help(isPinned ? l10n.unpinHelp : l10n.pinHelp)

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
            }
        }
        .task { await loadBody() }
        .task { await markReadOnce() }
    }

    // MARK: - Metadata

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

    private var toDisplay: String? {
        guard let to = messageBody?.toAddress, !to.isEmpty else { return nil }
        return to
    }

    private var receivedAt: Date? {
        messageBody?.receivedAt ?? header?.receivedAt
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(subjectText)
                .font(.title2)
                .bold()
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(fromDisplay)
                .font(.callout)
                .textSelection(.enabled)

            if let toDisplay {
                Text(l10n.recipient(toDisplay))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let receivedAt {
                Text(receivedAt.formatted(date: .complete, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Body

    @ViewBuilder
    private var bodySection: some View {
        if isLoadingBody && messageBody == nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(l10n.loadingMessage).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let bodyError {
            VStack(alignment: .leading, spacing: 8) {
                Text(l10n.couldNotLoadMessage)
                    .font(.headline)
                Text(bodyError)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button(l10n.retry) { Task { await loadBody() } }
            }
        } else if let messageBody {
            if messageBody.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(l10n.noPlainTextBody)
                    .foregroundStyle(.secondary)
            } else {
                Text(messageBody.text)
                    .font(.body)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Summary

    @ViewBuilder
    private var summarySection: some View {
        switch summaryState {
        case .idle:
            EmptyView()
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(l10n.summarizing).foregroundStyle(.secondary)
            }
        case .unavailable:
            // 503 is a configuration state, not a failure: keep it muted.
            Text(l10n.aiNotConfigured)
                .font(.callout)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        case .loaded(let summary):
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text(summary.summary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if !summary.actionItems.isEmpty {
                        Divider()
                        Text(l10n.actionItems)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(Array(summary.actionItems.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("•")
                                Text(item)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }

                    if let provider = summary.provider, !provider.isEmpty {
                        Text(l10n.viaProvider(provider))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label(l10n.aiSummary, systemImage: "sparkles")
            }
        }
    }

    private func inlineNotice(_ message: String, systemImage: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer()
        }
    }

    // MARK: - Actions

    private func loadBody() async {
        isLoadingBody = true
        bodyError = nil
        do {
            messageBody = try await api.fetchBody(gmailId: gmailId, accountId: accountId)
        } catch {
            bodyError = error.lagoonUIMessage
        }
        isLoadingBody = false
    }

    /// Fires exactly once per appearance. The feed row flips immediately; if the
    /// call fails we revert the row and surface the reason.
    private func markReadOnce() async {
        guard !didMarkRead else { return }
        didMarkRead = true
        guard !isRead else { return }

        isRead = true
        readError = nil
        onReadStateChange(gmailId, true)

        do {
            try await api.markRead(gmailId: gmailId, accountId: accountId)
        } catch {
            isRead = false
            onReadStateChange(gmailId, false)
            readError = l10n.markReadFailed + error.lagoonUIMessage
        }
    }

    private func togglePin() async {
        guard !isPinBusy else { return }
        let target = !isPinned
        isPinned = target
        isPinBusy = true
        pinError = nil
        do {
            try await api.setPinned(gmailId: gmailId, accountId: accountId, pinned: target)
            onPinnedChanged(target)
        } catch {
            isPinned = !target
            pinError = (target ? l10n.pinFailed : l10n.unpinFailed) + error.lagoonUIMessage
        }
        isPinBusy = false
    }

    private func loadSummary() async {
        guard summaryState != .loading else { return }
        summaryState = .loading
        do {
            summaryState = .loaded(try await api.fetchSummary(
                gmailId: gmailId,
                accountId: accountId,
                language: l10n.language.rawValue
            ))
        } catch APIError.badStatus(let code, _) where code == 503 {
            summaryState = .unavailable
        } catch {
            summaryState = .failed(l10n.summaryFailed + error.lagoonUIMessage)
        }
    }
}
