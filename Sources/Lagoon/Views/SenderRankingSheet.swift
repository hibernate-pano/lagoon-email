import SwiftUI
import LagoonKit

/// 发件人排行 — who writes to this mailbox, ranked by volume.
///
/// ## Why this panel exists
///
/// This is the one question a per-message classifier cannot answer. Every row
/// the feed shows is judged on its own merits; nothing in the feed says "this
/// one sender has written to you 340 times and you have opened none of them".
/// Inbox Zero's most-used feature is exactly that ranking, and Foxmail / QQ邮箱
/// both approximate it with filters — but Lagoon had the data and no way to see
/// it.
///
/// ## What it deliberately does not do
///
/// No bulk archive, no bulk unsubscribe, no auto-rule. The panel names what it
/// found and offers two routes to act, both of which land on the ordinary
/// user-triggered flows: open the sender's mail (`SenderSheet`), or file them
/// into a 聚合规则 (the existing stack editor). A panel that could empty a
/// sender's mail on one click would be an auto-archive with a ranking on top —
/// constitution §2 rule 5 rules that out, and a newsletter you never read is
/// still a decision you get to make.
struct SenderRankingSheet: View {
    let accountId: UUID
    /// Called when the user picks a sender to file. Left to the caller because
    /// creating a rule needs the stack editor, which lives on the list surface.
    var onFileSender: (SenderSummary) -> Void = { _ in }
    /// Opens one sender's full history.
    var onOpenSender: (SenderSummary) -> Void = { _ in }

    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var undo: UndoController

    @State private var senders: [SenderSummary] = []
    @State private var query = ""
    @State private var isLoading = true
    @State private var errorBanner: ErrorBanner?
    /// The address a rule was just created for, so the row can confirm instead
    /// of appearing to do nothing.
    @State private var filedAddress: String?
    /// Set when the list came back empty *because of a filter*, so the empty
    /// state can say "no sender matches" rather than "nobody writes to you" —
    /// which would be a lie when the mailbox is simply not loaded yet.
    @State private var isFiltered = false

    private let api = APIClient.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 620, height: 520)
        .task { await load() }
    }

    // MARK: - Chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(l10n.senderRankingTitle, systemImage: "person.2")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
                .help(l10n.refresh)
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(l10n.dismiss)
            }
            // The panel's one-line thesis, stated once. Without it the numbers
            // below are a table; with it they are a decision.
            Text(l10n.senderRankingBlurb)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            searchField
        }
        .padding(16)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(l10n.senderRankingSearch, text: $query)
                .textFieldStyle(.plain)
                .onSubmit { Task { await load() } }
            if !query.isEmpty {
                Button {
                    query = ""
                    Task { await load() }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(l10n.clearSelection)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let errorBanner, senders.isEmpty {
            NoticeBannerView(banner: errorBanner) { self.errorBanner = nil }
                .padding(16)
        } else if isLoading, senders.isEmpty {
            ProgressView().padding(30)
        } else if senders.isEmpty {
            VStack(spacing: 8) {
                Text(isFiltered ? l10n.senderRankingNoMatch : l10n.senderRankingEmpty)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(30)
        } else {
            List {
                ForEach(senders) { sender in
                    row(sender)
                }
            }
            .listStyle(.inset)
        }
    }

    private func row(_ sender: SenderSummary) -> some View {
        HStack(alignment: .top, spacing: 10) {
            SenderAvatar(email: sender.address, displayName: sender.displayName)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(sender.displayName ?? sender.address)
                        .font(.body)
                        .bold(sender.unreadCount > 0)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    // Volume is the ranking, so it is the loudest number here.
                    Text(l10n.senderMailCount(sender.totalCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text(sender.address)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if sender.unreadCount > 0 {
                        Label(
                            l10n.senderUnreadCount(sender.unreadCount),
                            systemImage: "envelope.badge"
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    Text(sender.latestAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if filedAddress == sender.address {
                        // Confirms the rule landed. Without it the sheet closes
                        // and the user cannot tell a silent success from a no-op.
                        Label(l10n.senderFiled, systemImage: "checkmark.circle")
                            .font(.caption2)
                            .foregroundStyle(.tint)
                    }
                }
            }

            Spacer(minLength: 0)

            // Two routes to act, both landing on existing user-triggered flows.
            Button(l10n.senderViewMail) { onOpenSender(sender) }
                .buttonStyle(.link)
                .font(.caption)
            if sender.isWorthCollapsing {
                Button(l10n.senderFile) { onFileSender(sender) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    // MARK: - Loading

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let rows = try await api.fetchSenders(
                accountId: accountId, query: query.isEmpty ? nil : query
            )
            senders = rows
            isFiltered = !query.isEmpty
            errorBanner = nil
        } catch {
            // A failed filter keeps the previous rows on screen: replacing them
            // with an error would throw away a ranking the user was reading.
            if senders.isEmpty {
                errorBanner = ErrorBanner(
                    severity: .error,
                    title: l10n.senderRankingFailed,
                    detail: error.lagoonUIMessage,
                    actionLabel: l10n.retry,
                    action: { Task { await load() } }
                )
            }
        }
    }

    /// Called by the parent once the stack editor has created a rule, so the row
    /// can confirm rather than look unchanged.
    func markFiled(_ address: String) {
        filedAddress = address
    }
}