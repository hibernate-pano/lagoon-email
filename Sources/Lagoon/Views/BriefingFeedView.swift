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
            Text("简报")
                .font(.headline)
            if isLoading {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button {
                onShowAllMessages()
            } label: {
                Label("全部邮件", systemImage: "list.bullet")
            }
            .keyboardShortcut("0", modifiers: .command)
            .help("查看全部邮件列表（⌘0）")

            Button("刷新") {
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
                ProgressView("正在加载简报…")
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
        .help(collapsedGroups.contains(group) ? "展开 \(group.title)" : "收起 \(group.title)")
        .id(group)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("还没有简报", systemImage: "tray")
        } description: {
            Text("服务器还没有分类任何邮件，正在后台持续同步。")
        }
    }

    private var errorState: some View {
        ContentUnavailableView {
            Label("简报不可用", systemImage: "exclamationmark.triangle")
        } description: {
            Text(errorMessage ?? "未知错误")
        } actions: {
            Button("重试") { Task { await refresh() } }
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
                "未连接",
                systemImage: "person.crop.circle.badge.exclamationmark",
                description: Text("请先连接 Gmail 账号以阅读邮件。")
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
            errorMessage = "简报加载失败：\(error.lagoonUIMessage)"
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
                Text(item.message.subject ?? "（无主题）")
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
