import SwiftUI
import LagoonKit

/// Where the sidebar can send the user.
///
/// ## Why this is a value and not five booleans
///
/// The two surfaces used to be switched by a segmented control, which can only
/// express "which surface" — so "unread only" and "group by sender" lived as
/// independent toggles *inside* the list, and the sidebar-to-be has no way to
/// say "unread, grouped by sender, archived". Modelling the destination as one
/// value is what makes a third column possible: the sidebar binds a selection,
/// and the list renders whatever it is handed.
///
/// Every case maps onto a filter the list already implements — none of these
/// invent server capability. `.rule` carries a rule id because that is how
/// `/api/messages` takes an aggregation filter, so the sidebar can link to a
/// user's own group without a new query shape.
enum SidebarDestination: Hashable, Identifiable {
    /// The Briefing Feed — the classified surface that is the product's front door.
    case briefing
    /// Every live message, unfiltered.
    case allMessages
    /// Live messages the user has not read.
    case unread
    /// Live messages carrying a pin.
    case pinned
    /// The 档案柜.
    case archived
    /// 已发送 — mail this account sent (R1).
    ///
    /// A real folder on the server, which is why it sits beside 档案柜 and 废纸篓
    /// rather than with 未读/置顶 (those are filters over the inbox, not places
    /// mail sits).
    case sent
    /// One user-defined 聚合规则, by id.
    case rule(UUID)
    /// The server's Trash. Now a real destination with a real list — it used to
    /// map to `.all`, so clicking this row showed the inbox, which is worse
    /// than having no row at all: the user would conclude the delete had failed.
    case deleted

    var id: String {
        switch self {
        case .briefing: return "briefing"
        case .allMessages: return "all-messages"
        case .unread: return "unread"
        case .pinned: return "pinned"
        case .archived: return "archived"
        case .sent: return "sent"
        case .deleted: return "deleted"
        case .rule(let id): return "rule:\(id.uuidString)"
        }
    }

    /// Which count key feeds this row's badge, or nil when the row has none.
    ///
    /// `.briefing` has no count of its own: it is a *view* of the inbox rather
    /// than a place mail sits, and giving it the inbox total would imply the
    /// feed holds mail the raw list does not. `.rule` takes its count from
    /// `/api/stacks` instead, so it answers nil here.
    var countKey: String? {
        switch self {
        case .briefing, .rule: return nil
        case .allMessages: return FolderCountKey.live
        case .unread: return FolderCountKey.unread
        case .pinned: return FolderCountKey.pinned
        case .archived: return FolderCountKey.archived
        case .sent: return FolderCountKey.sent
        case .deleted: return FolderCountKey.deleted
        }
    }

    /// Whether selecting this destination switches to the Briefing surface.
    ///
    /// Only `.briefing` does. Everything else is a lens on the raw list, so
    /// choosing "unread" while reading the Briefing would be a silent no-op —
    /// the user would click a sidebar row and see the same feed again.
    var showsBriefing: Bool { self == .briefing }
}

/// The navigation column.
///
/// ## Why it is a third column rather than a sheet
///
/// Foxmail, QQ邮箱 and 网易邮箱大师 all put a folder/tag tree on the left, and
/// the reason is not aesthetic: a sheet is a *task*, a sidebar is a *place*. A
/// user who opens 归档柜 to check something, closes it, and opens it again
/// tomorrow should find the same thing in the same spot. Before this, every
/// one of those destinations was behind `⌘K`, a row menu, or a sheet — all of
/// which make the user re-find the thing they already found once.
///
/// ## What it does not do
///
/// It has no write verbs. No archive, no delete, no sweep from here — those
/// stay on the row and in the panels where the user has already selected the
/// message. A navigation column that could empty a folder on its own is a
/// different product (and, per constitution §2 rule 5, not this one).
struct Sidebar: View {
    @Binding var selection: SidebarDestination
    /// The user's own 聚合规则 with their live counts, from `/api/stacks`.
    var rules: [StackSummary] = []
    /// Fixed-bucket tallies from `/api/folder-counts`.
    var counts: [String: Int] = [:]

    @Environment(\.l10n) private var l10n

