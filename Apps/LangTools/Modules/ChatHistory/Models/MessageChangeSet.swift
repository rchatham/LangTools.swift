//
//  MessageChangeSet.swift
//  ChatHistory
//

import Foundation
import Chat

/// One atomic batch of message writes for a single conversation.
///
/// `upserts` are applied in order. A message's agent-event children are
/// written with it. Deleting an ID also deletes its descendants. The type is
/// `Codable` so a future synced store can queue batches as outbox entries.
public struct MessageChangeSet: Codable {
    public var upserts: [Message]
    public var deletions: Set<UUID>

    public init(upserts: [Message] = [], deletions: Set<UUID> = []) {
        self.upserts = upserts
        self.deletions = deletions
    }

    public var isEmpty: Bool { upserts.isEmpty && deletions.isEmpty }
}
