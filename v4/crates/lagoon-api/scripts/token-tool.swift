// The other implementation, on purpose: CryptoKit's AES.GCM is what v3's
// AccessTokenCipher.seal/open call. Kept to two functions so there is no room
// for this file to drift into "a second cipher".
//
//   swiftc -O scripts/token-tool.swift -o /tmp/token-tool
//   /tmp/token-tool seal <base64-key> <plaintext>    -> base64(combined)
//   /tmp/token-tool open <base64-key> <base64-blob>  -> plaintext
import CryptoKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 4 else {
    fputs("usage: token-tool seal|open <base64-key> <value>\n", stderr)
    exit(2)
}
guard let keyData = Data(base64Encoded: arguments[2]), keyData.count == 32 else {
    fputs("key must be base64 of 32 bytes\n", stderr)
    exit(2)
}
let key = SymmetricKey(data: keyData)
switch arguments[1] {
case "seal":
    let sealed = try AES.GCM.seal(Data(arguments[3].utf8), using: key)
    print(sealed.combined!.base64EncodedString())
case "open":
    guard let blob = Data(base64Encoded: arguments[3]) else { exit(2) }
    let box = try AES.GCM.SealedBox(combined: blob)
    print(String(decoding: try AES.GCM.open(box, using: key), as: UTF8.self))
default:
    fputs("unknown mode\n", stderr)
    exit(2)
}