    var body: some View {
        List(selection: $selection) {
            Section(l10n.sidebarSmartViews) {
                row(.briefing, icon: "rectangle.grid.2x2")
                row(.allMessages, icon: "tray.full")
                row(.unread, icon: "envelope")
                row(.pinned, icon: "pin")
            }
            Section(l10n.sidebarPlaces) {
                // Order matters here: 收件箱-adjacent first, then the folders
                // mail gets filed into, then the one it gets removed to. 已发送
                // sits with 已归档 rather than up in 智能视图 because it is a
                // *place*, not a view — same reason 未读 and 置顶 are up there
                // and these two are not.
                row(.archived, icon: "archivebox")
                row(.sent, icon: "paperplane")
                row(.deleted, icon: "trash")
            }
            if !rules.isEmpty {
                Section(l10n.stackRulesHeader) {
                    ForEach(rules) { summary in
                        row(.rule(summary.rule.id), icon: "label", title: summary.rule.name,
                            count: summary.count)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // A sidebar row with a badge but no label is unreadable; the count is
        // an aid, never the content.
        .accessibilityLabel(l10n.sidebarNavigation)
    }

    /// One destination row: icon, title, count badge.
    ///
    /// The badge is omitted at zero rather than shown as "0" — a column of
    /// zeros is noise, and an absent number is the honest "there is nothing
    /// here" (which is different from "we have not checked").
    @ViewBuilder
    private func row(
        _ destination: SidebarDestination,
        icon: String,
        title customTitle: String? = nil,
        count: Int? = nil
    ) -> some View {
        let resolved = count ?? destination.countKey.flatMap { counts[$0] }
        Label {
            HStack {
                Text(customTitle ?? title(for: destination))
                Spacer(minLength: 4)
                if let resolved, resolved > 0 {
                    Text("\(resolved)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        } icon: {
            Image(systemName: icon)
        }
        .tag(destination)
        .accessibilityValue(resolved.map { "\($0)" } ?? "")
    }

    private func title(for destination: SidebarDestination) -> String {
        switch destination {
        case .briefing: return l10n.briefing
        case .allMessages: return l10n.allMessages
        case .unread: return l10n.sidebarUnread
        case .pinned: return l10n.sidebarPinned
        case .archived: return l10n.stackArchivedRow
        case .deleted: return l10n.sidebarDeleted
        case .sent: return l10n.sidebarSent
        case .rule: return l10n.stackRulesHeader
        }
    }
}


extension DeleteBulkRequest.LensScope {
    /// Maps a sidebar destination onto the scope its "select all" would mean.
    ///
    /// Total by construction: every `SidebarDestination` case is handled and the
    /// compiler enforces it. That matters because a new sidebar row without a
    /// mapping here would silently fall back to `.inbox` — and "select all" in
    /// that new folder would then bulk-delete the **inbox** instead. A missing
    /// case is a compile error; a wrong one is an incident.
    ///
    /// `.briefing` maps to `.inbox` deliberately: the Briefing feed is a *view*
    /// of the inbox rather than a separate place mail sits, so "everything in
    /// the briefing" is the inbox. The same reasoning puts `.unread` and
    /// `.pinned` there too — they are filters over the inbox, not folders — and
    /// it is the one place where that shortcut could surprise someone, so it is
    /// spelled out rather than left to a reader to infer.
    init(_ destination: SidebarDestination) {
        switch destination {
        case .archived: self = .archived
        case .deleted: self = .deleted
        case .sent: self = .sent
        case .rule(let id): self = .rule(id)
        case .briefing, .allMessages, .unread, .pinned: self = .inbox
        }
    }
}

extension SidebarDestination {
    /// The destination a list lens corresponds to, or nil when the lens is a
    /// pure filter with no folder of its own.
    ///
    /// Round-trips `MessageListView.Lens.init(_:)` for the folder-shaped
    /// destinations. `.unread` and `.pinned` return nil because neither is a
    /// place mail sits — which is exactly why their "select all" resolves to
    /// the inbox, and why the caller must not treat them as folders.
    init?(_ lens: MessageListView.Lens) {
        switch lens {
        case .archived: self = .archived
        case .deleted: self = .deleted
        case .sent: self = .sent
        case .rule(let id): self = .rule(id)
        case .all, .unread, .pinned: return nil
        }
    }
}
