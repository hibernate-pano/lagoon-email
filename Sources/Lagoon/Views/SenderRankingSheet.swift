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
    /// The address a 聚合规则 was just created for, so the row can confirm
    /// instead of appearing to do nothing.
    ///
    /// A **binding**, not local state, and that is the whole fix for the dead
    /// checkmark. The rule is created by the stack editor, which lives in a
    /// different view tree; the panel could never hear about it on its own,
    /// so `filedAddress` stayed nil and the 「已建立聚合」 label never
    /// appeared. The owner of both surfaces (RootView) holds the fact and
    /// hands it down here, so the write and the read meet in one place.
    @Binding var filedAddress: String?
    /// Called once the rule for a sender has actually been created.
    ///
    /// The parent owns the sidebar, which has to learn about the new rule —
    /// the panel cannot refresh the 自定义聚合 section itself.
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
    /// The sender whose rule is being written, and the editor that writes it.
    @State private var pendingFiling: PendingFiling?
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
        .frame(
            width: LagoonSheetSize.wide.width,
            height: LagoonSheetSize.wide.height
        )
        .task { await load() }
        // The rule editor, presented by the panel itself.
        //
        // It used to be opened by the list surface, one view tree away, and
        // handed over through a pending value — a route that dropped the
        // request whenever the destination changed underneath it (the list
        // is keyed on the destination, so switching to it *recreated* the
        // list and the pending value with it). The editor is a sheet of its
        // own; there is no reason for the panel to go through another
        // surface to reach it.
        .sheet(item: $pendingFiling) { filing in
            StackRuleEditorSheet(
                initialKind: .sender,
                prefilledValue: filing.sender.address,
                prefilledName: filing.sender.displayName ?? filing.sender.address
            ) { _ in
                // The rule landed — this is the only place that knows it, and
                // the only place the confirmation can be raised from.
                markFiled(filing.sender.address)
                onFileSender(filing.sender)
            }
        }
    }

    // MARK: - Chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: LagoonMetrics.spaceSM) {
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
                        .padding(LagoonMetrics.spaceXS)
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
        .padding(LagoonMetrics.spaceLG)
    }

    private var searchField: some View {
        HStack(spacing: LagoonMetrics.spaceSM) {
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
        .padding(.horizontal, LagoonMetrics.spaceSM)
        .padding(.vertical, LagoonMetrics.spaceSM)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: LagoonMetrics.radiusMedium))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let errorBanner, senders.isEmpty {
            NoticeBannerView(banner: errorBanner) { self.errorBanner = nil }
                .padding(LagoonMetrics.spaceLG)
        } else if isLoading, senders.isEmpty {
            ProgressView().padding(LagoonMetrics.spaceXXL)
        } else if senders.isEmpty {
            VStack(spacing: LagoonMetrics.spaceSM) {
                Text(isFiltered ? l10n.senderRankingNoMatch : l10n.senderRankingEmpty)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(LagoonMetrics.spaceXXL)
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
        HStack(alignment: .top, spacing: LagoonMetrics.spaceMD) {
            SenderAvatar(email: sender.address, displayName: sender.displayName)

            VStack(alignment: .leading, spacing: LagoonMetrics.spaceXS) {
                HStack(alignment: .firstTextBaseline, spacing: LagoonMetrics.spaceSM) {
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
                HStack(spacing: LagoonMetrics.spaceSM) {
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
                Button(l10n.senderFile) { pendingFiling = PendingFiling(sender: sender) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(.vertical, LagoonMetrics.spaceXS)
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

    /// Records that a rule now exists for this address.
    ///
    /// Writes through the binding rather than into local state: the rule is
    /// created by the stack editor, which this panel cannot see. The binding
    /// is precisely so that this write lands where the owner of both surfaces
    /// can see it — and where the row that has to show the confirmation can
    /// read it.
    func markFiled(_ address: String) {
        filedAddress = address
    }
}

/// A sender waiting to be filed into a 聚合规则.
///
/// Carries the whole sender rather than just the address: the rule editor
/// reports back that a rule exists, and the panel has to turn that into a
/// confirmation *on that sender's row* — an address alone would leave the
/// row to be matched by string comparison in two places.
struct PendingFiling: Identifiable {
    let sender: SenderSummary
    var id: String { sender.address }
}
