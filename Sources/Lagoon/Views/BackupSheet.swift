import SwiftUI
import AppKit
import LagoonKit

/// 「数据与备份」 — the promise "your data stays on this Mac", completed with
/// "and you can take it with you".
///
/// ## Why a sheet and not three buttons in the About box
///
/// The About box is 360 points and already holds the icon, the version, three
/// links and the privacy entry. The export alone needs a scope picker, a
/// progress line and a cancel button, and its failures need somewhere to say
/// what went wrong. Cramming that in would produce the thing this project
/// keeps refusing to ship: a control whose failure has nowhere to appear.
///
/// So the About sheet keeps one link, and the work happens here, where there
/// is room to be honest about what each action does and how it ended.
///
/// ## Why every action ends in a banner
///
/// A backup that silently does nothing is worse than no backup: the user
/// believes they are covered. Every path out of this sheet — success, failure,
/// cancellation — produces a `ErrorBanner`-shaped result with the file name
/// and the count, so "did it work?" is answered on screen rather than in the
/// user's guess.
struct BackupSheet: View {
    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var directory: DirectoryStore

    /// The result of the last action, shown inline.
    ///
    /// Inline rather than through `ErrorCenter`: the global banner lives on
    /// `RootView`, and a sheet covers it. A failure reported underneath the
    /// sheet the user is still looking at is the same as no report.
    @State private var result: ErrorBanner?
    @State private var isBackingUp = false

    /// Export state. One task handle, so Cancel can actually stop it.
    @State private var exportTask: Task<Void, Never>?
    @State private var exportProgress: (done: Int, total: Int)?
    @State private var exportCancelled = false
    @State private var exportScope: ExportScope = .active

    /// Which mailboxes the `.mbox` covers.
    private enum ExportScope: String, CaseIterable, Identifiable {
        case active
        case all

        var id: String { rawValue }

