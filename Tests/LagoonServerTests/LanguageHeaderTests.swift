import XCTest
@testable import LagoonServer

/// `Accept-Language` is how the client's UI language reaches the AI summary.
final class LanguageHeaderTests: XCTestCase {
    func test_preferredLanguage_takesFirstTag() {
        XCTAssertEqual(RouteParams.preferredLanguage(fromHeader: "zh-CN,zh;q=0.9"), "zh-CN")
        XCTAssertEqual(RouteParams.preferredLanguage(fromHeader: "en-US,en;q=0.9,zh;q=0.8"), "en-US")
        XCTAssertEqual(RouteParams.preferredLanguage(fromHeader: "en"), "en")
        XCTAssertEqual(RouteParams.preferredLanguage(fromHeader: " zh-Hans "), "zh-Hans")
    }

    func test_preferredLanguage_nilWhenAbsentOrBlank() {
        XCTAssertNil(RouteParams.preferredLanguage(fromHeader: nil))
        XCTAssertNil(RouteParams.preferredLanguage(fromHeader: ""))
        XCTAssertNil(RouteParams.preferredLanguage(fromHeader: "   "))
        XCTAssertNil(RouteParams.preferredLanguage(fromHeader: ";q=0.5"))
    }
}
