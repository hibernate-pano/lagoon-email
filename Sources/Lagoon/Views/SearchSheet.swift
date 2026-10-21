import SwiftUI
import LagoonKit

/// Global search (server: `GET /api/search?q=...&accountId=...`).
struct SearchSheet: View {
    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var accounts: AccountStore
    /// The account directory: which mailboxes exist and what they are called.
    ///
    /// The search sheet needs it for two things the sheet cannot own: the
    /// scope picker (a multi-mailbox user has to be able to say "every
    /// mailbox") and the **name on each result row** — without the name, a
    /// cross-account hit is unreadable: the user cannot tell which mailbox a
    /// message came from, and the mail looks like it belongs to the account
    /// they happen to be looking at.
    @EnvironmentObject private var directory: DirectoryStore
    /// The query to start with, when one came from outside — a
    /// `lagoon://search?q=…` link, or the menu bar.
    ///
    /// The sheet still owns the query field: the seed is copied in once, on
    /// appear, and from then on the user is typing into the sheet's own
    /// state. A link that arrives while the panel is already open updates
    /// the field too, because the link is a request to search for that text.
    let initialQuery: String?
    @State private var query = ""
    @State private var results: [MessageHeader] = []
    /// How many messages matched, before the server's cap.
    ///
    /// Nil when the server did not say (an older server, or a failed
    /// request) — the panel then says nothing about a total rather than
    /// inventing one.
    @State private var totalCount: Int?
    @State private var isLoading = false
    @State private var errorBanner: ErrorBanner?
    @State private var path: [MessageRef] = []
    /// Whether a search has actually been run.
    ///
    /// Without it the panel opened showing "没找到匹配邮件" — a *result* —
    /// before the user had typed anything. "Nothing matched" and "you have
    /// not searched yet" are different states and the copy has to say which
    /// one it is.
    @State private var hasSearched = false
    /// Which mailboxes the search covers.
    ///
    /// The default is **the active mailbox only**, because that is what
    /// "search" meant before multi-account existed and it is the narrow,
    /// predictable answer. `all` is one click away for the user who knows
    /// the mail is in another mailbox.
    ///
    /// The choice is remembered for the session (not across launches): a
    /// user who habitually searches "everything" should not have to say so
    /// every morning, and a user who searched everything once by accident
    /// should not stay in that mode forever.
    @AppStorage("lagoon.search.scope") private var scopeChoice: String = SearchScopeChoice.active.rawValue
    /// The scope the *next* search will use.
    ///
    /// A separate piece of state from `scopeChoice`: switching the scope
    /// re-runs the current query immediately, and the picker has to show the
    /// scope the results on screen came from — not the one the user has
    /// just clicked on.
    @State private var activeScope: SearchScopeChoice = .active
    private let api = APIClient.shared

    /// The scope options the picker offers.
    ///
    /// "Every mailbox" is only offered when there is more than one mailbox:
    /// with a single account it is the same search with a longer label, and
    /// offering it would be a control that does nothing.
    private var scopeOptions: [SearchScopeChoice] {
        directory.accounts.count > 1 ? [.active, .all] : [.active]
    }

