import Foundation
import LagoonKit

public struct ArchiveResponse: Codable, Sendable, Equatable {
    public let ok: Bool
    public let remoteId: String
    public let remote: Bool
    public let actionId: Int64
}

public struct UnsubscribeResponse: Codable, Sendable, Equatable {
    public let ok: Bool
    public let unsubscribed: Bool
    public let publisher: String
    public let actionId: Int64
}

/// R1 已发送列表的响应。
///
/// 形状与 `SyncResponse` 一致（`messages` + `totalCount`），这样客户端的列表
/// 视图无需为它新增一条解码路径——这是把它做成独立路由而不是
/// `?sent=true` 的另一个理由。
public struct SentResponse: Codable, Sendable, Equatable {
    public let messages: [MessageHeader]
    /// 服务端总数，不受 limit 影响。Optional 只是为了兼容旧载荷。
    public let totalCount: Int?
    /// 本次从服务器拉回多少行。诊断用，也让测试能证明刷新确实发生过。
    public let refreshedFromServer: Int
    /// 非 nil 表示服务器没拉到。列表仍然渲染，但会标注「可能不是最新」。
    public let staleReason: String?

    public init(
        messages: [MessageHeader],
        totalCount: Int? = nil,
        refreshedFromServer: Int = 0,
        staleReason: String? = nil
    ) {
        self.messages = messages
        self.totalCount = totalCount
        self.refreshedFromServer = refreshedFromServer
        self.staleReason = staleReason
    }

    /// 行数与总数在只有一个来源时才可信。
    public var effectiveTotal: Int { totalCount ?? messages.count }
}

/// 彻底删除 / 清空废纸篓 的响应。
///
/// **没有 `actionId`**，而且这是类型层面的缺失而非约定：彻底删除之后没有可撤销
/// 的动作，返回一个 id 只会诱导调用方挂上一个按了没用的 ⌘Z。
///
/// `purged` 是本地删除的行数——单封是 1，清空是 N，本来就是空的废纸篓是 0。
public struct PurgeResponse: Codable, Sendable, Equatable {
    public let ok: Bool
    public let remoteId: String
    public let purged: Int
}

public struct ChooseDraftResponse: Codable, Sendable, Equatable {
    public let ok: Bool
    public let draftId: Int64
    public let chosen: Int
}

public struct SendResponse: Codable, Sendable, Equatable {
    public let ok: Bool
    /// Server-side Message-ID reported by the SMTP send path.
    public let providerMessageId: String?
}
