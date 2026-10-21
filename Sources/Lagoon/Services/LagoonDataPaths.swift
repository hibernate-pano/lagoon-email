import Foundation

/// Where Lagoon's local data lives — the one place that knows.
///
/// ## Why this file exists
///
/// Three surfaces need the same answer: the embedded server (which opens the
/// database there), the Settings window (which shows the path so the user can
/// find it) and the About sheet (which offers "open the data folder" and
/// "back up now"). They used to spell the path out separately, which is
/// exactly the shape that drifts: the moment the directory moves, one of the
/// three answers is a lie, and the user is the one who finds out — by
/// deleting the wrong folder.
///
/// So the path is computed **once**, here, and everyone reads it from here.
///
/// ## Why the directory name is a constant rather than a literal
///
/// `Bundle.main.bundleIdentifier` is nil for a bare `swift run` executable,
/// and its suffix is a UUID on a release build, so it cannot name a folder a
/// user will ever recognise. A fixed, human-readable name is the honest
/// choice: the user has to be able to type it, and "Lagoon" is what the
/// product calls itself.
public enum LagoonDataPaths {
    /// The folder name under Application Support.
    public static let directoryName = "Lagoon"

    /// The database file name inside that folder.
    public static let databaseFileName = "lagoon.sqlite"

    /// The app's data directory, or nil when the system will not say where
    /// Application Support is.
    ///
    /// `urls(for:in:)` answers with `~/Library/Application Support`, which
    /// macOS always provides — but "always" is not a guarantee, and a force
    /// unwrap on the launch path is a crash the user sees as "the app won't
    /// open" with no explanation. The caller decides what a missing directory
    /// means: the server fails loudly at boot (an honest, retryable boot
    /// screen), the UI shows an error.
    public static var appDirectory: URL? {
        FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first?.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// The database file inside the data directory.
    ///
    /// nil when the data directory itself is unavailable — the two answers
    /// are one thing: without Application Support there is no database
    /// either.
    public static var databaseURL: URL? {
        appDirectory?.appendingPathComponent(databaseFileName)
    }
}
