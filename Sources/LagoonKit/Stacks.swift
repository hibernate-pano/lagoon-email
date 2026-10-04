import Foundation

// 聚合 / 批量动作 / 规则推荐的共享 wire 类型。Server 与 client 各自编码解码
// 同一份定义 —— 合同漂移会在编译期暴露，而不是在真机上静默失败。

/// A stack rule plus how many live messages it currently matches.
public struct StackSummary: Codable, Sendable, Equatable, Identifiable {
    public let rule: StackRule
    public let count: Int
    public var id: UUID { rule.id }

    public init(rule: StackRule, count: Int) {
        self.rule = rule
        self.count = count
    }
}

public struct StackRuleListResponse: Codable, Sendable, Equatable {
    public let stacks: [StackSummary]
    public init(stacks: [StackSummary]) { self.stacks = stacks }
}

public struct StackCreateRequest: Codable, Sendable, Equatable {
    public let name: String
    public let kind: StackRule.Kind
    public let value: String
    public init(name: String, kind: StackRule.Kind, value: String) {
        self.name = name
        self.kind = kind
        self.value = value
    }
}

public struct StackCreateResponse: Codable, Sendable, Equatable {
    public let stack: StackSummary
    public init(stack: StackSummary) { self.stack = stack }
}

public struct StackDeleteResponse: Codable, Sendable, Equatable {
    public let ok: Bool
    public init(ok: Bool) { self.ok = ok }
}

/// 清扫（Sweep）: archive every listed remote id, remote-first, one audit row
/// each so every single undo stays independent.
public struct ArchiveBulkRequest: Codable, Sendable, Equatable {
    public let remoteIds: [String]
    public init(remoteIds: [String]) { self.remoteIds = remoteIds }
}

public struct ArchiveBulkItem: Codable, Sendable, Equatable {
    public let remoteId: String
    public let ok: Bool
    public let actionId: Int64?
    public let errorCode: String?
    public init(remoteId: String, ok: Bool, actionId: Int64? = nil, errorCode: String? = nil) {
        self.remoteId = remoteId
        self.ok = ok
        self.actionId = actionId
        self.errorCode = errorCode
    }
}

public struct ArchiveBulkResponse: Codable, Sendable, Equatable {
    public let items: [ArchiveBulkItem]
    /// Ids the request asked for beyond the server's per-call cap, which were
    /// silently dropped before this field existed.
    ///
    /// The server caps one call at 500 ids and used to just `prefix(500)` the
    /// request. A caller archiving 800 messages got 500 successes and no
    /// indication the other 300 were never attempted — the same "looks
    /// complete while part is missing" failure the briefing window was fixed
    /// for. Non-nil only when truncation actually happened; callers must
    /// either page through the remainder or tell the user.
    public let truncatedCount: Int?
    public init(items: [ArchiveBulkItem], truncatedCount: Int? = nil) {
        self.items = items
        self.truncatedCount = truncatedCount
    }
}
