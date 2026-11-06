//
//  CompactionPolicy.swift
//  ChatContext
//

import Foundation

/// When and how far a conversation's requests are compacted.
///
/// Compaction uses two thresholds so it happens rarely: once a request would
/// use more than `triggerPercent` of the input budget, older turns are folded
/// into a summary until the request fits in `targetPercent`. The summary is
/// then reused unchanged (a stable checkpoint) until the trigger is crossed
/// again, which keeps the request prefix identical between turns so provider
/// prompt caching stays effective.
///
/// Stored policies decode missing fields as their defaults, so fields can be
/// added later without a migration.
public struct CompactionPolicy: Codable, Hashable, Sendable {
    /// When false no new summaries are written. An existing summary is still
    /// applied, because the older messages it replaces may not be loaded.
    public var isEnabled: Bool
    /// Compact once a request would use more than this share of the input budget.
    public var triggerPercent: Int
    /// After compacting, the request aims to use at most this share.
    public var targetPercent: Int
    /// Recent turns kept word for word, besides the current prompt, as long
    /// as they fit the input budget.
    public var minimumRecentTurns: Int
    /// The longest summary to ask for.
    public var summaryTokenLimit: Int
    /// Room left for the model's reply. Capped at a quarter of the window.
    public var reservedResponseTokens: Int
    /// The window assumed for models that do not publish one.
    public var fallbackContextWindowTokens: Int
    /// The model that writes summaries (a `Model` raw value); `nil` uses the
    /// conversation's model.
    public var summaryModelIdentifier: String?

    public static let standard = CompactionPolicy()
    public static let disabled = CompactionPolicy(isEnabled: false)

    public init(
        isEnabled: Bool = true,
        triggerPercent: Int = 80,
        targetPercent: Int = 50,
        minimumRecentTurns: Int = 2,
        summaryTokenLimit: Int = 1_500,
        reservedResponseTokens: Int = 4_096,
        fallbackContextWindowTokens: Int = 32_000,
        summaryModelIdentifier: String? = nil
    ) {
        self.isEnabled = isEnabled
        self.triggerPercent = triggerPercent
        self.targetPercent = targetPercent
        self.minimumRecentTurns = minimumRecentTurns
        self.summaryTokenLimit = summaryTokenLimit
        self.reservedResponseTokens = reservedResponseTokens
        self.fallbackContextWindowTokens = fallbackContextWindowTokens
        self.summaryModelIdentifier = summaryModelIdentifier
    }

    /// The policy with every value clamped to a usable range, so a stored or
    /// hand-edited policy cannot disable the budget checks.
    public var normalized: CompactionPolicy {
        var policy = self
        policy.triggerPercent = min(100, max(10, triggerPercent))
        policy.targetPercent = min(policy.triggerPercent - 5, max(5, targetPercent))
        policy.minimumRecentTurns = max(0, minimumRecentTurns)
        policy.summaryTokenLimit = max(64, summaryTokenLimit)
        policy.reservedResponseTokens = max(0, reservedResponseTokens)
        policy.fallbackContextWindowTokens = max(1_024, fallbackContextWindowTokens)
        if policy.summaryModelIdentifier?.isEmpty == true { policy.summaryModelIdentifier = nil }
        return policy
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, triggerPercent, targetPercent, minimumRecentTurns, summaryTokenLimit
        case reservedResponseTokens, fallbackContextWindowTokens, summaryModelIdentifier
    }

    public init(from decoder: Decoder) throws {
        let defaults = CompactionPolicy()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
        triggerPercent = try container.decodeIfPresent(Int.self, forKey: .triggerPercent) ?? defaults.triggerPercent
        targetPercent = try container.decodeIfPresent(Int.self, forKey: .targetPercent) ?? defaults.targetPercent
        minimumRecentTurns = try container.decodeIfPresent(Int.self, forKey: .minimumRecentTurns) ?? defaults.minimumRecentTurns
        summaryTokenLimit = try container.decodeIfPresent(Int.self, forKey: .summaryTokenLimit) ?? defaults.summaryTokenLimit
        reservedResponseTokens = try container.decodeIfPresent(Int.self, forKey: .reservedResponseTokens) ?? defaults.reservedResponseTokens
        fallbackContextWindowTokens = try container.decodeIfPresent(Int.self, forKey: .fallbackContextWindowTokens)
            ?? defaults.fallbackContextWindowTokens
        summaryModelIdentifier = try container.decodeIfPresent(String.self, forKey: .summaryModelIdentifier)
    }
}