        func label(_ l10n: L10n) -> String {
            switch self {
            case .active: return l10n.backupExportScopeActive
            case .all: return l10n.backupExportScopeAll
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // The promise, stated before the controls: the whole
                    // point of the sheet is that "your data stays on this
                    // Mac" is a claim the user can now act on.
                    Text(l10n.backupSectionIntro)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let result {
                        NoticeBannerView(banner: result, onDismiss: { self.result = nil })
                            .padding(.horizontal, -4)
                    }
                    openFolderSection
                    snapshotSection
                    exportSection
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(
            width: LagoonSheetSize.standard.width,
            height: LagoonSheetSize.standard.height
        )
        .onDisappear {
            // A sheet that closes mid-export would otherwise leave the task
            // running with nowhere to report: it would write a file the user
            // has stopped waiting for, and its banner would land on a view
            // that is gone.
            exportTask?.cancel()
        }
    }

    private var header: some View {
        HStack {
            Label(l10n.backupSectionTitle, systemImage: "externaldrive.badge.timemachine")
                .font(.headline)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(l10n.dismiss)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Open the data folder

    private var openFolderSection: some View {
        section(
            title: l10n.backupOpenFolder,
            detail: l10n.backupOpenFolderHelp
        ) {
            Button {
                openDataFolder()
            } label: {
                Label(l10n.backupOpenFolder, systemImage: "folder")
            }
            .disabled(isBusy)
        }
    }

    private func openDataFolder() {
        guard let directory = LagoonDataPaths.appDirectory else {
            result = ErrorBanner(
                severity: .error,
                title: l10n.backupDataDirectoryMissing,
                detail: l10n.backupDataDirectoryMissingDetail,
                // Application Support is resolved per-process; a transient
                // failure there is worth one more try, and the button costs
                // nothing.
                actionLabel: l10n.retry,
                action: { [self] in await MainActor.run { self.openDataFolder() } }
            )
            return
        }
        // The folder exists as soon as the server has opened the database;
        // before that there is nothing to open and Finder would show the
        // enclosing directory instead — a confusing answer to "open my data".
        guard FileManager.default.fileExists(atPath: directory.path) else {
            result = ErrorBanner(
                severity: .error,
                title: l10n.backupDataDirectoryMissing,
                detail: l10n.backupDataDirectoryMissingDetail,
                // The usual cause is "the server has not started yet", which
                // resolves itself a moment later — so retry is the right
                // offer here.
                actionLabel: l10n.retry,
                action: { [self] in await MainActor.run { self.openDataFolder() } }
            )
            return
        }
        NSWorkspace.shared.open(directory)
    }

    // MARK: - Back up now

    private var snapshotSection: some View {
        section(
            title: l10n.backupNow,
            detail: l10n.backupNowHelp
        ) {
            Button {
                Task { await backupNow() }
            } label: {
                HStack(spacing: 6) {
                    if isBackingUp { ProgressView().controlSize(.small) }
                    Label(l10n.backupNow, systemImage: "arrow.down.doc")
                }
            }
            .disabled(isBusy)
        }
    }

    /// Snapshots the database to a path the user chooses.
    ///
    /// The panel comes first, before any work: a user who changes their mind
    /// at the save dialog should not have paid for a copy of a 2 GB database.
    @MainActor
    private func backupNow() async {
        result = nil
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
            result = ErrorBanner(
                severity: .error,
                title: l10n.backupFailed,
                detail: l10n.downloadNoWindow,
                // Same as the attachment download: the window was not
                // attachable at that instant, and by the time the user
                // presses this it may well be.
                actionLabel: l10n.retry,
                action: { await backupNow() }
            )
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = BackupService.defaultSnapshotName(date: Date())
        panel.canCreateDirectories = true
        panel.allowedContentTypes = []
        panel.message = l10n.backupNowHelp
        let response = await panel.beginSheetModal(for: window)
        guard response == .OK, let url = panel.url else { return }

        isBackingUp = true
        defer { isBackingUp = false }
        do {
            // Off the main actor: `VACUUM INTO` reads and writes the whole
            // database and on a large mailbox that is seconds of blocking,
            // which on the main thread would freeze the window the sheet is
            // attached to.
            let snapshot = try await Task.detached(priority: .userInitiated) {
                try BackupService.snapshotDatabase(to: url)
            }.value
            result = ErrorBanner(
                severity: .success,
                title: l10n.backupSucceeded,
                detail: l10n.backupSucceededDetail(name: snapshot.url.lastPathComponent),
                // A confirmation, not a problem: it clears itself so the
                // sheet does not keep a stale "done" line from an earlier
                // attempt.
                dismissible: true,
                autoDismissAfter: .seconds(8)
            )
        } catch {
            result = ErrorBanner(
                severity: .error,
                title: l10n.backupFailed,
                detail: l10n.backupFailedDetail(reason: error.lagoonUIMessage),
                // A failed snapshot is retryable in the cases that actually
                // happen: a busy database (`SQLITE_BUSY`), a destination the
                // user can now pick differently, a full disk that has been
                // cleared. Retrying reopens the panel, so the user is not
                // committed to the same path.
                actionLabel: l10n.retry,
                action: { await backupNow() }
            )
        }
    }

    // MARK: - Export as .mbox

    private var exportSection: some View {
        section(
            title: l10n.backupExportMbox,
            detail: l10n.backupExportMboxHelp
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Picker(l10n.backupExportScopeLabel, selection: $exportScope) {
                    ForEach(ExportScope.allCases) { scope in
                        Text(scope.label(l10n)).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel(l10n.backupExportScopeLabel)
                .disabled(isBusy)

                Text(l10n.backupExportScopeHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let exportProgress {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(l10n.backupExportProgress(
                            done: exportProgress.done, total: exportProgress.total
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Spacer()
                    }
                    Button(l10n.backupExportCancel) {
                        exportCancelled = true
                        exportTask?.cancel()
                    }
                    .controlSize(.small)
                } else {
                    Button {
                        Task { await exportMbox() }
                    } label: {
                        Label(l10n.backupExportMbox, systemImage: "tray.and.arrow.up")
                    }
                    .disabled(isBusy || directory.accounts.isEmpty)
                }

                if directory.accounts.isEmpty {
                    Text(l10n.backupExportNoAccount)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Runs the export, off the main actor, with progress and cancellation.
    @MainActor
    private func exportMbox() async {
        result = nil
        let accounts = accountsForScope()
        guard !accounts.isEmpty else {
            result = ErrorBanner(
                severity: .error,
                title: l10n.backupExportNoAccount,
                detail: l10n.backupExportNoAccountDetail,
                // An account can finish connecting while the sheet is open,
                // and the segmented picker above is the real fix. Retry costs
                // one check and re-reads the scope.
                actionLabel: l10n.retry,
                action: { await exportMbox() }
            )
            return
        }
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
            result = ErrorBanner(
                severity: .error,
                title: l10n.backupExportFailed,
                detail: l10n.downloadNoWindow,
                actionLabel: l10n.retry,
                action: { await exportMbox() }
            )
            return
        }
        let label = exportScope == .all
            ? l10n.backupExportScopeAll
            : (accounts.first?.email ?? l10n.backupExportScopeActive)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = BackupService.defaultExportName(
            label: label, date: Date()
        )
        panel.canCreateDirectories = true
        panel.allowedContentTypes = []
        panel.message = l10n.backupExportMboxHelp
        let response = await panel.beginSheetModal(for: window)
        guard response == .OK, let url = panel.url else { return }

        exportCancelled = false
        exportProgress = (0, 0)
        let api = APIClient.shared
        let scopeAccounts = accounts
        let l10n = self.l10n
        let task = Task { @MainActor in
            do {
                // The index and the fetch both live off the main actor; only
                // the progress updates come back to it.
                let items = try await Self.collectIndex(
                    accounts: scopeAccounts, api: api
                )
                exportProgress = (0, items.count)
                let summary = try await BackupService.writeMbox(
                    items: items,
                    to: url,
                    fetch: { item in
                        // The raw bytes come from the existing route — the
                        // exact `.eml` the detail view already offers, not a
                        // second rendering of the message.
                        try await Self.fetchRaw(api: api, item: item)
                    },
                    progress: { done, total in
                        Task { @MainActor in exportProgress = (done, total) }
                    }
                )
                exportProgress = nil
                result = ErrorBanner(
                    severity: summary.skipped > 0 ? .warning : .success,
                    title: l10n.backupExportSucceeded,
                    detail: summary.skipped > 0
                        ? l10n.backupExportSkippedDetail(
                            name: summary.url.lastPathComponent,
                            exported: summary.exported,
                            skipped: summary.skipped
                        )
                        : l10n.backupExportSucceededDetail(
                            name: summary.url.lastPathComponent,
                            count: summary.exported
                        ),
                    dismissible: true,
                    autoDismissAfter: summary.skipped > 0 ? nil : .seconds(10)
                )
            } catch let error as BackupError {
                exportProgress = nil
                // Cancellation is not a failure, but it is not a success
                // either: the file on disk is real and partial, and saying so
                // is the only honest report.
                if case .exportCancelled(let exported) = error {
                    result = ErrorBanner(
                        severity: .warning,
                        title: l10n.backupExportCancelled,
                        detail: l10n.backupExportCancelledDetail(exported: exported)
                    )
                } else {
                    result = ErrorBanner(
                        severity: .error,
                        title: l10n.backupExportFailed,
                        detail: error.lagoonUIMessage,
                        // Retry restarts the export from the beginning. It is
                        // honest about what it costs: a partial file is
                        // already written, and the retry replaces it only on
                        // success (the writer stages + renames).
                        actionLabel: l10n.retry,
                        action: { await exportMbox() }
                    )
                }
            } catch is CancellationError {
                exportProgress = nil
                result = ErrorBanner(
                    severity: .warning,
                    title: l10n.backupExportCancelled,
                    detail: l10n.backupExportCancelledDetail(exported: 0)
                )
            } catch {
                exportProgress = nil
                result = ErrorBanner(
                    severity: .error,
                    title: l10n.backupExportFailed,
                    detail: l10n.backupExportFailedDetail(
                        reason: error.lagoonUIMessage, exported: 0, total: 0
                    ),
                    actionLabel: l10n.retry,
                    action: { await exportMbox() }
                )
            }
        }
        exportTask = task
        await task.value
        exportTask = nil
    }

    /// The account ids the current scope covers.
    private func accountsForScope() -> [ConnectedAccount] {
        switch exportScope {
        case .active:
            if let active = directory.active { return [active] }
            return directory.accounts.first.map { [$0] } ?? []
        case .all:
            return directory.accounts
        }
    }

    /// The index for every selected account, oldest first within each.
    ///
    /// `itemAccount` is carried alongside each message because a remote id is
    /// only unique per account, and the fetch route needs to know which
    /// mailbox to ask. A dictionary from key to account id is built here, so
    /// the fetch closure stays synchronous and cheap.
    nonisolated static func collectIndex(
        accounts: [ConnectedAccount],
        api: APIClient
    ) async throws -> [BackupService.ExportItem] {
        var items: [BackupService.ExportItem] = []
        for account in accounts {
            let headers = try await api.fetchExportIndex(accountId: account.id)
            items.append(contentsOf: headers.map {
                BackupService.ExportItem(
                    remoteId: $0.remoteId,
                    fromAddress: $0.fromAddress,
                    receivedAt: $0.receivedAt,
                    accountId: account.id
                )
            })
        }
        return items
    }

    nonisolated static func fetchRaw(
        api: APIClient, item: BackupService.ExportItem
    ) async throws -> Data {
        try await api.downloadRawMessage(
            accountId: item.accountId, remoteId: item.remoteId
        )
    }

    private var isBusy: Bool {
        isBackingUp || exportProgress != nil
    }

    /// One heading, one explanation, and the control.
    private func section<Content: View>(
        title: String,
        detail: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            content()
                .padding(.top, 2)
        }
    }
}
