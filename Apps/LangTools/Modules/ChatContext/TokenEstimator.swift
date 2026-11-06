//
//  TokenEstimator.swift
//  ChatContext
//

import Foundation
import Chat

/// Estimates how many tokens text and messages take up in a request.
///
/// This is a heuristic, not a tokenizer. It starts from the CLI's
/// `ContextManager` (about four characters per token plus a fixed overhead
/// per message) but counts UTF-8 bytes instead of characters and rounds up.
/// For English the two agree; for scripts that need more bytes per character
/// (CJK, emoji) it estimates more tokens, so errors lean toward compacting a
/// little early rather than overflowing the context window.
public struct TokenEstimator: Codable, Hashable, Sendable {
    public var bytesPerToken: Int
    /// Framing every provider adds around one message (role, separators).
    public var messageOverheadTokens: Int
    /// Framing around one replayed tool call and its result.
    public var toolCallOverheadTokens: Int

    public static let standard = TokenEstimator()

    public init(bytesPerToken: Int = 4, messageOverheadTokens: Int = 10, toolCallOverheadTokens: Int = 10) {
        self.bytesPerToken = max(1, bytesPerToken)
        self.messageOverheadTokens = max(0, messageOverheadTokens)
        self.toolCallOverheadTokens = max(0, toolCallOverheadTokens)
    }

    public func tokens(in text: String) -> Int {
        let bytes = text.utf8.count
        guard bytes > 0 else { return 0 }
        return (bytes + bytesPerToken - 1) / bytesPerToken
    }

    /// What replaying `message` costs: its provider-facing text plus every
    /// finished tool call's name, arguments and result, which providers
    /// replay as separate tool messages.
    public func tokens(in message: Message) -> Int {
        var total = messageOverheadTokens + tokens(in: message.providerContext ?? "")
        for call in message.toolCalls where call.status != .pending {
            total += toolCallOverheadTokens
                + tokens(in: call.name)
                + tokens(in: call.arguments ?? "")
                + tokens(in: message.providerToolResults[call.id] ?? call.result ?? "")
        }
        return total
    }

    public func tokens<Messages: Sequence>(in messages: Messages) -> Int where Messages.Element == Message {
        messages.reduce(0) { $0 + tokens(in: $1) }
    }
}
