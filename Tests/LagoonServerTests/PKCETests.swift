import XCTest
import CryptoKit
@testable import LagoonServer

final class PKCETests: XCTestCase {
    func test_verifier_is_43_to_128_chars() {
        let p = PKCE.generate()
        XCTAssertGreaterThanOrEqual(p.verifier.count, 43)
        XCTAssertLessThanOrEqual(p.verifier.count, 128)
        XCTAssertFalse(p.challenge.isEmpty)
        XCTAssertEqual(p.method, "S256")
    }

    func test_challenge_is_base64url_no_padding() {
        let p = PKCE.generate()
        XCTAssertFalse(p.challenge.contains("="))
        XCTAssertFalse(p.challenge.contains("+"))
        XCTAssertFalse(p.challenge.contains("/"))
    }

    func test_two_generations_differ() {
        let a = PKCE.generate()
        let b = PKCE.generate()
        XCTAssertNotEqual(a.verifier, b.verifier)
    }

    /// Independently recompute base64url(SHA256(verifier)) and compare.
    func test_challenge_matchesS256OfVerifier() {
        for _ in 0..<10 {
            let p = PKCE.generate()
            let digest = SHA256.hash(data: Data(p.verifier.utf8))
            let expected = Data(digest)
                .base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            XCTAssertEqual(p.challenge, expected)
        }
    }

    /// RFC 7636 verifier charset: unreserved characters only.
    func test_verifier_containsOnlyUnreservedCharacters() {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        for _ in 0..<20 {
            let p = PKCE.generate()
            XCTAssertTrue(
                p.verifier.unicodeScalars.allSatisfy { allowed.contains($0) },
                "verifier has non-unreserved characters: \(p.verifier)"
            )
        }
    }
}
