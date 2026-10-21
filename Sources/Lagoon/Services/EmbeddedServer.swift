import Foundation
import Security
import LagoonKit
import LagoonServer

/// Boots the server inside the app process (V3 embedded runtime).
///
/// Everything the old Docker/Postgres/launchd setup provided is replaced:
/// the SQLite store lives under Application Support, the AES key and API
/// token live in the Keychain (generated on first launch), and the AI
/// provider keys are migrated once from the legacy repo `.env` the launchd
/// agent used to source. The HTTP layer stays on loopback because the
/// client keeps talking to the same API surface — only the process boundary
/// is gone.
enum EmbeddedServer {
    static let tokenKeyService = "lagoon.tokenKey"
    /// The key that seals the mail body at rest. Separate from the
    /// credential key: they protect different data with different lifetimes,
    /// and rotating one must not orphan the other.
    static let bodyKeyService = "lagoon.bodyKey"
    static let envService = "lagoon.envJSON"
    /// The per-install API token. A dev-set `LAGOON_API_TOKEN` env var wins
    /// over this; the client reads the same value from `UserDefaults`.
    static let apiTokenService = "lagoon.apiTokenSecret"

    /// Keys that may be carried over from the legacy `.env`/launchd setup.
    private static let migratablePrefixes = ["LLM_PROVIDER_", "LAGOON_"]

