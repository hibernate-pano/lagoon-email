import SwiftUI
import LagoonKit

/// Default landing surface (spec §7.1): the classified Briefing Feed.
///
/// Groups are rendered in `BriefingGroup.allCases` order, empty groups are
/// hidden (§2 principle 4), and `.subscriptionNoise` starts collapsed.
/// Selecting a row pushes the message detail; ⌘1…⌘5 jump to a group.
struct BriefingFeedView: View {
    @EnvironmentObject private var accounts: AccountStore

    @State private var items: [BriefingItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var collapsedGroups: Set<BriefingGroup> =
        Set(BriefingGroup.allCases.filter(\.collapsedByDefault))
    @State private var path: [String] = []
    @State private var scrollProxy: ScrollViewProxy?

    private let api = APIClient()
    private static let refreshInterval: Duration = .seconds(30)

    @Environment(\.l10n) private var l10n

    /// Lets the root surface switcher show the raw message list.
    var onShowAllMessages: () -> Void = {}

    var body: some View {
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: 0) {
                    headerBar
                    if let errorMessage {
                        noticeBanner(errorMessage)
                    }
                    content
                }
                .onAppear { scrollProxy = proxy }
            }
            .navigationDestination(for: String.self) { gmailId in
                destination(for: gmailId)
            }
            .background(groupJumpShortcuts)
        }
        .frame(minWidth: 720, minHeight: 480)
        // Initial load, then poll while visible. SwiftUI cancels the task when
        // the view leaves the hierarchy.
        .task {
            await refresh()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.refreshInterval)
                } catch {
                    return
                }
                await refresh()
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 8) {
            Text(l10n.briefing)
                .font(.headline)
            if isLoading {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button {
                onShowAllMessages()
            } label: {
                Label(l10n.allMessages, systemImage: "list.bullet")
            }
            .keyboardShortcut("0", modifiers: .command)
            .help(l10n.showRawListHelp)

            Button(l10n.refresh) {
                Task { await refresh() }
            }
            .disabled(isLoading)
            .keyboardShortcut("r", modifiers: .command)
        }
        .padding()
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if items.isEmpty {
            if isLoading {
                ProgressView(l10n.loadingBriefing)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if errorMessage != nil {
                errorState
            } else {
                emptyState
            }
        } else {
            feedList
        }
    }

    private var feedList: some View {
        List {
            ForEach(BriefingGroup.allCases) { group in
                let groupItems = items.filter { $0.group == group }
                if !groupItems.isEmpty {
                    Section {
                        if !collapsedGroups.contains(group) {
                            ForEach(groupItems) { item in
                                NavigationLink(value: item.message.gmailId) {
                                    BriefingRow(item: item)
                                }
                            }
                        }
                    } header: {
                        groupHeader(group, count: groupItems.count)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private func groupHeader(_ group: BriefingGroup, count: Int) -> some View {
        Button {
            toggle(group)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: collapsedGroups.contains(group) ? "chevron.right" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(group.emoji) \(l10n.groupTitle(group))")
                    .font(.headline)
                Spacer()
                Text("\(count)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collapsedGroups.contains(group) ? l10n.expandGroup(l10n.groupTitle(group)) : l10n.collapseGroup(l10n.groupTitle(group)))
        .id(group)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(l10n.noBriefingYet, systemImage: "tray")
        } description: {
            Text(l10n.noBriefingYetDescription)
        }
    }

    private var errorState: some View {
        ContentUnavailableView {
            Label(l10n.briefingUnavailable, systemImage: "exclamationmark.triangle")
        } description: {
            Text(errorMessage ?? l10n.unknownError)
        } actions: {
            Button(l10n.retry) { Task { await refresh() } }
        }
    }

    private func noticeBanner(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    // MARK: - ⌘1…⌘5 group jumps

    private var groupJumpShortcuts: some View {
        VStack {
            ForEach(Array(BriefingGroup.allCases.enumerated()), id: \.element) { index, group in
                Button(l10n.groupTitle(group)) { jump(to: group) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func jump(to group: BriefingGroup) {
        collapsedGroups.remove(group)
        withAnimation {
            scrollProxy?.scrollTo(group, anchor: .top)
        }
    }

    // MARK: - Detail destination

    @ViewBuilder
    private func destination(for gmailId: String) -> some View {
        if let accountId = accounts.accountId {
            let item = items.first { $0.message.gmailId == gmailId }
            MessageDetailView(
                gmailId: gmailId,
                accountId: accountId,
                header: item?.message,
                initiallyPinned: item?.group == .pinned,
                onReadStateChange: { gmailId, isRead in
                    setRead(gmailId: gmailId, isRead: isRead)
                },
                onPinnedChanged: { _ in
                    Task { await refresh() }
                }
            )
        } else {
            ContentUnavailableView(
                l10n.notConnected,
                systemImage: "person.crop.circle.badge.exclamationmark",
                description: Text(l10n.connectToRead)
            )
        }
    }

    // MARK: - State

    private func toggle(_ group: BriefingGroup) {
        if collapsedGroups.contains(group) {
            collapsedGroups.remove(group)
        } else {
            collapsedGroups.insert(group)
        }
    }

    private func setRead(gmailId: String, isRead: Bool) {
        guard let index = items.firstIndex(where: { $0.message.gmailId == gmailId }) else { return }
        let item = items[index]
        let message = item.message
        let updated = MessageHeader(
            id: message.id,
            accountId: message.accountId,
            gmailId: message.gmailId,
            threadId: message.threadId,
            fromAddress: message.fromAddress,
            fromName: message.fromName,
            subject: message.subject,
            snippet: message.snippet,
            receivedAt: message.receivedAt,
            isRead: isRead,
            isArchived: message.isArchived
        )
        items[index] = BriefingItem(message: updated, group: item.group, reasonCode: item.reasonCode)
    }

    private func refresh() async {
        guard let accountId = accounts.accountId else { return }
        guard !isLoading else { return }
        isLoading = true
        do {
            let response = try await api.fetchBriefing(accountId: accountId)
            items = response.items
            errorMessage = nil
        } catch {
            errorMessage = l10n.briefingFailed + error.lagoonUIMessage
        }
        isLoading = false
    }
}

/// One Briefing Feed row: subject, sender, date, and the classifier's "why".
private struct BriefingRow: View {
    let item: BriefingItem
    @Environment(\.l10n) private var l10n

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.message.subject ?? l10n.noSubject)
                    .font(.body)
                    .bold(!item.message.isRead)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(item.message.receivedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(item.message.fromName ?? item.message.fromAddress)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let reason = l10n.reasonText(item.reasonCode) {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            } else if let snippet = item.message.snippet {
                Text(snippet)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}
