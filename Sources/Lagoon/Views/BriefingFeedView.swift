import SwiftUI
import LagoonKit

/// Default landing surface (spec §7.1): the classified Briefing Feed.
///
/// Each row carries context-aware action buttons (archive, pin, override)
/// and j/k navigation jumps between messages. ⌘Z surfaces the undo toast
/// via UndoController.
struct BriefingFeedView: View {
    @EnvironmentObject private var accounts: AccountStore
    @EnvironmentObject private var undo: UndoController
    @EnvironmentObject private var directory: DirectoryStore
    @State private var items: [BriefingItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var collapsedGroups: Set<BriefingGroup> = Set(BriefingGroup.allCases.filter(\.collapsedByDefault))
    @State private var path: [String] = []
    @State private var scrollProxy: ScrollViewProxy?
    @State private var selectedGmailId: String? = nil

    private let api = APIClient()
    private static let refreshInterval: Duration = .seconds(30)
    @Environment(\.l10n) private var l10n

    /// Same gate as the detail toolbar. Unknown (directory not loaded yet, or a
    /// version-skewed row) reads as allowed: the server is the authority and
    /// answers 409 archive-unavailable when the folder really is missing.
    private var canArchive: Bool {
        directory.active?.capabilities.archiveFolder ?? true
    }

    var onShowAllMessages: () -> Void = {}

    var body: some View {
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: 0) {
                    headerBar
                    if let errorMessage { noticeBanner(errorMessage) }
                    content
                }
                .onAppear { scrollProxy = proxy }
            }
            .navigationDestination(for: String.self) { remoteId in
                destination(for: remoteId)
            }
            .background(groupJumpShortcuts)
            .safeAreaInset(edge: .bottom) { UndoToast(controller: undo) }
        }
        .frame(minWidth: 720, minHeight: 480)
        .task { await refresh() ; await poll() }
        .onReceive(NotificationCenter.default.publisher(for: .lagoonDidUndo)) { _ in
            Task { await refresh() }
        }
    }

    private func poll() async {
        while !Task.isCancelled {
            do { try await Task.sleep(for: Self.refreshInterval) } catch { return }
            await refresh()
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 8) {
            Text(l10n.briefing).font(.headline)
            if isLoading { ProgressView().controlSize(.small) }
            Spacer()
            Button { onShowAllMessages() } label: {
                Label(l10n.allMessages, systemImage: "list.bullet")
            }
            .keyboardShortcut("0", modifiers: .command)
            .help(l10n.showRawListHelp)
            Button(l10n.refresh) { Task { await refresh() } }
                .disabled(isLoading)
                .keyboardShortcut("r", modifiers: .command)
                .help(l10n.shortcutRefresh)
        }
        .padding()
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if items.isEmpty {
            if isLoading { ProgressView(l10n.loadingBriefing).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if errorMessage != nil { errorState }
            else { emptyState }
        } else {
            feedList
        }
    }

    private var feedList: some View {
        List(selection: $selectedGmailId) {
            ForEach(BriefingGroup.allCases) { group in
                let groupItems = items.filter { $0.group == group }
                if !groupItems.isEmpty {
                    Section {
                        if !collapsedGroups.contains(group) {
                            ForEach(groupItems) { item in
                                NavigationLink(value: item.message.remoteId) {
                                    BriefingRow(item: item)
                                }
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    Button { Task { await archiveAndUndo(item) } } label: {
                                        Label(l10n.archived, systemImage: "tray.and.arrow.down")
                                    }
                                    .tint(.orange)
                                    .disabled(!canArchive)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button { togglePin(item: item) } label: {
                                        Label(item.group == .pinned ? l10n.unpin : l10n.pin, systemImage: "pin")
                                    }
                                    .tint(.yellow)
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
        .onDeleteCommand { if let id = selectedGmailId { Task { await archiveAndUndo(byId: id) } } }
        .onMoveCommand { direction in
            moveSelection(direction: direction)
        }
    }

    private func groupHeader(_ group: BriefingGroup, count: Int) -> some View {
        Button { toggle(group) } label: {
            HStack(spacing: 8) {
                Image(systemName: collapsedGroups.contains(group) ? "chevron.right" : "chevron.down")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("\(group.emoji) \(l10n.groupTitle(group))").font(.headline)
                Spacer()
                Text("\(count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)

        .help(collapsedGroups.contains(group) ? l10n.expand : l10n.collapse)

        .id(group)

    }



    private var emptyState: some View {

        ContentUnavailableView {

            Label(l10n.inboxZero, systemImage: "checkmark.seal")

        } description: {

            Text(l10n.tapGmailToSync)

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

            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)

            Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)

            Spacer()

        }.padding(.horizontal, 10).padding(.vertical, 8)

        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

        .padding(.horizontal).padding(.bottom, 8)

    }



    // MARK: - Selection / navigation



    private func moveSelection(direction: MoveCommandDirection) {

        guard !items.isEmpty else { return }

        let visible = items.filter { !collapsedGroups.contains($0.group) }

        guard !visible.isEmpty else { return }

        let current = selectedGmailId.flatMap { id in visible.firstIndex(where: { $0.message.remoteId == id }) } ?? 0

        let next: Int

        switch direction {

        case .up: next = max(0, current - 1)

        case .down: next = min(visible.count - 1, current + 1)

        case .left, .right: return

        @unknown default: return

        }

        let target = visible[next].message.remoteId

        selectedGmailId = target

        withAnimation { scrollProxy?.scrollTo(target, anchor: .center) }

    }



    private var groupJumpShortcuts: some View {

        VStack {

            ForEach(Array(BriefingGroup.allCases.enumerated()), id: \.element) { index, group in

                Button(l10n.groupTitle(group)) { jump(to: group) }

                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)

            }

        }.frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)

    }



    private func jump(to group: BriefingGroup) {

        collapsedGroups.remove(group)

        withAnimation { scrollProxy?.scrollTo(group, anchor: .top) }

    }



    // MARK: - Detail destination



    @ViewBuilder

    private func destination(for remoteId: String) -> some View {

        if let accountId = accounts.accountId {

            let visible = items.filter { !collapsedGroups.contains($0.group) }.map { $0.message.remoteId }

            let siblings = visible.contains(remoteId) ? visible : nil

            MessageDetailView(

                remoteId: remoteId,

                accountId: accountId,

                header: items.first { $0.message.remoteId == remoteId }?.message,

                initiallyPinned: items.first { $0.message.remoteId == remoteId }?.group == .pinned,

                siblings: siblings,

                onArchived: { id, isArchived in

                    handleArchived(id: id, isArchived: isArchived)

                },

                onAdvanceTo: { next in

                    path = [next]

                },

                onReadStateChange: { id, isRead in

                    setRead(remoteId: id, isRead: isRead)

                },

                onPinnedChanged: { _ in

                    Task { await refresh() }

                }

            )

        } else {

            ContentUnavailableView(

                l10n.notConnected, systemImage: "person.crop.circle.badge.exclamationmark",

                description: Text(l10n.connectToRead)

            )

        }

    }



    // MARK: - Actions



    private func toggle(_ group: BriefingGroup) {

        if collapsedGroups.contains(group) { collapsedGroups.remove(group) } else { collapsedGroups.insert(group) }

    }



    private func setRead(remoteId: String, isRead: Bool) {

        guard let index = items.firstIndex(where: { $0.message.remoteId == remoteId }) else { return }

        let item = items[index]

        items[index] = BriefingItem(

            message: withUpdatedRead(item.message, isRead: isRead),

            group: item.group, reasonCode: item.reasonCode

        )

    }



    private func withUpdatedRead(_ m: MessageHeader, isRead: Bool) -> MessageHeader {

        MessageHeader(

            id: m.id, accountId: m.accountId, remoteId: m.remoteId, threadId: m.threadId,

            fromAddress: m.fromAddress, fromName: m.fromName,

            subject: m.subject, snippet: m.snippet,

            receivedAt: m.receivedAt, isRead: isRead, isArchived: m.isArchived

        )

    }



    private func handleArchived(id: String, isArchived: Bool) {

        items.removeAll { $0.message.remoteId == id }

    }



    private func togglePin(item: BriefingItem) {

        guard let accountId = accounts.accountId else { return }

        let toPinned = item.group != .pinned

        Task {

            try? await api.setPinned(remoteId: item.message.remoteId, accountId: accountId, pinned: toPinned)

            await refresh()

        }

    }



    private func archiveAndUndo(_ item: BriefingItem) async {

        await archiveAndUndo(byId: item.message.remoteId)

    }



    private func archiveAndUndo(byId remoteId: String) async {

        guard canArchive else {

            errorMessage = l10n.archiveUnavailable

            return

        }

        guard let accountId = accounts.accountId else { return }

        do {

            let response = try await api.archiveMessage(remoteId: remoteId, accountId: accountId)

            items.removeAll { $0.message.remoteId == remoteId }

            if let actions = try? await api.fetchActions(accountId: accountId, since: Date().addingTimeInterval(-30)),

               let latest = actions.first {

                let msg = response.remote ? l10n.archived : l10n.archivedLocallyOnly

                undo.show(UndoItem(id: latest.id, message: msg, systemImage: "tray.and.arrow.down"))

            }

        } catch APIError.badStatus(let code, _) where code == 409 {

            errorMessage = l10n.archiveUnavailable

        } catch {

            errorMessage = l10n.archiveFailed + error.lagoonUIMessage

        }

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



private struct BriefingRow: View {

    let item: BriefingItem

    @Environment(\.l10n) private var l10n



    var body: some View {

        VStack(alignment: .leading, spacing: 4) {

            HStack(alignment: .firstTextBaseline, spacing: 8) {

                Text(item.message.subject ?? l10n.noSubject)

                    .font(.body).bold(!item.message.isRead).lineLimit(1)

                Spacer(minLength: 8)

                Text(item.message.receivedAt.formatted(date: .abbreviated, time: .shortened))

                    .font(.caption2).foregroundStyle(.tertiary)

            }

            Text(item.message.fromName ?? item.message.fromAddress)

                .font(.caption).foregroundStyle(.secondary).lineLimit(1)

            if let reason = l10n.reasonText(item.reasonCode) {

                Text(reason).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)

            } else if let snippet = item.message.snippet {

                Text(snippet).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)

            }

        }.padding(.vertical, 2)

    }

}

