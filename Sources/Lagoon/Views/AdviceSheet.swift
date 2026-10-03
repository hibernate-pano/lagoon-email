import SwiftUI
import LagoonKit

/// The suggestion queue — where Lagoon finally becomes visible as an advisor.
///
/// Three deliberate constraints (constitution §3):
///
/// 1. **No mailbox buttons here.** This sheet shows what the AI suggests and
///    offers exactly two verbs: open the message, or dismiss the suggestion.
///    Archive / delete / unsubscribe live in the Briefing row and the detail
///    view — the places the user already triages mail. Putting a second set of
///    write buttons here would duplicate that logic and invite the reading
///    that this panel can act on your behalf.
/// 2. **Adjectives, not verbs in the past.** Every label says "suggest", never
///    "archived". The user must be able to glance at this list and know nothing
///    has happened yet.
/// 3. **Confidence is visible and coarse.** A "delete this" line reads very
///    differently at "判断明确" than at "不太确定", and the second one is
///    exactly where a user is owed the doubt.
struct AdviceSheet: View {
    @EnvironmentObject private var accounts: AccountStore
    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss

    @State private var records: [AdviceRecord] = []
    @State private var isLoading = true
    @State private var errorBanner: ErrorBanner?
    @State private var busyId: Int64?

    private let api = APIClient.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            advisoryNotice
            Divider()
            content
        }
        .frame(width: 560, height: 520)
        .task { await load() }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack {
            Label(l10n.adviceTitle, systemImage: "sparkles")
                .font(.headline)
            Spacer()
            if !records.isEmpty {
                Text(l10n.adviceCount(records.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(l10n.refresh) { Task { await load() } }
                .disabled(isLoading)
            if isLoading && !records.isEmpty {
                ProgressView().controlSize(.small)
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(l10n.dismiss)
        }
        .padding(16)
    }

    /// The product promise, stated once, above the list. It is not
    /// dismissible and not skippable: it is the sentence that makes every row
    /// below it legible.
    private var advisoryNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "hand.raised")
                .foregroundStyle(.secondary)
            Text(l10n.adviceAdvisoryOnlyNotice)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.35))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoading, records.isEmpty {
            ProgressView().padding(30)
        } else if let errorBanner, records.isEmpty {
            NoticeBannerView(banner: errorBanner) { self.errorBanner = nil }
                .padding(16)
        } else if records.isEmpty {
            VStack(spacing: 8) {
                Text(l10n.adviceEmpty)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(30)
        } else {
            List {
                ForEach(records) { record in
                    row(record)
                }
            }
            .listStyle(.inset)
        }
    }

    private func row(_ record: AdviceRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // "Suggest archiving" / "Suggest deleting" — the verb is the
                // advice, never a claim that it happened.
                Text(l10n.adviceAction(record.advice.action))
                    .font(.callout.weight(.medium))
                Spacer(minLength: 8)
                if record.advice.confidence == .low {
                    // The one row that gets a visible hedge. A low-confidence
                    // destructive suggestion must not read like a firm one.
                    Text(l10n.adviceConfidence(.low))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let category = record.advice.category {
                Label(l10n.adviceCategory(category), systemImage: icon(for: category))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }

            if let rationale = record.advice.rationale {
                Text(rationale)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let due = record.advice.dueText {
                Label(due, systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                // Provenance: a paid model judgment and a free offline rule do
                // not deserve the same trust, and hiding that would make the
                // heuristic look as confident as the model.
                Text(l10n.adviceSource(record.source, model: record.model))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(record.decision == .dismissed ? l10n.adviceDismissed : l10n.adviceOpenMessage) {
                    NotificationCenter.default.post(
                        name: .lagoonRevealMessage,
                        object: nil,
                        userInfo: ["remoteId": record.remoteId]
                    )
                    dismiss()
                }
                .buttonStyle(.link)
                .font(.caption)
                if record.decision == .pending {
                    Button(l10n.adviceDismiss) {
                        Task { await dismiss_(record) }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(busyId != nil)
                }
                if busyId == record.id {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
        .opacity(record.decision == .dismissed ? 0.55 : 1)
        // Dismissing removes the row from the queue; the server keeps the
        // verdict so re-classification cannot push it back.
        .animation(.default, value: records.map(\.id))
    }

    // MARK: - Actions

    private func load() async {
        guard let accountId = accounts.accountId else {
            isLoading = false
            return
        }
        isLoading = records.isEmpty
        do {
            records = try await api.fetchAdvice(accountId: accountId)
            errorBanner = nil
        } catch {
            errorBanner = ErrorBanner(
                severity: .error,
                title: l10n.adviceLoadFailed,
                detail: error.lagoonUIMessage
            )
        }
        isLoading = false
    }

    /// Records the verdict and drops the row locally. Best-effort on failure:
    /// the row stays put and the error surfaces, because silently removing a
    /// suggestion the server still considers pending is how a queue starts
    /// lying about its own state.
    private func dismiss_(_ record: AdviceRecord) async {
        guard let accountId = accounts.accountId else { return }
        busyId = record.id
        defer { busyId = nil }
        do {
            _ = try await api.setAdviceDecision(
                id: record.id, decision: .dismissed, accountId: accountId
            )
            records.removeAll { $0.id == record.id }
            errorBanner = nil
        } catch {
            errorBanner = ErrorBanner(
                severity: .error,
                title: l10n.adviceLoadFailed,
                detail: error.lagoonUIMessage,
                actionLabel: l10n.retry,
                action: { Task { await dismiss_(record) } }
            )
        }
    }

    private func icon(for category: ContentCategory) -> String {
        switch category {
        case .marketing, .newsletter: "megaphone"
        case .spam: "exclamationmark.triangle"
        case .work: "briefcase"
        case .financial: "dollarsign.circle"
        case .logistics: "shippingbox"
        case .personal: "person"
        case .notification: "bell"
        case .transactional: "doc.text"
        case .other: "tag"
        }
    }
}
