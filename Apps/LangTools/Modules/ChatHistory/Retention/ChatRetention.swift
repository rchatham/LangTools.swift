//
//  ChatRetention.swift
//  ChatHistory
//
//  Automatic deletion of inactive conversations. Off by default.
//

import Foundation

public enum ChatRetentionPolicy: Codable, Hashable, Sendable {
    case keepForever
    case deleteInactive(afterDays: Int)

    public static let `default` = ChatRetentionPolicy.keepForever
    /// The choices offered in settings.
    public static let presetDays = [30, 90, 180, 365]

    /// Conversations inactive since before this date expire; `nil` means
    /// nothing ever expires.
    public func cutoff(now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .keepForever:
            return nil
        case .deleteInactive(let days):
            guard days > 0 else { return nil }
            return calendar.date(byAdding: .day, value: -days, to: now)
        }
    }
}

/// Persists the retention policy in `UserDefaults`.
public struct ChatRetentionSettingsStore {
    public static let key = "chatHistory.retentionPolicy"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> ChatRetentionPolicy {
        guard let data = defaults.data(forKey: Self.key),
              let policy = try? JSONDecoder().decode(ChatRetentionPolicy.self, from: data) else {
            return .default
        }
        return policy
    }

    public func save(_ policy: ChatRetentionPolicy) {
        guard let data = try? JSONEncoder().encode(policy) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

public struct ChatRetentionReport: Equatable, Sendable {
    public var cutoff: Date?
    public var evaluatedCount: Int
    public var deletedIDs: Set<UUID>

    public static let none = ChatRetentionReport(cutoff: nil, evaluatedCount: 0, deletedIDs: [])
}

/// Deletes conversations that the retention policy says have expired.
///
/// Some conversations are never deleted, whatever the policy:
/// pinned ones, ones marked `isRetentionExempt` (hosts use this for
/// long-running threads such as a bot's main thread), and any in
/// `protecting` (typically conversations with a live session).
@MainActor
public struct ChatRetentionPruner {
    public let storage: any ChatHistoryStorage
    /// The expiry rule; injectable so the always-kept rules can be tested on
    /// their own.
    let isExpired: (ConversationRecord, Date) -> Bool

    public init(storage: any ChatHistoryStorage) {
        self.init(storage: storage, isExpired: Self.isExpired)
    }

    init(storage: any ChatHistoryStorage, isExpired: @escaping (ConversationRecord, Date) -> Bool) {
        self.storage = storage
        self.isExpired = isExpired
    }

    /// The conversations `prune` would delete, for previews in settings.
    public func candidates(
        policy: ChatRetentionPolicy,
        protecting protected: Set<UUID> = [],
        now: Date = Date()
    ) throws -> [ConversationRecord] {
        guard let cutoff = policy.cutoff(now: now) else { return [] }
        return try storage.conversations(matching: ConversationQuery(includeArchived: true))
            .filter { !$0.isPinned && !$0.isRetentionExempt && !protected.contains($0.id) }
            .filter { isExpired($0, cutoff) }
    }

    @discardableResult
    public func prune(
        policy: ChatRetentionPolicy,
        protecting protected: Set<UUID> = [],
        now: Date = Date()
    ) throws -> ChatRetentionReport {
        guard let cutoff = policy.cutoff(now: now) else { return .none }
        let all = try storage.conversations(matching: ConversationQuery(includeArchived: true))
        let expired = try candidates(policy: policy, protecting: protected, now: now)
        let ids = Set(expired.map(\.id))
        if !ids.isEmpty {
            try storage.deleteConversations(ids: ids)
        }
        return ChatRetentionReport(cutoff: cutoff, evaluatedCount: all.count, deletedIDs: ids)
    }

    /// Whether an eligible conversation (not pinned, exempt or protected) has
    /// been inactive long enough to delete.
    ///
    /// - Parameters:
    ///   - record: the conversation, including `updatedAt` (last title,
    ///     settings or message change), `lastMessageAt` (newest message,
    ///     `nil` when empty), `createdAt` and `archivedAt`.
    ///   - cutoff: the policy's boundary; activity before it is "too old".
    public static func isExpired(_ record: ConversationRecord, cutoff: Date) -> Bool {
        // TODO(Reid): decide what "inactive" means. Until this is written,
        // retention never deletes anything, even with a policy turned on.
        //
        // Questions to settle in 5-10 lines:
        // - Which timestamp marks the last activity: `updatedAt` (counts a
        //   rename as activity), `lastMessageAt` (only messages count), or
        //   the later of the two?
        // - An empty conversation has no `lastMessageAt`; should it age from
        //   `createdAt`?
        // - Should an archived conversation expire sooner, for example by
        //   aging from `archivedAt` instead?
        return false
    }
}