    /// Starts the embedded server and returns the port it bound.
    ///
    /// ## Why the Keychain work happens off the main thread
    ///
    /// `SecItemCopyMatching` can block for as long as the user takes to
    /// answer the system's "…wants to use the secret stored in the keychain"
    /// dialog. This function is reached from `EmbeddedServerBoot.run()`, which
    /// is `@MainActor`, so a Keychain call made inline here blocks the main
    /// thread — and the main thread is the one AppKit needs to finish
    /// launching and put a window on screen. The result was an app that
    /// appeared to hang with no window at all.
    ///
    /// So every Keychain read and write below runs on a detached task, and
    /// only the pure computation (which port, which token) happens inline.
    static func bootstrap() async throws -> Int {
        // The legacy `.env` import is a *background* concern: it must never
        // stand between the app and a listening socket. It runs detached and
        // its result is applied when it arrives.
        let legacyMigration = Task.detached(priority: .utility) {
            await migrateLegacyEnvIfNeeded()
        }

        // Resolve the secrets in the background. Every read is bounded by
        // `KeychainReader`'s deadline, so none of them can wedge the app —
        // the whole point of the deadline is that a blocked Keychain
        // produces an answer instead of a hang.
        let secrets = Task.detached(priority: .userInitiated) {
            await resolveAllSecrets()
        }

        // The API token. A dev-set env var wins (so `swift run` against the
        // app's server keeps working). Otherwise the token decides what the
        // client will send, and the client reads it from `UserDefaults` —
        // so the value the server enforces and the value the client presents
        // must come from the same place. Both are therefore resolved
        // **synchronously** here, from `UserDefaults`, and the Keychain copy
        // only ever *seeds* that default (see `resolveAllSecrets`).
        //
        // ## Why this is not "just pass nil until the Keychain answers"
        //
        // A nil token means the auth middleware is **off** (`APIAuthMiddleware`
        // gates only when a token is set). Passing nil on launch would bind
        // an unauthenticated server, then persist a freshly generated token
        // that a later launch would start enforcing — and every request the
        // client made in between would 401. Worse, if the Keychain stayed
        // blocked forever, the server would keep serving without auth while
        // the UI believed a token was set.
        //
        // Seeding from `UserDefaults` costs nothing: it is a local read with
        // no authorization prompt, so it cannot hang. Generating a token when
        // both sources are empty is equally safe — it is a `UUID()`, not a
        // Keychain call — and it is stored to `UserDefaults` immediately so
        // the client and the server agree on it from the first request.
        let env = ProcessInfo.processInfo.environment
        var apiToken = env["LAGOON_API_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if apiToken?.isEmpty == true { apiToken = nil }
        if apiToken == nil {
            let stored = UserDefaults.standard.string(forKey: "lagoon.apiToken")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            apiToken = (stored?.isEmpty == false) ? stored : nil
        }
        if apiToken == nil {
            let generated = UUID().uuidString
            UserDefaults.standard.set(generated, forKey: "lagoon.apiToken")
            apiToken = generated
        }

        // Environment for the runtime: Keychain (migrated) first, process env
        // wins on conflict so dev overrides keep working. The process env is
        // known synchronously, so the *minimum* environment is available
        // immediately; the Keychain values are added when they arrive.
        var runtimeEnv: [String: String] = [:]
        for (key, value) in env {
            if migratablePrefixes.contains(where: { key.hasPrefix($0) }) {
                runtimeEnv[key] = value
            }
        }
        // providers.json: prefer an explicit config path that still exists,
        // else the copy bundled into the .app Resources.
        if let configured = runtimeEnv["LAGOON_PROVIDER_CONFIG"],
           !FileManager.default.fileExists(atPath: configured) {
            runtimeEnv.removeValue(forKey: "LAGOON_PROVIDER_CONFIG")
        }
        if runtimeEnv["LAGOON_PROVIDER_CONFIG"] == nil,
           let bundled = Bundle.main.url(forResource: "providers", withExtension: "json") {
            runtimeEnv["LAGOON_PROVIDER_CONFIG"] = bundled.path
        }

        // `urls(for:in:)` answers with `~/Library/Application Support`, which
        // macOS always provides — but "always" is not a guarantee, and this
        // line is on the launch path, where a force unwrap is a crash the
        // user sees as "the app won't open" with no explanation.
        //
        // The alternative — falling back to a temporary directory — was worse:
        // the app would start and silently put the database somewhere the OS
        // is free to delete, so the user's mail would appear to vanish on
        // the next relaunch. Failing loudly puts the problem on the boot
        // screen with a retry, which is the honest outcome.
        //
        // The path itself comes from `LagoonDataPaths` — the same answer the
        // Settings window shows and the About sheet opens. It used to be
        // spelled out here, and the two copies were free to drift: the moment
        // the directory moved, this server would open a database somewhere
        // else while the UI pointed the user at a folder that was empty.
        guard let dbURL = LagoonDataPaths.databaseURL else {
            throw EmbeddedServerError.appSupportUnavailable
        }
        let dbPath = dbURL.path

        let pinnedPort = env["LAGOON_SERVER_PORT"].flatMap(Int.init)
            ?? UserDefaults.standard.object(forKey: "lagoon.serverPort") as? Int
        let candidatePorts: [Int]
        if let pinnedPort, pinnedPort > 0 {
            // Pinned port first, but never alone: a just-quit instance's
            // socket can still be releasing, and a bind race must degrade to
            // another port (APIClient re-reads the persisted one), not brick
            // the app into a boot-error screen.
            candidatePorts = [pinnedPort] + (8080...8090).filter { $0 != pinnedPort }
        } else {
            candidatePorts = Array(8080...8090)
        }

        var lastError: Error?
        for port in candidatePorts {
            let configuration = LagoonRuntimeConfiguration(
                dbPath: dbPath,
                host: "127.0.0.1",
                port: port,
                apiToken: apiToken,
                // The placeholder is a distinct, obviously-fake key. It is
                // what makes the "not ready yet" case legible: a decryption
                // failure against a plausible-looking key reads as "the
                // database is corrupted", which is a completely wrong
                // diagnosis.
                tokenKeyBase64: PlaceholderSecret.keyBase64,
                bodyKey: PlaceholderSecret.keyBase64,
                environment: runtimeEnv,
                usesPlaceholderKeys: true
            )
            do {
                let server = try await LagoonRuntime.start(configuration, logger: .init(label: "lagoon.embedded"))
                UserDefaults.standard.set(port, forKey: "lagoon.serverPort")
                // The handle is what keeps the server alive. `RunningLagoonServer`
                // owns the `ServiceGroup` the HTTP service runs inside, so the
                // moment the last reference goes away the group is released and
                // the service stops. The old line here read
                // `Task { _ = server }` under a comment claiming it kept the
                // handle alive — it did the opposite: the closure ended at
                // once, the capture was released, and the server went with it.
                await EmbeddedServerHandle.shared.adopt(server)

                // The port is bound and the app is usable. Now finish the
                // secret work *without* making the caller wait for it: the
                // next launch finds the keys already resolved, and the AI
                // settings sheet reads the same store directly.
                Task.detached(priority: .utility) {
                    let resolved = await secrets.value
                    installResolvedKeys(resolved)
                    _ = await legacyMigration.value
                }
                return port
            } catch {
                lastError = error
            }
        }
        throw lastError ?? EmbeddedServerError.startFailed
    }

    /// The secrets the server needs, once resolved.
    struct ResolvedSecrets: Sendable {
        var tokenKey: String?
        var bodyKey: String?
        var apiToken: String?
        var environment: [String: String]
    }

    /// Resolves every secret, off the critical path.
    ///
    /// Each secret is independent: a blocked token key does not stop the
    /// body key from being read, and one failure does not abort the rest.
    /// Every read is bounded by `KeychainReader`'s deadline, so this
    /// function always returns.
    static func resolveAllSecrets() async -> ResolvedSecrets {
        async let tokenKey = resolveString(service: tokenKeyService) { randomKeyBase64() }
        async let bodyKey = resolveString(service: bodyKeyService) { randomKeyBase64() }
        async let apiToken = resolveAPIToken()
        async let environment = resolveEnvironment()

        let (resolvedTokenKey, resolvedBodyKey, resolvedAPIToken, resolvedEnvironment) =
            await (tokenKey, bodyKey, apiToken, environment)
        return ResolvedSecrets(
            tokenKey: resolvedTokenKey,
            bodyKey: resolvedBodyKey,
            apiToken: resolvedAPIToken,
            environment: resolvedEnvironment
        )
    }

    /// Resolves the stored API token, **without** ever changing what the
    /// client is using.
    ///
    /// The server already bound with the token `bootstrap()` resolved from
    /// the environment / `UserDefaults` (and that is the value the client
    /// presents). So this function must not generate a new one, and must
    /// not overwrite `UserDefaults`: doing either would make the server and
    /// the client disagree, and every request would 401 until the app was
    /// restarted twice.
    ///
    /// What it *may* do is seed the stored default from the Keychain when
    /// the default is empty — the first launch after an upgrade, where the
    /// token exists in the Keychain but not yet in `UserDefaults`. That
    /// cannot affect this session (the session already has its token) and
    /// makes the next launch read the same value.
    ///
    /// A failed read changes nothing. A new token generated over an
    /// unreadable one would replace a secret the server may already be
    /// enforcing.
    static func resolveAPIToken() async -> String? {
        switch await KeychainReader.readString(service: apiTokenService) {
        case .found(let value):
            let stored = UserDefaults.standard.string(forKey: "lagoon.apiToken")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if stored?.isEmpty != false {
                UserDefaults.standard.set(value, forKey: "lagoon.apiToken")
            }
            return value
        case .failed, .missing:
            return nil
        }
    }

    /// Reads a secret, or generates one, returning `nil` when the item is
    /// present but unreadable.
    ///
    /// The order matters: **read first, generate only if there is nothing
    /// to read**. A failed read is not "nothing to read" — it returns
    /// `nil` and no new secret is generated, because generating one would
    /// silently orphan whatever the user already has (a new token key
    /// cannot decrypt the credentials already sealed with the old one).
    static func resolveString(service: String, generate: () -> String) async -> String? {
        switch await KeychainReader.readString(service: service) {
        case .found(let value):
            return value
        case .failed:
            // The item is there but unreadable. Do NOT generate a
            // replacement — a new key cannot open what the old one sealed,
            // and overwriting would destroy the user's data.
            return nil
        case .missing:
            // Nothing stored: create one. This is the only case where
            // writing is safe — the absence is proven, not assumed.
            let generated = generate()
            do {
                try KeychainStore.saveString(generated, service: service)
                return generated
            } catch {
                return nil
            }
        }
    }

    /// Reads the runtime environment from the Keychain.
    static func resolveEnvironment() async -> [String: String] {
        switch await KeychainReader.readString(service: envService) {
        case .found(let raw):
            return (try? JSONDecoder().decode([String: String].self, from: Data(raw.utf8))) ?? [:]
        case .missing, .failed:
            // A failed read yields no overrides rather than a wrong guess.
            // The migration already refuses to overwrite a stored value it
            // could not read, so nothing is lost here.
            return [:]
        }
    }

    /// Installs the real cipher keys, once they are known.
    ///
    /// A key that did not resolve leaves the placeholder in place. That is
    /// deliberate: a missing key must fail closed and loudly (the app
    /// shows the Keychain screen), never be replaced by a freshly
    /// generated one — a new key cannot open what the old one sealed.
    static func installResolvedKeys(_ secrets: ResolvedSecrets) {
        if let tokenKey = secrets.tokenKey {
            CipherKeyInstaller.installTokenKey(base64: tokenKey)
        }
        if let bodyKey = secrets.bodyKey {
            CipherKeyInstaller.installBodyKey(base64: bodyKey)
        }
    }

    /// A fresh 32-byte key, base64-encoded.
    static func randomKeyBase64() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { return PlaceholderSecret.keyBase64 }
        return Data(bytes).base64EncodedString()
    }

