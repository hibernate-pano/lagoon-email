import Foundation

/// The 「数据与备份」 strings.
///
/// They live here rather than in `L10n.swift` so that the file that
/// *defines* the feature and the file that *says* what it does are
/// separate. Two features that each need a string can then work at the
/// same time without both editing the same 2000-line file.
extension L10n {
    // MARK: - The section itself

    /// The heading of the data-and-backup section in the About sheet.
    public var backupSectionTitle: String { pick("数据与备份", "Data and backup") }

    /// The one-line explanation under the heading.
    ///
    /// It has to make the promise concrete, because the whole point of the
    /// section is that "your data stays on this Mac" is a promise the user
    /// can now check.
    public var backupSectionIntro: String {
        pick(
            "你的邮件只存在这台 Mac 上。下面的三个按钮让你随时把它拿走。",
            "Your mail lives only on this Mac. The three buttons below let you take it with you at any time."
        )
    }

    // MARK: - Open the data folder

    public var backupOpenFolder: String { pick("打开数据文件夹", "Open data folder") }
    public var backupOpenFolderHelp: String {
        pick("在访达里打开存放数据库的文件夹。", "Reveal the folder that holds the database in Finder.")
    }

    // MARK: - Back up now

    public var backupNow: String { pick("立即备份", "Back up now") }
    public var backupNowHelp: String {
        pick(
            "把整个数据库存成一个单独的文件——写入正在发生时也保证一致，不会拷到半个文件。",
            "Save the whole database as one single file — consistent even while the app is writing, never a half-copied file."
        )
    }
    /// The banner title after a backup succeeded.
    public var backupSucceeded: String { pick("备份完成", "Backup complete") }
    /// The banner detail after a backup succeeded — it names the file, so
    /// the user knows exactly what to look for.
    public func backupSucceededDetail(name: String) -> String {
        pick(
            "已保存到 \(name)。",
            "Saved to \(name)."
        )
    }
    /// The banner title after a backup failed.
    public var backupFailed: String { pick("备份失败", "Backup failed") }
    /// The banner detail after a backup failed: what failed, and why.
    public func backupFailedDetail(reason: String) -> String {
        pick(
            "没有生成备份文件：\(reason)。你的邮件没有受影响，可以再试一次。",
            "No backup file was produced: \(reason). Your mail is untouched — you can try again."
        )
    }
    /// The banner title when the data directory could not be found at all.
    public var backupDataDirectoryMissing: String {
        pick("找不到数据文件夹", "Could not find the data folder")
    }
    public var backupDataDirectoryMissingDetail: String {
        pick(
            "系统没有告诉应用数据应该放在哪里，所以没法备份。",
            "The system did not tell the app where to store data, so there was nothing to back up."
        )
    }
    /// The reason recorded when the snapshot came out empty.
    ///
    /// Its own string rather than a generic one: zero bytes from `VACUUM INTO`
    /// on a database that exists is a *specific* fault, and naming it is what
    /// lets the user report something useful.
    public var backupSnapshotEmpty: String {
        pick("备份文件是空的", "the snapshot file is empty")
    }
    /// The reason recorded when the export file could not be created.
    public var backupExportWriteFailed: String {
        pick("无法创建文件", "could not create the file")
    }
    /// The date-stamped part of the default file name.
    ///
    /// `备份` in Chinese, `backup` in English — the name is user-visible copy
    /// like any other, so it goes through `L10n` rather than being hardcoded.
    public var backupFileNamePrefix: String { pick("备份", "backup") }

    // MARK: - Export as .mbox

    public var backupExportMbox: String { pick("导出全部为 .mbox", "Export all as .mbox") }
    public var backupExportMboxHelp: String {
        pick(
            "把本地已知的所有邮件导成一个 .mbox 文件——Thunderbird、Outlook、Apple 邮件都能直接导入。",
            "Export every mail the app knows about into one .mbox file — Thunderbird, Outlook and Apple Mail can all import it."
        )
    }
    /// The banner title after an export succeeded.
    public var backupExportSucceeded: String { pick("导出完成", "Export complete") }
    /// The banner detail after an export succeeded. It names the file *and*
    /// the count, because "how many mails did I actually get" is the first
    /// question a user asks of an export.
    public func backupExportSucceededDetail(name: String, count: Int) -> String {
        pick(
            "已导出 \(count) 封到 \(name)。",
            "Exported \(count) messages to \(name)."
        )
    }
    /// The banner detail when the export finished but some messages could not
    /// be fetched.
    ///
    /// Partial success is reported as partial success. Saying "导出完成" over
    /// a file that silently dropped a hundred messages is the kind of quiet
    /// wrong answer this product exists to avoid — the user would import it
    /// and never learn what was missing.
    public func backupExportSkippedDetail(name: String, exported: Int, skipped: Int) -> String {
        pick(
            "已导出 \(exported) 封到 \(name)；另有 \(skipped) 封取不到（可能已在服务器上删除），没有写进文件。",
            "Exported \(exported) messages to \(name); \(skipped) could not be fetched (they may be gone from the server) and are not in the file."
        )
    }
    /// The banner title after an export failed.
    public var backupExportFailed: String { pick("导出失败", "Export failed") }
    /// The banner detail after an export failed.
    ///
    /// It says *what* went wrong and how far the export got, because a
    /// partial export is a real thing: the user has to know whether the
    /// file they are looking at is complete.
    public func backupExportFailedDetail(reason: String, exported: Int, total: Int) -> String {
        pick(
            "已导出 \(exported)/\(total) 封后中断：\(reason)。文件不完整。",
            "Stopped after \(exported) of \(total) messages: \(reason). The file is incomplete."
        )
    }
    /// The banner title when the export was cancelled by the user.
    public var backupExportCancelled: String { pick("导出已取消", "Export cancelled") }
    /// The banner detail when the export was cancelled.
    public func backupExportCancelledDetail(exported: Int) -> String {
        pick(
            "已导出 \(exported) 封后停止。文件不完整。",
            "Stopped after \(exported) messages. The file is incomplete."
        )
    }
    /// The progress line while an export runs.
    public func backupExportProgress(done: Int, total: Int) -> String {
        pick(
            "正在导出 \(done)/\(total)…",
            "Exporting \(done) of \(total)…"
        )
    }
    /// The button that stops a running export.
    public var backupExportCancel: String { pick("停止导出", "Stop export") }

    // MARK: - The export scope

    /// The label of the export-scope picker.
    public var backupExportScopeLabel: String { pick("导出范围", "Export scope") }
    /// Export only the account the app is showing.
    public var backupExportScopeActive: String { pick("当前账户", "Current account") }
    /// Export every connected account into one file.
    public var backupExportScopeAll: String { pick("全部账户", "All accounts") }
    /// The detail under the scope picker.
    public var backupExportScopeHelp: String {
        pick(
            "「当前账户」只导出正在看的那个邮箱；「全部账户」把所有已连接的邮箱合并进同一个文件。",
            "“Current account” exports only the mailbox you are looking at; “All accounts” merges every connected mailbox into one file."
        )
    }
    /// Shown when there is no account to export at all.
    public var backupExportNoAccount: String {
        pick("没有可导出的账户", "There is no account to export")
    }
    public var backupExportNoAccountDetail: String {
        pick(
            "先连接一个邮箱，再回来导出。",
            "Connect a mailbox first, then come back and export."
        )
    }
}
