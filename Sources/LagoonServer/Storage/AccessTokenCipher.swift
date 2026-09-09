import Foundation
import PostgresNIO
import LagoonKit

/// M0: reads access_token blob and treats it as plaintext.
/// M1 replaces this with libsodium sealed-box decryption keyed from the
/// client keychain (spec §6.6 rule 5). The interface stays identical so
/// call sites do not move.
public enum AccessTokenCipher {
    public static func readToken(accountId: UUID, db: PostgresConnection) async throws -> String {
        let sql = "SELECT access_token FROM accounts WHERE id = $1"
        let result = try await db.query(sql, [PostgresData(uuid: accountId)]).get()
        guard let row = result.rows.first else { throw AccountStoreError.notFound }
        let bytes: Data = try row.makeRandomAccess()["access_token"].decode(Data.self)
        return String(data: bytes, encoding: .utf8) ?? ""
    }
}