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

        // The body key seals the cached mail body at rest (spec §6.6 rule 5).
        // It is a separate key from the credential key on purpose — the two
        // protect different data, and rotating one must not orphan the other.
        // It has to be set before the store is opened, because the migration
        // that seals a legacy store runs there.
        guard let bodyKey = env["LAGOON_BODY_KEY"], !bodyKey.isEmpty else {
            die("""
                refusing to start: LAGOON_BODY_KEY is missing.
                It must be base64 of exactly 32 random bytes. Generate one with:
                  export LAGOON_BODY_KEY="$(openssl rand -base64 32)"
                To share data with the app, use the value of its Keychain item
                'lagoon.bodyKey'.
                """)
        }
        guard Data(base64Encoded: bodyKey)?.count == 32 else {
            die("refusing to start: LAGOON_BODY_KEY is malformed (need base64 of 32 bytes)")
        }
        BodyCipher.keyProvider = {
            guard let data = Data(base64Encoded: bodyKey), data.count == 32 else {
                throw BodyCipherError.badKey
            }
            return SymmetricKey(data: data)
        }

        let dbPath = env["LAGOON_DB_PATH"]
            ?? defaultDatabasePath().appendingPathComponent("lagoon.sqlite").path
        let cfg = LagoonRuntimeConfiguration(
            dbPath: dbPath,
            host: env["LAGOON_SERVER_HOST"] ?? "127.0.0.1",
            port: Int(env["LAGOON_SERVER_PORT"] ?? "8080") ?? 8080,
            apiToken: env["LAGOON_API_TOKEN"],
            tokenKeyBase64: tokenKey,
            bodyKey: bodyKey
        )

        // Diagnostics run against the store and exit; they never serve HTTP.
        let args = CommandLine.arguments
        // An unknown flag must **stop** the run, not be ignored.
        //
        // This CLI used to ignore any argument it did not recognise and
        // carry on against the default store — the user's real mailbox, in
        // Application Support. So a command that said `--db /tmp/copy.sqlite`
        // (a natural thing to try) silently ran against the live database
        // instead, migrating it with whatever key the environment happened to
        // carry. That is how the real store got sealed with a throwaway key
        // on 2026-10-20.
        //
        // The rule now: every argument must be one this binary knows. A typo
        // fails loudly, before the store is opened — so nothing is written.
        let knownFlags: Set<String> = [
            "--self-test", "--list-mailboxes", "--find-subject", "--restore",
            "--help", "-h",
        ]
        let knownValueFlags: Set<String> = ["--restore", "--find-subject"]
        var index = 1
        while index < args.count {
            let argument = args[index]
            if knownFlags.contains(argument) {
                if knownValueFlags.contains(argument) {
                    // The flag takes a value; skip it as well.
                    index += 2
                } else {
                    index += 1
                }
                continue
            }
            die("""
                unknown argument '\(argument)'.
                This CLI never opens a store it was not told to: set
                LAGOON_DB_PATH to the file you mean, or use one of:
                  --self-test          run the store's self-check
                  --list-mailboxes     list the account's IMAP folders
                  --find-subject <s>   find a message by subject
                  --restore <uid>      restore a message from the server's Trash
                (no argument was applied; nothing was written.)
                """)
        }
        if args.contains("--help") || args.contains("-h") {
            print("""
                LagoonServerCLI — diagnostics against the local store.
                  LAGOON_DB_PATH     the SQLite file to open (required: no default is assumed)
                  LAGOON_TOKEN_KEY   base64 of 32 bytes
                  LAGOON_BODY_KEY    base64 of 32 bytes
                """)
            return
        }
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
        // Read-only coverage report (LIST + SELECT per folder): the provider's
        // per-folder counts next to the local store's. No mail is sent and
        // nothing is written.
        // One real pull round against the live mailbox, reported and discarded
        // (no writes, cursor not advanced, session handed back).
        if args.contains("--dry-run-pull") {
            do {
                try await LagoonSelfTest.dryRunPull(db: diagnosticsDB, logger: logger)
                return
            } catch {
                die("dry-run pull failed: \(error)")
            }
        }
        if args.contains("--mailbox-stats") {
            do {
                try await LagoonSelfTest.mailboxStats(db: diagnosticsDB, logger: logger)
                return
            } catch {
                die("mailbox stats failed: \(error)")
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
