// Swift side of the AES-256-GCM interop probe.
// Mirrors Sources/LagoonKit/BodyCipher.swift:71-95 (seal/open) exactly:
//   envelope = "lgb1:" + base64( AES.GCM.SealedBox.combined )
//
// usage:
//   swift interop.swift layout
//   swift interop.swift seal <key-b64> <plaintext>
//   swift interop.swift open <key-b64> <envelope>
//
// Never prints a real Keychain key: the key here is a fixed test vector.

import Foundation
import CryptoKit

let prefix = "lgb1:"

func key(_ b64: String) throws -> SymmetricKey {
    guard let data = Data(base64Encoded: b64), data.count == 32 else {
        throw NSError(domain: "key", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "key must be 32 bytes base64"])
    }
    return SymmetricKey(data: data)
}

/// Same three lines as BodyCipher.seal (BodyCipher.swift:71-76).
func seal(_ plaintext: String, using k: SymmetricKey) throws -> String {
    let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: k)
    guard let combined = sealed.combined else {
        throw NSError(domain: "seal", code: 1)
    }
    return prefix + combined.base64EncodedString()
}

/// Same as BodyCipher.open (BodyCipher.swift:84-95).
func open(_ envelope: String, using k: SymmetricKey) throws -> String {
    guard envelope.hasPrefix(prefix) else {
        throw NSError(domain: "open", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "not an lgb1: envelope"])
    }
    let encoded = String(envelope.dropFirst(prefix.count))
    guard let data = Data(base64Encoded: encoded) else {
        throw NSError(domain: "open", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "bad base64"])
    }
    let box = try AES.GCM.SealedBox(combined: data)
    let plaintext = try AES.GCM.open(box, using: k)
    guard let text = String(data: plaintext, encoding: .utf8) else {
        throw NSError(domain: "open", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "not utf8"])
    }
    return text
}

func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

/// Proves the combined layout by measurement, not by assumption.
func layout() throws {
    let k = SymmetricKey(size: .bits256)
    let plaintext = "layout-probe"  // 12 bytes of plaintext
    let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: k)
    let nonce = sealed.nonce.withUnsafeBytes { Data($0) }
    let tag = sealed.tag
    let ct = sealed.ciphertext
    let combined = sealed.combined!
    print("plaintext_len=\(plaintext.utf8.count)")
    print("nonce_len=\(nonce.count) nonce_hex=\(hex(nonce))")
    print("ciphertext_len=\(ct.count) ciphertext_hex=\(hex(ct))")
    print("tag_len=\(tag.count) tag_hex=\(hex(tag))")
    print("combined_len=\(combined.count) combined_hex=\(hex(combined))")
    print("ASSERT combined == nonce||ciphertext||tag : \(combined == nonce + ct + tag)")
    print("ASSERT combined[0..<12] == nonce          : \(Data(combined.prefix(12)) == nonce)")
    print("ASSERT combined[12..<24] == ciphertext    : \(Data(combined.dropFirst(12).prefix(ct.count)) == ct)")
    print("ASSERT combined.suffix(16) == tag         : \(Data(combined.suffix(16)) == tag)")
    // and the reverse: a hand-assembled buffer is accepted by SealedBox(combined:)
    let rebuilt = nonce + ct + tag
    print("ASSERT SealedBox(combined: nonce||ct||tag) parses: \((try? AES.GCM.SealedBox(combined: rebuilt)) != nil)")
}

let args = Array(CommandLine.arguments.dropFirst())
do {
    switch args.first {
    case "layout" where args.count == 1:
        try layout()
    case "seal" where args.count == 3:
        let k = try key(args[1])
        print("ENVELOPE=\(try seal(args[2], using: k))")
    case "open" where args.count == 3:
        let k = try key(args[1])
        print("PLAINTEXT=\(try open(args[2], using: k))")
    default:
        FileHandle.standardError.write(Data("usage: interop.swift layout|seal|open ...\n".utf8))
        exit(2)
    }
} catch {
    print("SWIFT_ERROR=\(error)")
    exit(1)
}
