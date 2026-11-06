//
//  ContextBudget.swift
//  ChatContext
//

import Foundation
import Chat

/// How many tokens one request may use.
///
/// The window is the model's published `contextWindowTokens` (or the
/// policy's fallback). `ChatConversationSettings.contextWindowPercent` limits
/// requests to that share of the window, and the reply's reserve comes out of
/// what is left.
public struct ContextBudget: Equatable, Sendable {
    public var contextWindowTokens: Int
    /// False when the model does not publish its window and the fallback is used.
    public var isContextWindowKnown: Bool
    /// The share of the window requests may use, 1...100.
    public var windowPercent: Int
    public var reservedResponseTokens: Int

    public init(
        contextWindowTokens: Int,
        isContextWindowKnown: Bool = true,
        windowPercent: Int = 100,
        reservedResponseTokens: Int = 0
    ) {
        self.contextWindowTokens = max(0, contextWindowTokens)
        self.isContextWindowKnown = isContextWindowKnown
        self.windowPercent = Self.clamped(percent: windowPercent)
        self.reservedResponseTokens = max(0, reservedResponseTokens)
    }

    public init(model: Model, settings: ChatConversationSettings, policy: CompactionPolicy) {
        let policy = policy.normalized
        let published = model.generationCapabilities.contextWindowTokens.flatMap { $0 > 0 ? $0 : nil }
        let window = published ?? policy.fallbackContextWindowTokens
        self.init(
            contextWindowTokens: window,
            isContextWindowKnown: published != nil,
            windowPercent: settings.contextWindowPercent ?? 100,
            reservedResponseTokens: min(policy.reservedResponseTokens, window / 4)
        )
    }

    /// Tokens the system prompt and history may use together.
    public var inputTokenLimit: Int {
        max(0, contextWindowTokens * windowPercent / 100 - reservedResponseTokens)
    }

    /// `percent` of `inputTokenLimit`.
    public func tokens(atPercent percent: Int) -> Int {
        inputTokenLimit * Self.clamped(percent: percent) / 100
    }

    static func clamped(percent: Int) -> Int {
        min(100, max(1, percent))
    }
}
