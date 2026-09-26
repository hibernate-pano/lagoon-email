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
    public init(items: [ArchiveBulkItem]) { self.items = items }
}

/// 发件人归档历史驱动的白名单推荐：近 30 天归档次数多、且还没有
/// auto-archive 规则的发件人。创建动作走既有的 auto-archive 规则路由。
public struct AutoArchiveSuggestion: Codable, Sendable, Equatable, Identifiable {
    public let sender: String
    public let fromName: String?
    public let archiveCount: Int
    public var id: String { sender }
    public init(sender: String, fromName: String?, archiveCount: Int) {
        self.sender = sender
        self.fromName = fromName
        self.archiveCount = archiveCount
    }
}

public struct AutoArchiveSuggestionsResponse: Codable, Sendable, Equatable {
    public let suggestions: [AutoArchiveSuggestion]
    public init(suggestions: [AutoArchiveSuggestion]) { self.suggestions = suggestions }
}
