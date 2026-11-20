//
//  ChatSessionManager.swift
//  ChatHistory
//

import Combine
import Foundation

/// Owns the live `ChatSession`s of one store. Create one per process.
///
/// There is at most one live session per conversation, so every window (and
/// any headless run) shares the same transcript and persistence pipeline.
/// Idle sessions beyond `maximumIdleSessions` are released; a released
/// session that a view still holds is reused instead of duplicated.
@MainActor
public final class ChatSessionManager: ObservableObject {
    public let storage: any ChatHistoryStorage
    public let hooks: ChatSessionHooks
    public let timing: ChatPersistenceTiming
    public let paging: ChatSessionPaging
    public var maximumIdleSessions: Int

    private final class WeakSession {
        weak var value: ChatSession?
        init(_ value: ChatSession) { self.value = value }
    }

    private var retained: [UUID: ChatSession] = [:]
    private var released: [UUID: WeakSession] = [:]
    private var lastAccess: [UUID: UInt64] = [:]
    private var accessClock: UInt64 = 0
    private var storageChanges: AnyCancellable?

    public init(
        storage: any ChatHistoryStorage,
        hooks: ChatSessionHooks,
        timing: ChatPersistenceTiming = .standard,
        paging: ChatSessionPaging = .standard,
        maximumIdleSessions: Int = 16
    ) {
        self.storage = storage
        self.hooks = hooks
        self.timing = timing
        self.paging = paging
        self.maximumIdleSessions = maximumIdleSessions
        storageChanges = storage.changes.sink { [weak self] change in
            MainActor.assumeIsolated {
                if case .conversationsDeleted(let ids) = change {
                    for id in ids { self?.closeSession(id: id) }
                }
            }
        }
    }

    /// The live session for a stored conversation, loading it if needed.
    public func session(for conversationID: UUID) throws -> ChatSession {
        if let session = liveSession(for: conversationID) {
            touch(session)
            return session
        }
        guard let record = try storage.conversation(id: conversationID) else {
            throw ChatHistoryError.conversationNotFound(conversationID)
        }
        let session = try ChatSession(record: record, draft: nil, storage: storage, hooks: hooks, timing: timing, paging: paging)
        register(session)
        return session
    }

    /// A session for a conversation that is created in storage only when its
    /// first message is sent. Asking again with the same draft ID returns the
    /// same session.
    public func draftSession(_ draft: ConversationDraft) -> ChatSession {
        if let session = liveSession(for: draft.id) {
            touch(session)
            return session
        }
        // The draft was stored earlier and its session released: load it.
        if let record = try? storage.conversation(id: draft.id),
           let session = try? ChatSession(record: record, draft: nil, storage: storage, hooks: hooks, timing: timing, paging: paging) {
            register(session)
            return session
        }
        // A draft session cannot fail to load: there is nothing stored yet.
        let session = try! ChatSession(record: nil, draft: draft, storage: storage, hooks: hooks, timing: timing, paging: paging)
        register(session)
        return session
    }

    /// The session for `conversationID` if one is live, without loading.
    public func liveSession(for conversationID: UUID) -> ChatSession? {
        if let session = retained[conversationID] { return session }
        if let session = released[conversationID]?.value {
            retained[conversationID] = session
            released.removeValue(forKey: conversationID)
            return session
        }
        released.removeValue(forKey: conversationID)
        return nil
    }

    /// Conversations with a live session. Retention never deletes these.
    public var liveConversationIDs: Set<UUID> {
        released = released.filter { $0.value.value != nil }
        return Set(retained.keys).union(released.keys)
    }

    /// Saves every session's queued changes now, for example when the app is
    /// about to become inactive. Failed batches stay queued and are returned.
    @discardableResult
    public func flushAll() -> [Error] {
        var failures: [Error] = []
        for session in allLiveSessions where session.hasPendingPersistence {
            do {
                try session.flush()
            } catch {
                failures.append(error)
            }
        }
        return failures
    }

    /// Closes and forgets a conversation's session (used on deletion).
    public func closeSession(id: UUID) {
        let session = retained.removeValue(forKey: id) ?? released[id]?.value
        released.removeValue(forKey: id)
        lastAccess.removeValue(forKey: id)
        session?.close()
    }

    // MARK: - Private

    private var allLiveSessions: [ChatSession] {
        Array(retained.values) + released.values.compactMap(\.value)
    }

    private func register(_ session: ChatSession) {
        retained[session.conversationID] = session
        session.onActivityChanged = { [weak self] _ in self?.evictIdleSessionsIfNeeded() }
        touch(session)
    }

    private func touch(_ session: ChatSession) {
        accessClock &+= 1
        lastAccess[session.conversationID] = accessClock
        evictIdleSessionsIfNeeded()
    }

    /// Moves the least recently used idle sessions to weak references.
    private func evictIdleSessionsIfNeeded() {
        let idle = retained.values.filter { !$0.hasActivity }
        let excess = idle.count - maximumIdleSessions
        guard excess > 0 else { return }
        let oldestFirst = idle.sorted {
            (lastAccess[$0.conversationID] ?? 0) < (lastAccess[$1.conversationID] ?? 0)
        }
        for session in oldestFirst.prefix(excess) {
            retained.removeValue(forKey: session.conversationID)
            released[session.conversationID] = WeakSession(session)
        }
    }
}
