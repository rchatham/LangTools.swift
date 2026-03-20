//
//  ContextManager.swift
//  CLI
//
//  Manages conversation context window and summarization
//

import Foundation

/// Manages context window for conversations
final class ContextManager {
    /// Shared singleton instance
    static let shared = ContextManager()

    /// Maximum context tokens before compaction
    var maxContextTokens: Int = 100_000

    /// Target tokens after compaction
    var compactedContextTokens: Int = 50_000

    /// Estimated tokens per character (rough approximation)
    private let tokensPerCharacter: Double = 0.25

    private init() {}

    // MARK: - Token Estimation

    /// Estimate tokens for a string
    func estimateTokens(_ text: String) -> Int {
        return Int(Double(text.count) * tokensPerCharacter)
    }

    /// Estimate total tokens for messages
    func estimateTokens(for messages: [ChatMessage]) -> Int {
        messages.reduce(0) { total, message in
            total + estimateTokens(message.content) + 10 // +10 for message overhead
        }
    }

    /// Check if context needs compaction
    func needsCompaction(messages: [ChatMessage]) -> Bool {
        estimateTokens(for: messages) > maxContextTokens
    }

    // MARK: - Context Compaction

    /// Compact messages to fit within context window
    func compactMessages(_ messages: [ChatMessage]) -> [ChatMessage] {
        let currentTokens = estimateTokens(for: messages)

        guard currentTokens > maxContextTokens else {
            return messages
        }

        // Strategy: Keep recent messages, summarize older ones
        let targetTokens = compactedContextTokens
        var result: [ChatMessage] = []
        var usedTokens = 0

        // Always keep the most recent messages (last ~30%)
        let recentCount = max(5, messages.count / 3)
        let recentMessages = Array(messages.suffix(recentCount))
        let olderMessages = Array(messages.prefix(messages.count - recentCount))

        // Estimate tokens for recent messages
        let recentTokens = estimateTokens(for: recentMessages)

        // If recent alone is too much, just keep recent
        if recentTokens > targetTokens {
            return recentMessages
        }

        usedTokens = recentTokens

        // Add summary of older messages if there are any
        if !olderMessages.isEmpty {
            let summary = createSummary(of: olderMessages)
            let summaryMessage = ChatMessage(
                role: .system,
                content: "[Conversation Summary]\n\n\(summary)\n\n[End Summary - Recent messages follow]"
            )

            let summaryTokens = estimateTokens(summaryMessage.content)

            if usedTokens + summaryTokens <= targetTokens {
                result.append(summaryMessage)
                usedTokens += summaryTokens
            }
        }

        // Add recent messages
        result.append(contentsOf: recentMessages)

        return result
    }

    /// Create a summary of messages
    private func createSummary(of messages: [ChatMessage]) -> String {
        // Simple extractive summary - in production, this could use LLM
        var summary: [String] = []

        // Group by role and extract key points
        var userTopics: [String] = []
        var assistantActions: [String] = []
        var toolResults: [String] = []

        for message in messages {
            switch message.role {
            case .user:
                // Extract first sentence or up to 100 chars
                let content = String(message.content.prefix(100))
                if let firstSentence = content.components(separatedBy: [".", "?", "!"]).first {
                    userTopics.append(firstSentence.trimmingCharacters(in: .whitespaces))
                }

            case .assistant:
                // Extract first line
                if let firstLine = message.content.components(separatedBy: .newlines).first {
                    let truncated = String(firstLine.prefix(100))
                    assistantActions.append(truncated)
                }

            case .tool:
                // Note tool execution
                let truncated = String(message.content.prefix(50))
                toolResults.append("Tool: \(truncated)...")

            case .system:
                break // Skip system messages in summary
            }
        }

        if !userTopics.isEmpty {
            summary.append("User discussed: \(userTopics.prefix(5).joined(separator: "; "))")
        }

        if !assistantActions.isEmpty {
            summary.append("Assistant helped with: \(assistantActions.prefix(5).joined(separator: "; "))")
        }

        if !toolResults.isEmpty {
            summary.append("Tools used: \(toolResults.count) tool calls")
        }

        return summary.joined(separator: "\n")
    }

    // MARK: - Context Window Status

    /// Get current context usage
    func contextUsage(for messages: [ChatMessage]) -> ContextUsage {
        let currentTokens = estimateTokens(for: messages)
        let percentage = Double(currentTokens) / Double(maxContextTokens) * 100

        return ContextUsage(
            currentTokens: currentTokens,
            maxTokens: maxContextTokens,
            percentage: percentage,
            needsCompaction: percentage > 80
        )
    }
}

/// Context window usage information
struct ContextUsage {
    let currentTokens: Int
    let maxTokens: Int
    let percentage: Double
    let needsCompaction: Bool

    var formattedUsage: String {
        let percentStr = String(format: "%.1f", percentage)
        return "\(currentTokens)/\(maxTokens) tokens (\(percentStr)%)"
    }
}
