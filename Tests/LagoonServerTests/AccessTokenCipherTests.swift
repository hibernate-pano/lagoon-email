import XCTest
import Foundation
import Darwin
@testable import LagoonServer

/// Process-global `LAGOON_TOKEN_KEY` fixture.
///
/// `AccessTokenCipher` reads the key from the process environment on every
/// call, so tests set their own key and restore the previous value afterwards
/// (including restoring "unset"). Tests run serially in one process, so this is
/// safe as long as every use goes through `withKey` / `withKeyAsync`.
enum TokenKeyFixture {
    static func freshKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max) }
        return Data(bytes).base64EncodedString()
    }

    static func current() -> String? {
        guard let c = getenv("LAGOON_TOKEN_KEY") else { return nil }
        return String(cString: c)
    }

    static func apply(_ key: String?) {
        if let key {
            setenv("LAGOON_TOKEN_KEY", key, 1)
        } else {
            unsetenv("LAGOON_TOKEN_KEY")
        }
    }

    static func withKey<T>(_ key: String?, _ body: () throws -> T) rethrows -> T {
        let previous = current()
        apply(key)
        defer { apply(previous) }
        return try body()
    }

    static func withKeyAsync<T>(_ key: String?, _ body: () async throws -> T) async throws -> T {
        let previous = current()
        apply(key)
        defer { apply(previous) }
        return try await body()
    }
}

final class AccessTokenCipherTests: XCTestCase {
    func test_sealOpenRoundTrip() throws {
        try TokenKeyFixture.withKey(TokenKeyFixture.freshKey()) {
            let plaintext = "ya29.secret-token-\(UUID().uuidString)"
            let blob = try AccessTokenCipher.seal(plaintext)
            XCTAssertEqual(try AccessTokenCipher.open(blob), plaintext)
        }
    }

    func test_sealedBlobDoesNotContainPlaintext() throws {
        try TokenKeyFixture.withKey(TokenKeyFixture.freshKey()) {
            let plaintext = "PLAINTEXT-MARKER-\(UUID().uuidString)"
            let blob = try AccessTokenCipher.seal(plaintext)
            XCTAssertNotEqual(blob, Data(plaintext.utf8))
            XCTAssertNil(blob.range(of: Data(plaintext.utf8)))
        }
    }

    func test_twoSealsOfSamePlaintextDiffer() throws {
        try TokenKeyFixture.withKey(TokenKeyFixture.freshKey()) {
            let plaintext = "same-plaintext"
            XCTAssertNotEqual(
                try AccessTokenCipher.seal(plaintext),
                try AccessTokenCipher.seal(plaintext)
            )
        }
    }

    func test_openThrowsAfterTamper() throws {
        try TokenKeyFixture.withKey(TokenKeyFixture.freshKey()) {
            var blob = try AccessTokenCipher.seal("tamper-me")
            XCTAssertGreaterThan(blob.count, 0)
            blob[blob.count - 1] ^= 0x01
            XCTAssertThrowsError(try AccessTokenCipher.open(blob))
        }
    }

    func test_openWithDifferentKeyFails() throws {
        let blob = try TokenKeyFixture.withKey(TokenKeyFixture.freshKey()) {
            try AccessTokenCipher.seal("different-key")
        }
        try TokenKeyFixture.withKey(TokenKeyFixture.freshKey()) {
            XCTAssertThrowsError(try AccessTokenCipher.open(blob))
        }
    }

    func test_missingKeyThrowsMissingKey() throws {
        try TokenKeyFixture.withKey(nil) {
            XCTAssertThrowsError(try AccessTokenCipher.seal("x")) { error in
                guard case TokenCipherError.missingKey = error else {
                    return XCTFail("expected missingKey, got \(error)")
                }
            }
        }
    }

    func test_badKey16BytesThrowsBadKey() throws {
        let short = Data(repeating: 0, count: 16).base64EncodedString()
        try TokenKeyFixture.withKey(short) {
            XCTAssertThrowsError(try AccessTokenCipher.seal("x")) { error in
                guard case TokenCipherError.badKey = error else {
                    return XCTFail("expected badKey, got \(error)")
                }
            }
        }
    }

    func test_nonBase64KeyThrowsBadKey() throws {
        try TokenKeyFixture.withKey("this-is-not-base64") {
            XCTAssertThrowsError(try AccessTokenCipher.open(Data([0, 1, 2]))) { error in
                guard case TokenCipherError.badKey = error else {
                    return XCTFail("expected badKey, got \(error)")
                }
            }
        }
    }

    func test_validateKey_badAndGood() throws {
        try TokenKeyFixture.withKey(nil) {
            XCTAssertThrowsError(try AccessTokenCipher.validateKey())
        }
        try TokenKeyFixture.withKey(Data(repeating: 0, count: 16).base64EncodedString()) {
            XCTAssertThrowsError(try AccessTokenCipher.validateKey())
        }
        try TokenKeyFixture.withKey("not base64!!") {
            XCTAssertThrowsError(try AccessTokenCipher.validateKey())
        }
        try TokenKeyFixture.withKey(TokenKeyFixture.freshKey()) {
            XCTAssertNoThrow(try AccessTokenCipher.validateKey())
        }
    }
}
