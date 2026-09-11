import Foundation
import Hummingbird
import NIOCore
import PostgresNIO
import LagoonKit

public enum AccountsRoutes {
    /// GET /api/accounts — the M0 OAuth handshake. The macOS client polls this
    /// while the connect screen is visible and matches on `id`.
    public static func register(on router: Router<BasicRequestContext>, db: PostgresConnection) {
        router.get("api/accounts") { _, _ -> Response in
            let accounts = try await AccountStore.all(db: db)
            let connected = accounts.map {
                ConnectedAccount(
                    id: $0.id,
                    provider: $0.provider,
                    email: $0.email,
                    isActive: $0.isActive,
                    syncHealth: $0.syncHealth,
                    capabilities: $0.capabilities
                )
            }
            let data = try JSONEncoder().encode(connected)
            return Response(
                status: .ok,
                headers: [.contentType: "application/json; charset=utf-8"],
                body: .init(byteBuffer: ByteBuffer(data: data))
            )
        }
    }
}
