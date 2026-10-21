import Foundation
import Logging
import LagoonKit

/// A gateway that can be swapped while the app is running.
///
/// ## Why this exists
///
/// The AI gateway was built once, at launch, from the environment the
/// server booted with. The user then went to 「AI 设置」, pasted a key,
/// pressed 保存 — and the app said "重启 App 后生效" (restart the app to
/// take effect).
///
/// That was a real cost with no real reason behind it. A key is a
/// credential; changing a credential does not require rebuilding the
/// process. What *did* require a restart was the architecture: the
/// routes captured the gateway instance in a `let` at registration time,
/// so there was no way to hand them a different one.
///
/// This holder is that way. The routes hold the holder, the holder holds
/// the current gateway, and saving a new key replaces the gateway behind
/// the same reference. The user pastes a key and it works — no quit, no
/// relaunch, no "did you restart?" question.
///
/// ## Why the holder implements the protocols itself
///
/// The holder *is* the thing the routes talk to. It forwards each call
/// to the current gateway, and when there is no gateway it throws the
/// same "not configured" error the unwrapped path used to throw. The
/// routes never learn that a swap is possible.
public final class AIGatewayHolder: BriefingClassifying, MessageSummarizing, MessageDrafting, @unchecked Sendable {
    /// The current gateway, or nil when no provider is configured.
    private let lock = NSLock()
    private var gateway: AIGateway?

    public init(gateway: AIGateway?) {
        self.gateway = gateway
    }

    /// Replaces the gateway.
    ///
    /// `nil` means "no provider configured" — which is a **different**
    /// state from "not yet loaded", and the routes must be able to tell
    /// the difference: a missing key should disable the AI features and
    /// say so, not throw an opaque error.
    public func replace(with gateway: AIGateway?) {
        lock.lock()
        defer { lock.unlock() }
        self.gateway = gateway
    }

    /// The current gateway, for the status routes.
    public var current: AIGateway? {
        lock.lock()
        defer { lock.unlock() }
        return gateway
    }

    /// Whether a provider is configured right now.
    public var isConfigured: Bool { current?.isConfigured ?? false }

    // MARK: - The protocols

    public func classify(
        _ messages: [MessageHeader],
        accountEmail: String,
        language: String?
    ) async throws -> [String: ClassificationOutcome] {
        guard let gateway = current else { throw LLMError.notConfigured }
        return try await gateway.classify(
            messages, accountEmail: accountEmail, language: language
        )
    }

    public func summarize(
        _ body: MessageBody,
        language: String?,
        accountEmail: String
    ) async throws -> MessageSummary {
        guard let gateway = current else { throw LLMError.notConfigured }
        return try await gateway.summarize(body, language: language, accountEmail: accountEmail)
    }

    public func draftReplies(
        _ body: MessageBody,
        language: String?,
        accountEmail: String,
        count: Int
    ) async throws -> [String] {
        guard let gateway = current else { throw LLMError.notConfigured }
        return try await gateway.draftReplies(
            body, language: language, accountEmail: accountEmail, count: count
        )
    }
}
