import XCTest
@testable import Lagoon

/// V1 AI settings: Save must overlay only the 4 AI keys and never drop
/// unrelated entries (provider config path, future migrates) from envJSON.
final class AISettingsStoreTests: XCTestCase {
    func test_mergePreservesUnrelatedKeys() {
        let stored = [
            "LAGOON_PROVIDER_CONFIG": "/bundled/providers.json",
            "LAGOON_SOMETHING_ELSE": "keep-me",
            "LLM_PROVIDER_PRIMARY_API_KEY": "old-key",
        ]
        let out = AISettingsStore.merged(
            stored, apiKey: "new-key", baseURL: "", model: "", budgetUSD: ""
        )
        XCTAssertEqual(out["LAGOON_PROVIDER_CONFIG"], "/bundled/providers.json")
        XCTAssertEqual(out["LAGOON_SOMETHING_ELSE"], "keep-me")
        XCTAssertEqual(out["LLM_PROVIDER_PRIMARY_API_KEY"], "new-key")
    }

    func test_mergeAppliesDefaultsForEmptyBaseURLAndModel() {
        let out = AISettingsStore.merged([:], apiKey: "k", baseURL: "", model: "", budgetUSD: "")
        XCTAssertEqual(out["LLM_PROVIDER_PRIMARY_BASE_URL"], AISettingsStore.defaultBaseURL)
        XCTAssertEqual(out["LLM_PROVIDER_PRIMARY_MODEL"], AISettingsStore.defaultModel)
    }

    func test_mergeTrimsWhitespaceFromKey() {
        let out = AISettingsStore.merged([:], apiKey: "  k123\n", baseURL: "u", model: "m", budgetUSD: "")
        XCTAssertEqual(out["LLM_PROVIDER_PRIMARY_API_KEY"], "k123")
    }

    func test_emptyKeyClearsSoAICanBeDisabled() {
        let out = AISettingsStore.merged(
            ["LLM_PROVIDER_PRIMARY_API_KEY": "old"], apiKey: "  ", baseURL: "u", model: "m", budgetUSD: ""
        )
        XCTAssertNil(out["LLM_PROVIDER_PRIMARY_API_KEY"])
    }

    func test_emptyBudgetClearsTheCap() {
        let out = AISettingsStore.merged(
            ["LAGOON_BUDGET_USD_PER_MONTH": "10"], apiKey: "k", baseURL: "u", model: "m", budgetUSD: ""
        )
        XCTAssertNil(out["LAGOON_BUDGET_USD_PER_MONTH"])
    }

    func test_saveRejectsNonNumericBudget() {
        XCTAssertThrowsError(
            try AISettingsStore.save(apiKey: "k", baseURL: "", model: "", budgetUSD: "ten")
        )
    }

    func test_saveRejectsNonHttpsBaseURL() {
        XCTAssertThrowsError(
            try AISettingsStore.save(apiKey: "k", baseURL: "http://evil.invalid", model: "", budgetUSD: "")
        )
    }
}
