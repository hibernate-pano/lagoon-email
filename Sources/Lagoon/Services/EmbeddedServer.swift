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
    static let envService = "lagoon.envJSON"

    /// Keys that may be carried over from the legacy `.env`/launchd setup.
    private static let migratablePrefixes = ["LLM_PROVIDER_", "LAGOON_"]

    /// Starts the embedded server and returns the port it bound.
    static func bootstrap() async throws -> Int {
        try migrateLegacyEnvIfNeeded()

        // AES key for credentials blobs: Keychain-held, generated once.
        var tokenKey = try KeychainStore.loadString(service: tokenKeyService)
        if tokenKey == nil {
            var bytes = [UInt8](repeating: 0, count: 32)
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            guard status == errSecSuccess else {
                throw EmbeddedServerError.keyGenerationFailed
            }
            tokenKey = Data(bytes).base64EncodedString()
            try KeychainStore.saveString(tokenKey!, service: tokenKeyService)
        }

        // API token: a dev-set env var wins (so `swift run` against the app's
        // server keeps working), otherwise Keychain, otherwise generate.
        let env = ProcessInfo.processInfo.environment
        var apiToken = env["LAGOON_API_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if apiToken?.isEmpty == true { apiToken = nil }
        if apiToken == nil {
            let stored = try KeychainStore.loadString(service: "lagoon.apiTokenSecret")
            apiToken = stored ?? UUID().uuidString
            if stored == nil {
                try KeychainStore.saveString(apiToken!, service: "lagoon.apiTokenSecret")
            }
            // The APIClient reads this when the env var is absent.
            UserDefaults.standard.set(apiToken, forKey: "lagoon.apiToken")
        }

        // Environment for the runtime: Keychain (migrated) first, process env
        // wins on conflict so dev overrides keep working.
        var runtimeEnv = try KeychainStore.loadString(service: envService)
            .flatMap { try? JSONDecoder().decode([String: String].self, from: Data($0.utf8)) } ?? [:]
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

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = support.appendingPathComponent("Lagoon", isDirectory: true)
        let dbPath = appDir.appendingPathComponent("lagoon.sqlite").path

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
                tokenKeyBase64: tokenKey!,
                environment: runtimeEnv
            )
            do {
                let server = try await LagoonRuntime.start(configuration, logger: .init(label: "lagoon.embedded"))
                UserDefaults.standard.set(port, forKey: "lagoon.serverPort")
                Task { _ = server }  // keep the handle alive for the process lifetime
                return port
            } catch {
                lastError = error
            }
        }
        throw lastError ?? EmbeddedServerError.startFailed
    }

    // MARK: - Legacy .env migration (launchd → Keychain)

    /// One-time import of the launchd agent's `.env` so the AI keys and the
    /// budget cap survive the switch without the user re-entering them. The launchd plist names the repo working
    /// directory the old agent sourced `.env` from.
    static func migrateLegacyEnvIfNeeded() throws {
        guard try KeychainStore.loadString(service: envService) == nil else { return }
        let envPath = legacyEnvPath()
        guard let envPath, let raw = try? String(contentsOfFile: envPath, encoding: .utf8) else {
            // Nothing to migrate; store an empty map so we never retry.
            try KeychainStore.saveString("{}", service: envService)
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
        let json = String(decoding: try JSONEncoder().encode(migrated), as: UTF8.self)
        try KeychainStore.saveString(json, service: envService)
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

    var errorDescription: String? {
        switch self {
        case .keyGenerationFailed: return "无法生成加密密钥（Keychain 写入失败）"
        case .startFailed: return "内嵌服务启动失败"
        }
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

    func run() async {
        do {
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
}
