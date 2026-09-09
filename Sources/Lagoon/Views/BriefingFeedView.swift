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
            Text("Briefing")
                .font(.headline)
            if isLoading {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button {
                onShowAllMessages()
            } label: {
                Label("All messages", systemImage: "list.bullet")
            }
            .keyboardShortcut("0", modifiers: .command)
            .help("Show the raw message list (⌘0)")

            Button("Refresh") {
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
                ProgressView("Loading briefing…")
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
                Text("\(group.emoji) \(group.title)")
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
        .help(collapsedGroups.contains(group) ? "Expand \(group.title)" : "Collapse \(group.title)")
        .id(group)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No briefing yet", systemImage: "tray")
        } description: {
            Text("The server has not classified any messages yet. It keeps syncing in the background.")
        }
    }

    private var errorState: some View {
        ContentUnavailableView {
            Label("Briefing unavailable", systemImage: "exclamationmark.triangle")
        } description: {
            Text(errorMessage ?? "Unknown error")
        } actions: {
            Button("Retry") { Task { await refresh() } }
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
                Button(group.title) { jump(to: group) }
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
                "Not connected",
                systemImage: "person.crop.circle.badge.exclamationmark",
                description: Text("Connect a Gmail account to read messages.")
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
        items[index] = BriefingItem(message: updated, group: item.group, reason: item.reason)
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
            errorMessage = "Briefing failed: \(error.lagoonUIMessage)"
        }
        isLoading = false
    }
}

/// One Briefing Feed row: subject, sender, date, and the classifier's "why".
private struct BriefingRow: View {
    let item: BriefingItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.message.subject ?? "(no subject)")
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
            if let reason = item.reason, !reason.isEmpty {
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
