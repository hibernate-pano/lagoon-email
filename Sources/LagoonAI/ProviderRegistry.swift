import Foundation

/// One entry in `config/providers.json`. Secrets never live here — only the
/// name of the env var that holds the key (spec §6.5).
public struct ProviderConfig: Codable, Sendable, Equatable {
    public let name: String
    public let baseURL: String
    public let apiKeyEnv: String
    public let model: String
    public let priority: Int
    public let capabilities: [String]
    /// Override for providers whose chat endpoint is not `{baseURL}/chat/completions`.
    public let chatPath: String?
    public let costPer1kPromptUsd: Double?
    public let costPer1kCompletionUsd: Double?

    public init(
        name: String,
        baseURL: String,
        apiKeyEnv: String,
        model: String,
        priority: Int,
        capabilities: [String],
        chatPath: String? = nil,
        costPer1kPromptUsd: Double? = nil,
        costPer1kCompletionUsd: Double? = nil
    ) {
        self.name = name
        self.baseURL = baseURL
        self.apiKeyEnv = apiKeyEnv
        self.model = model
        self.priority = priority
        self.capabilities = capabilities
        self.chatPath = chatPath
        self.costPer1kPromptUsd = costPer1kPromptUsd
        self.costPer1kCompletionUsd = costPer1kCompletionUsd
    }
}

public struct ProviderRegistryFile: Codable, Sendable {
    public let version: Int
    public let providers: [ProviderConfig]
    public let routing: [String: String]

    public init(version: Int, providers: [ProviderConfig], routing: [String: String]) {
        self.version = version
        self.providers = providers
        self.routing = routing
    }
}

/// A provider config with its secret resolved from the environment.
public struct ResolvedProvider: Sendable {
    public let config: ProviderConfig
    public let apiKey: String
    public let baseURL: URL

    public var name: String { config.name }
    public var model: String { config.model }
}

public enum ProviderRegistryError: Error, CustomStringConvertible {
    case missingConfig(String)
    case malformedConfig(String)

    public var description: String {
        switch self {
        case .missingConfig(let path): "provider config not found: \(path)"
        case .malformedConfig(let detail): "provider config malformed: \(detail)"
        }
    }
}

/// Loads `config/providers.json` and applies env overrides.
///
/// Env precedence (highest first) for the PRIMARY provider:
/// `LLM_PROVIDER_PRIMARY_BASE_URL` / `_MODEL` / `_API_KEY` override the file's
/// `baseURL` / `model` / `apiKeyEnv` lookup. Everything else comes from the file.
public enum ProviderRegistry {
    public static let defaultConfigPath = "config/providers.json"

    public static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileURL: URL? = nil
    ) throws -> [ResolvedProvider] {
        let url = try resolveConfigURL(environment: environment, fileURL: fileURL)
        guard let data = try? Data(contentsOf: url) else {
            throw ProviderRegistryError.missingConfig(url.path)
        }
        let file: ProviderRegistryFile
        do {
            file = try JSONDecoder().decode(ProviderRegistryFile.self, from: data)
        } catch {
            throw ProviderRegistryError.malformedConfig("\(error)")
        }

        // The primary provider is whichever the `summary` capability routes to,
        // else the lowest priority number.
        let primaryName = file.routing["summary"]
            ?? file.providers.min(by: { $0.priority < $1.priority })?.name

        var resolved: [ResolvedProvider] = []
        for config in file.providers.sorted(by: { $0.priority < $1.priority }) {
            var baseURL = config.baseURL
            var model = config.model
            var apiKey = environment[config.apiKeyEnv] ?? ""
            if config.name == primaryName {
                if let override = environment["LLM_PROVIDER_PRIMARY_BASE_URL"], !override.isEmpty {
                    baseURL = override
                }
                if let override = environment["LLM_PROVIDER_PRIMARY_MODEL"], !override.isEmpty {
                    model = override
                }
                if let override = environment["LLM_PROVIDER_PRIMARY_API_KEY"], !override.isEmpty {
                    apiKey = override
                }
            }
            guard !apiKey.isEmpty else { continue }
            guard let url = URL(string: baseURL), let scheme = url.scheme?.lowercased(),
                  scheme == "https", url.host != nil
            else {
                throw LLMError.invalidBaseURL(baseURL)
            }
            let trimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
            guard let normalized = URL(string: trimmed) else {
                throw LLMError.invalidBaseURL(baseURL)
            }
            resolved.append(ResolvedProvider(
                config: ProviderConfig(
                    name: config.name,
                    baseURL: trimmed,
                    apiKeyEnv: config.apiKeyEnv,
                    model: model,
                    priority: config.priority,
                    capabilities: config.capabilities,
                    chatPath: config.chatPath,
                    costPer1kPromptUsd: config.costPer1kPromptUsd,
                    costPer1kCompletionUsd: config.costPer1kCompletionUsd
                ),
                apiKey: apiKey,
                baseURL: normalized
            ))
        }
        return resolved
    }

    private static func resolveConfigURL(
        environment: [String: String],
        fileURL: URL?
    ) throws -> URL {
        if let fileURL { return fileURL }
        if let override = environment["LAGOON_PROVIDER_CONFIG"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: defaultConfigPath)
    }
}
