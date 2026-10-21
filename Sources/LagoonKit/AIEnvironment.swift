import Foundation

/// The environment keys that configure the AI.
///
/// ## Why these names live in `LagoonKit`
///
/// Three modules have to agree on them, and they used to agree only by
/// coincidence:
///
/// * the **client** writes them into the Keychain (`lagoon.envJSON`) and
///   sends them to the reload route;
/// * the **server** route turns them back into a live `AIGateway`;
/// * the **AI module** reads them out of the environment to override the
///   provider config file.
///
/// A typo in one of them would not fail loudly. The client would write
/// `LLM_PROVIDER_PRIMARY_APIKEY`, the server would build a gateway that
/// finds no key, and the product would report "AI 未配置" while the user
/// stared at a correctly pasted key. One list, three readers.
///
/// ## Why the list is a *closed* set
///
/// `managed` is the set of keys the client owns outright: for exactly
/// these, **absence is an answer**. The user blanked the API key field
/// to turn the AI off, and the server must clear it — not keep the old
/// one because it happened to still be in the process environment.
///
/// Everything outside `managed` is passed through untouched: the
/// providers.json path, the output language, whatever a future feature
/// adds.
public enum AIEnvironmentKeys {
    /// The provider API key. Absent = the AI is off.
    public static let apiKey = "LLM_PROVIDER_PRIMARY_API_KEY"
    /// The provider base URL.
    public static let baseURL = "LLM_PROVIDER_PRIMARY_BASE_URL"
    /// The model name.
    public static let model = "LLM_PROVIDER_PRIMARY_MODEL"
    /// The monthly cost cap, in US dollars.
    public static let budget = "LAGOON_BUDGET_USD_PER_MONTH"

    /// The keys the client's map owns outright.
    public static let managed: [String] = [apiKey, baseURL, model, budget]
}
