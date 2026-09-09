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
                    Label(isPinned ? "取消置顶" : "置顶", systemImage: isPinned ? "pin.slash" : "pin")
                }
                .disabled(isPinBusy)
                .help(isPinned ? "取消置顶这封邮件" : "置顶这封邮件")

                Button {
                    Task { await loadSummary() }
                } label: {
                    if summaryState == .loading {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("正在生成摘要…")
                        }
                    } else {
                        Label("生成摘要", systemImage: "sparkles")
                    }
                }
                .disabled(summaryState == .loading)
                .help("让服务器生成 AI 摘要和行动项")
            }
        }
        .task { await loadBody() }
        .task { await markReadOnce() }
    }

    // MARK: - Metadata

    private var subjectText: String {
        messageBody?.subject ?? header?.subject ?? "（无主题）"
    }

    private var fromDisplay: String {
        if let messageBody {
            return messageBody.fromName.map { "\($0) <\(messageBody.fromAddress)>" } ?? messageBody.fromAddress
        }
        if let header {
            return header.fromName.map { "\($0) <\(header.fromAddress)>" } ?? header.fromAddress
        }
        return "未知发件人"
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
                Text("收件人 \(toDisplay)")
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
                Text("正在加载邮件…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let bodyError {
            VStack(alignment: .leading, spacing: 8) {
                Text("无法加载这封邮件")
                    .font(.headline)
                Text(bodyError)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("重试") { Task { await loadBody() } }
            }
        } else if let messageBody {
            if messageBody.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("这封邮件没有纯文本正文。")
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
                Text("正在生成摘要…").foregroundStyle(.secondary)
            }
        case .unavailable:
            // 503 is a configuration state, not a failure: keep it muted.
            Text("AI 未配置（缺少 LLM_PROVIDER_PRIMARY_API_KEY）")
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
                        Text("行动项")
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
                        Text("由 \(provider) 生成")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label("AI 摘要", systemImage: "sparkles")
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
            readError = "标记已读失败：\(error.lagoonUIMessage)"
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
            pinError = "\(target ? "置顶" : "取消置顶")失败：\(error.lagoonUIMessage)"
        }
        isPinBusy = false
    }

    private func loadSummary() async {
        guard summaryState != .loading else { return }
        summaryState = .loading
        do {
            summaryState = .loaded(try await api.fetchSummary(gmailId: gmailId, accountId: accountId))
        } catch APIError.badStatus(let code, _) where code == 503 {
            summaryState = .unavailable
        } catch {
            summaryState = .failed("摘要失败：\(error.lagoonUIMessage)")
        }
    }
}