    // MARK: - Legacy .env migration (launchd → Keychain)

    /// One-time import of the launchd agent's `.env` so the AI keys and the
    /// budget cap survive the switch without the user re-entering them. The
    /// launchd plist names the repo working directory the old agent sourced
    /// `.env` from.
    ///
    /// ## Why the read below is not a `try?`
    ///
    /// The old code read the stored environment with `try?` and asked "is
    /// it there?". A Keychain **failure** and a **missing item** both
    /// answered that question with `nil` — so a read that never succeeded
    /// was indistinguishable from "the user has nothing stored". The
    /// function then went on to write `"{}"` over the value it had failed
    /// to read.
    ///
    /// That is data loss: the AI provider keys and the budget cap were
    /// destroyed by a read that never returned, and the user was then
    /// asked to paste their API key again. The fix is to keep the three
    /// answers apart — the value, "there is nothing stored", and "I could
    /// not read it" — and to write **only** in the second case.
    static func migrateLegacyEnvIfNeeded() async {
        // The read is bounded: on a rebuilt ad-hoc-signed build this read
        // can block forever, and a migration that blocks forever is a boot
        // that never finishes.
        switch await KeychainReader.readString(service: envService) {
        case .found:
            // Already migrated. Nothing to do.
            return
        case .failed:
            // The item exists but could not be read. Writing anything now
            // would destroy a value we never saw. Leave it alone.
            return
        case .missing:
            break
        }

        let envPath = legacyEnvPath()
        guard let envPath, let raw = try? String(contentsOfFile: envPath, encoding: .utf8) else {
            // Nothing to migrate; store an empty map so we never retry.
            // This write is safe *because* the read above proved there is
            // nothing stored — not merely because it failed to answer.
            try? KeychainStore.saveString("{}", service: envService)
            return
        }
        var migrated: [String: String] = [:]
        for line in raw.split(separator: "\n") {
            var l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("#") || l.isEmpty { continue }
            if l.hasPrefix("export ") { l = String(l.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let eq = l.firstIndex(of: "=") else { continue }
            let key = String(l[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(l[l.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\""))
                || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            guard !key.isEmpty, !value.isEmpty,
                  migratablePrefixes.contains(where: { key.hasPrefix($0) })
            else { continue }
            migrated[key] = value
        }
        guard let json = try? JSONEncoder().encode(migrated) else { return }
        try? KeychainStore.saveString(String(decoding: json, as: UTF8.self), service: envService)
    }

    private static func legacyEnvPath() -> String? {
        if let override = ProcessInfo.processInfo.environment["LAGOON_LEGACY_ENV"] {
            return override
        }
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.lagoon.email.server.plist")
        guard let data = try? Data(contentsOf: plist),
              let plistDict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let workDir = plistDict["WorkingDirectory"] as? String
        else { return nil }
        return workDir + "/.env"
    }
}

enum EmbeddedServerError: LocalizedError {
    case keyGenerationFailed
    case startFailed
    case appSupportUnavailable

    /// Non-View code path, so the strings come through `L10n.current` — the
    /// convention every other non-View error in the client uses. These two
    /// used to be hardcoded Chinese, which surfaced on the boot-failure
    /// screen of an English install.
    var errorDescription: String? {
        switch self {
        case .keyGenerationFailed: return L10n.current.keyGenerationFailed
        case .startFailed: return L10n.current.embeddedServerStartFailed
        case .appSupportUnavailable: return L10n.current.appSupportUnavailable
        }
    }
}

/// The running embedded server, held at the process level.
///
/// The handle *is* the server's lifetime: `RunningLagoonServer` owns the
/// `ServiceGroup` the HTTP service runs inside, so the moment the last
/// reference to the handle goes away the group is released and the service
/// stops serving. That is why this is a holder and not a local variable.
///
/// Process-wide rather than a property of the boot object, because the
/// server has to keep serving while windows open and close — the boot state
/// is a `@StateObject` on the `App`, and the app outlives any one window.
@MainActor
final class EmbeddedServerHandle {
    /// The one holder for the process.
    static let shared = EmbeddedServerHandle()

    /// The live server, if one is running.
    private(set) var server: RunningLagoonServer?

    /// Takes ownership of a freshly started server.
    ///
    /// Any previous server is stopped first: two servers cannot share a
    /// port, and a server nobody holds is a server whose port nothing can
    /// give back.
    func adopt(_ server: RunningLagoonServer) async {
        await stop()
        self.server = server
    }

    /// Stops the server and lets go of it.
    ///
    /// The release point for the handle. Until this runs the server is alive
    /// for the process, which is the intent — the app *is* the server.
    func stop() async {
        guard let server else { return }
        // Released before the stop: the handle must not be the thing that
        // keeps a server we are trying to shut down.
        self.server = nil
        await server.stop()
    }
}

/// SwiftUI-facing boot state: gates the UI on the embedded server being up
/// so no view fires a request into a socket that isn't listening yet.
@MainActor
final class EmbeddedServerBoot: ObservableObject {
    enum Phase {
        case starting
        case ready
        case failed(String)
    }

    @Published private(set) var phase: Phase = .starting

    /// The process-level handle to the running server.
    ///
    /// The server has to outlive this object, which is why the handle is a
    /// shared holder; but this object still *owns* it — it starts the server,
    /// and `stop()` is what lets it go.
    private let handle = EmbeddedServerHandle.shared

    func run() async {
        do {
            // A previous attempt may still be holding the port.
            // `bootstrap()` walks the candidate ports, so a stale server
            // would push the new one onto a different port — and leave the
            // old one running with nobody holding it.
            await handle.stop()
            _ = try await EmbeddedServer.bootstrap()
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func retry() {
        phase = .starting
        Task { await run() }
    }

    /// Stops the embedded server and lets go of the handle.
    ///
    /// Nothing calls this on a normal quit — the process dies with the
    /// server — but it is the one place that knows how to hand the port
    /// back, so a restart has a release path that is not "leak and hope".
    func stop() async {
        await handle.stop()
    }
}
