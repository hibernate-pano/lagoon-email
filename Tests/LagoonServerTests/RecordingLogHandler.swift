import Foundation
import Logging

/// Collects emitted log lines so a test can assert that a failure the code
/// deliberately swallows was at least recorded. The IMAP pull path is
/// otherwise silent by design, which is how a whole backfill window's
/// previews could disappear with no trace in any log.
final class RecordingLogHandler: LogHandler, @unchecked Sendable {
    let label: String
    private let lock = NSLock()
    private var storage: [(level: Logger.Level, message: String)] = []
    var metadata: Logger.Metadata = [:]
    var metadataProvider: Logger.MetadataProvider?
    /// Everything, including `.debug` — the whole point is to prove a
    /// deliberately swallowed failure left a trace.
    var logLevel: Logger.Level = .trace

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    init(label: String) {
        self.label = label
    }

    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        lock.lock()
        storage.append((level, message.description))
        lock.unlock()
    }

    /// Every message, in emission order.
    var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage.map(\.message)
    }

    var warnings: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage.filter { $0.level >= .warning }.map(\.message)
    }
}

extension Logger {
    /// A logger plus the handler behind it, for tests that assert on what a
    /// deliberately non-fatal failure recorded.
    static func recording(label: String) -> (logger: Logger, handler: RecordingLogHandler) {
        let handler = RecordingLogHandler(label: label)
        var logger = Logger(label: label)
        logger.handler = handler
        return (logger, handler)
    }
}
