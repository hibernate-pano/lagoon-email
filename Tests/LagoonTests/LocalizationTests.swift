import XCTest
import Foundation
@testable import Lagoon
@testable import LagoonKit

/// Covers the runtime language switch: every localized string must exist in
/// both languages, and non-View code must follow the stored preference.
final class LocalizationTests: XCTestCase {
    private let zh = L10n(language: .zhHans)
    private let en = L10n(language: .english)

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: LanguagePreference.defaultsKey)
        super.tearDown()
    }

    func test_groupTitles_existInBothLanguagesAndDiffer() {
        for group in BriefingGroup.allCases {
            let chinese = zh.groupTitle(group)
            let english = en.groupTitle(group)
            XCTAssertFalse(chinese.isEmpty, "missing zh title for \(group.rawValue)")
            XCTAssertFalse(english.isEmpty, "missing en title for \(group.rawValue)")
            XCTAssertNotEqual(chinese, english, "untranslated title for \(group.rawValue)")
        }
    }

    func test_reasonText_coversEveryCodeInBothLanguages() {
        for reason in BriefingReason.allCases {
            let chinese = zh.reasonText(reason.rawValue)
            let english = en.reasonText(reason.rawValue)
            XCTAssertNotNil(chinese, "missing zh text for \(reason.rawValue)")
            XCTAssertNotNil(english, "missing en text for \(reason.rawValue)")
            XCTAssertNotEqual(chinese, english, "untranslated reason \(reason.rawValue)")
        }
    }

    /// A code from a newer server must not crash or leak into the UI.
    func test_reasonText_unknownCode_returnsNil() {
        XCTAssertNil(zh.reasonText("something-new"))
        XCTAssertNil(zh.reasonText(nil))
        XCTAssertNil(zh.reasonText(""))
    }

    /// Structured strings that carry arguments must interpolate in both.
    func test_interpolatedStrings_useTheArgument() {
        XCTAssertEqual(zh.expandGroup("需要回复"), "展开 需要回复")
        XCTAssertEqual(en.expandGroup("Needs reply"), "Expand Needs reply")
        XCTAssertEqual(zh.viaProvider("MiniMax-M3"), "由 MiniMax-M3 生成")
        XCTAssertEqual(en.viaProvider("MiniMax-M3"), "via MiniMax-M3")
        XCTAssertEqual(zh.recipient("a@b.com"), "收件人 a@b.com")
        XCTAssertEqual(en.httpStatus(502), "Server returned HTTP 502: ")
        XCTAssertEqual(zh.httpStatus(502), "服务器返回 HTTP 502：")
    }

    func test_languagePreference_roundTripsThroughUserDefaults() {
        UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: LanguagePreference.defaultsKey)
        XCTAssertEqual(LanguagePreference.stored, .english)
        XCTAssertEqual(L10n.current.retry, "Retry")

        UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: LanguagePreference.defaultsKey)
        XCTAssertEqual(LanguagePreference.stored, .zhHans)
        XCTAssertEqual(L10n.current.retry, "重试")
    }

    func test_languagePreference_defaultsToChineseWhenUnset() {
        UserDefaults.standard.removeObject(forKey: LanguagePreference.defaultsKey)
        XCTAssertEqual(LanguagePreference.stored, .zhHans)
    }

    /// Errors thrown by non-View code follow the stored preference.
    func test_apiErrorMessages_followStoredLanguage() {
        UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: LanguagePreference.defaultsKey)
        XCTAssertEqual(
            APIError.invalidResponse.localizedDescription,
            "The server returned a non-HTTP response."
        )
        UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: LanguagePreference.defaultsKey)
        XCTAssertEqual(APIError.invalidResponse.localizedDescription, "服务器返回了非 HTTP 响应。")
    }
}
