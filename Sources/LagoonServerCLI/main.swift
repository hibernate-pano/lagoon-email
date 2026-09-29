// The CLI keeps the historical env-var contract for development and
// diagnostics: DATABASE_URL-era env vars are gone, but LAGOON_TOKEN_KEY,
// LAGOON_API_TOKEN, LAGOON_SERVER_HOST/PORT and the LLM_PROVIDER_* keys all
// still work. The app itself embeds `LagoonRuntime.start` and never uses this
// binary. Diagnostics: --self-test, --restore <uid>, --list-mailboxes,
// --find-subject <subject>. The embedded SQLite store lives where
// LAGOON_DB_PATH points (default: Application Support under the repo tree).
import Foundation
import Crypto
import Logging
import GRDB
import LagoonKit
import LagoonServer

@main
struct LagoonServerCLIMain {
    static func main() async throws {
        let logger = Logger(label: "lagoon.server")
        let env = ProcessInfo.processInfo.environment

        guard let tokenKey = env["LAGOON_TOKEN_KEY"], !tokenKey.isEmpty else {
            die("""
                refusing to start: LAGOON_TOKEN_KEY is missing.
                It must be base64 of exactly 32 random bytes. Generate one with:
                  export LAGOON_TOKEN_KEY="$(openssl rand -base64 32)"
                """)
        }
        guard Data(base64Encoded: tokenKey)?.count == 32 else {
            die("refusing to start: LAGOON_TOKEN_KEY is malformed (need base64 of 32 bytes)")
        }

        let dbPath = env["LAGOON_DB_PATH"]
            ?? defaultDatabasePath().appendingPathComponent("lagoon.sqlite").path
        let cfg = LagoonRuntimeConfiguration(
            dbPath: dbPath,
            host: env["LAGOON_SERVER_HOST"] ?? "127.0.0.1",
            port: Int(env["LAGOON_SERVER_PORT"] ?? "8080") ?? 8080,
            apiToken: env["LAGOON_API_TOKEN"],
            tokenKeyBase64: tokenKey
        )

        // Diagnostics run against the store and exit; they never serve HTTP.
        let args = CommandLine.arguments
        let pool = try LagoonDatabase.open(path: cfg.dbPath)
        let diagnosticsDB = LagoonDB(pool)
        if args.contains("--self-test") {
            do {
                try await LagoonSelfTest.run(db: diagnosticsDB, logger: logger)
                return
            } catch {
                die("self-test failed: \(error)")
            }
        }
        if let flag = args.firstIndex(of: "--restore") {
            guard args.index(after: flag) < args.endIndex else { die("--restore requires an IMAP UID") }
            do {
                try await LagoonSelfTest.restore(
                    remoteId: args[args.index(after: flag)], db: diagnosticsDB, logger: logger
                )
                return
            } catch {
                die("restore failed: \(error)")
            }
        }
        if args.contains("--list-mailboxes") {
            do {
                try await LagoonSelfTest.listMailboxes(db: diagnosticsDB, logger: logger)
                return
            } catch {
                die("mailbox listing failed: \(error)")
            }
        }
        if let flag = args.firstIndex(of: "--find-subject") {
            guard args.index(after: flag) < args.endIndex else { die("--find-subject requires a subject") }
            do {
                try await LagoonSelfTest.find(
                    subject: args[args.index(after: flag)], db: diagnosticsDB, logger: logger
                )
                return
            } catch {
                die("message lookup failed: \(error)")
            }
        }

        do {
            let server = try await LagoonRuntime.start(cfg, logger: logger)
            // Dev/diagnostic binary: SIGINT/SIGTERM exit the process directly.
            // SQLite WAL is crash-safe, so no graceful-shutdown machinery is
            // wired here.
            signal(SIGINT) { _ in exit(0) }
            signal(SIGTERM) { _ in exit(0) }
            try await Task.sleep(for: .seconds(86_400 * 365))
            _ = server
        } catch {
            die("refusing to start: \(error)")
        }
    }

    static func defaultDatabasePath() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Lagoon", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func die(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