    var body: some View {
        // `NavigationLink(value:)` only pushes when a NavigationStack is in
        // scope; previously the stack lived *inside* the destination closure,
        // so tapping a result did nothing. Bind `path` here too.
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(l10n.searchPlaceholder, text: $query)
                        .textFieldStyle(.plain)
                        .onSubmit { Task { await run() } }
                    if !query.isEmpty {
                        Button {
                            query = ""
                            results = []
                            totalCount = nil
                            // Back to "you have not searched yet", not
                            // "nothing matched".
                            hasSearched = false
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    Button(l10n.search) { Task { await run() } }
                        .disabled(query.isEmpty || isLoading)
                }
                .padding(12)
                // The scope picker. It sits under the query field rather
                // than beside it: the field is the thing the user touches
                // most, and a segmented control next to it steals the width
                // the query needs on a narrow window.
                if scopeOptions.count > 1 {
                    Picker(l10n.searchScopeLabel, selection: $scopeChoice) {
                        ForEach(scopeOptions) { option in
                            Text(scopeTitle(option)).tag(option.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .accessibilityLabel(l10n.searchScopeLabel)
                    .help(l10n.searchScopeHelp)
                    // Switching the scope re-runs the query, so the results
                    // on screen always belong to the scope on screen. Without
                    // this the user switches to "every mailbox", sees the
                    // old mailbox's results, and concludes the control is
                    // broken.
                    .onChange(of: scopeChoice) { _, _ in
                        Task { await run() }
                    }
                }
                Divider()
                // One line, always visible rather than only on an empty result:
                // search now matches what the AI *concluded* about a message
                // (its category and advised action), not just its text. A user
                // who types "marketing" and gets hits on mails that never use
                // the word needs to know why — otherwise the result looks wrong
                // and they stop trusting the box.
                Text(l10n.searchIncludesAdvice)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                if isLoading { ProgressView().padding(20) }
                else if !hasSearched {
                    // Nothing has been searched yet — this is an invitation,
                    // not a result.
                    ContentUnavailableView(
                        l10n.emptySearchPrompt,
                        systemImage: "magnifyingglass",
                        description: Text(l10n.emptySearchPromptHint)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                else if results.isEmpty {
                    ContentUnavailableView(
                        l10n.noResults,
                        systemImage: "magnifyingglass",
                        description: Text(l10n.emptySearchHint)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                else {
                    // The count, and what it means when the list is only a
                    // window. The search used to stop at the server's cap
                    // with nothing said, so a truncated result and a
                    // complete one looked identical — and the user could
                    // not tell that the answer they were reading was
                    // partial.
                    if let total = totalCount {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(l10n.searchResultCount(total))
                                .font(.caption.weight(.medium))
                            if total > results.count {
                                Text(l10n.searchTruncated(results.count, total))
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                    }
                    List(results) { m in
                        NavigationLink(value: MessageRef(m)) {
                            VStack(alignment: .leading, spacing: 3) {
                                highlightedText(
                                    m.subject ?? l10n.noSubject,
                                    term: query,
                                    bold: !m.isRead
                                )
                                .lineLimit(1)
                                HStack {
                                    highlightedText(
                                        m.fromName ?? m.fromAddress,
                                        term: query,
                                        font: .caption,
                                        color: .secondary
                                    )
                                    .lineLimit(1)
                                    Text(m.receivedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    // Which mailbox this hit came from.
                                    //
                                    // Only shown when the search covered more
                                    // than one mailbox: with a single-mailbox
                                    // search the answer is always the same
                                    // and repeating it on every row is
                                    // noise. With a cross-account search it
                                    // is the *only* thing that says whether
                                    // the mail is in the mailbox the user is
                                    // looking at or another one — without it
                                    // the result is a list of mail the user
                                    // cannot place.
                                    if let accountLabel = accountLabel(for: m) {
                                        Text(accountLabel)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                                if let snippet = m.snippet, !snippet.isEmpty {
                                    highlightedText(
                                        snippet,
                                        term: query,
                                        font: .caption2,
                                        color: .secondary
                                    )
                                    .lineLimit(2)
                                }
                            }
                        }
                    }
                }
            }
            .navigationDestination(for: MessageRef.self) { ref in
                // The account comes from the **result**, not from the active
                // account. A cross-account hit belongs to another mailbox,
                // and opening it under the active account's id would fetch
                // the wrong mail — or nothing at all, since `remoteId` is
                // only unique inside one mailbox.
                //
                // The navigation key is the *pair*, for the same reason:
                // `uid:42` exists in every mailbox, so a key of `remoteId`
                // alone resolves to whichever hit came first.
                if let result = results.first(where: {
                    $0.accountId == ref.accountId && $0.remoteId == ref.remoteId
                }) {
                    MessageDetailView(
                        remoteId: ref.remoteId,
                        accountId: ref.accountId,
                        header: result,
                        initiallyPinned: result.isPinned,
                        siblings: results.map { MessageRef($0) },
                        onArchived: { id, _ in
                            results.removeAll { $0.remoteId == id }
                        },
                        onAdvanceTo: { next in
                            path = next.map { [$0] } ?? []
                        },
                        onDelete: { id in
                            results.removeAll { $0.remoteId == id }
                            path = []
                        }
                    )
                    // Same reset contract as the BriefingFeed/MessageList
                    // entries: without this the destination reuses the
                    // previous message's @State (stale body, stale height).
                    .id(ref.id)
                }
            }
        }
        .noticeBanner($errorBanner)
        .frame(
            width: LagoonSheetSize.wide.width,
            height: LagoonSheetSize.wide.height
        )
        // A link that carries a query is a request to *search* for that
        // text, not merely to open the panel with it sitting in the field.
        // Running it here means the results are on screen when the panel
        // opens — which is what the person who clicked the link expected.
        .task(id: initialQuery) {
            guard let seed = initialQuery, !seed.isEmpty else { return }
            query = seed
            await run()
        }
        .background {
            Button(l10n.back) {
                if !path.isEmpty { path.removeLast() }
            }
            .keyboardShortcut("[", modifiers: .command)
            .help(l10n.backHelp)
            .frame(width: 0, height: 0)
            .opacity(0)
            .focusable(false)
            .accessibilityHidden(true)
        }
    }

    /// The label of the mailbox a result came from, or nil when the search
    /// covered only one mailbox.
    ///
    /// A result whose mailbox is not in the directory (removed while the
    /// sheet was open, or a mailbox the client has not polled yet) still
    /// gets a label — the raw id is ugly, but *something* that identifies
    /// the mailbox beats nothing.
    private func accountLabel(for message: MessageHeader) -> String? {
        guard activeScope == .all else { return nil }
        if let account = directory.accounts.first(where: { $0.id == message.accountId }) {
            return account.email
        }
        return message.accountId.uuidString.prefix(8).uppercased()
    }

    /// The picker title of a scope.
    private func scopeTitle(_ option: SearchScopeChoice) -> String {
        switch option {
        case .active: return l10n.searchScopeCurrent
        case .all: return l10n.searchScopeAll
        }
    }

    /// The scope the picker value stands for.
    private func currentScope() -> SearchScope {
        (SearchScopeChoice(rawValue: scopeChoice) ?? .active)
            .scope(activeAccountId: accounts.accountId)
    }

    func run() async {
        guard !query.isEmpty else { return }
        let scope = currentScope()
        activeScope = SearchScopeChoice(rawValue: scopeChoice) ?? .active
        isLoading = true
        errorBanner = nil
        hasSearched = true
        do {
            let page = try await api.searchPage(query: query, scope: scope)
            results = page.results
            totalCount = page.totalCount
        } catch {
            results = []
            // A failed search has no count to report, and claiming the last
            // one would be a number about a different question.
            totalCount = nil
            errorBanner = ErrorBanner(
                severity: .error,
                title: l10n.searchFailedTitle,
                detail: l10n.searchFailedDetail,
                actionLabel: l10n.retry,
                action: { [self] in await self.run() }
            )
        }
        isLoading = false
    }

    /// Render `text` with every case-insensitive occurrence of `term`
    /// highlighted in a yellow rounded background. Used to mark the
    /// user's search hits inside a result row so they can see *why* a
    /// given message matched before they open it.
    ///
    /// Built as a single `AttributedString` so styling stays consistent
    /// across matched and unmatched segments; the `Text` returned here
    /// lets the caller chain `.lineLimit` / `.foregroundStyle` modifiers
    /// if needed.
    private func highlightedText(
        _ text: String,
        term: String,
        font: Font? = nil,
        bold: Bool = false,
        color: Color? = nil,
        lineLimit: Int? = nil
    ) -> Text {
        var attr = AttributedString(text)
        if let font { attr.font = font }
        if bold {
            // `attr.font` is an optional, and `Font.bold()` returns a Font.
            // The compact assignment form below avoids the
            // if-let-with-side-effect-in-ViewBuilder pitfall.
            attr.font = (attr.font ?? .body).bold()
        }
        if let color { attr.foregroundColor = color }

        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty,
           let range = attr.range(of: trimmed, options: .caseInsensitive) {
            attr[range].backgroundColor = .yellow.opacity(0.35)
        }
        return Text(attr)
    }
}
