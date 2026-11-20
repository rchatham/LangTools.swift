//
//  ChatHistorySchemaV2.swift
//  ChatHistory
//
//  SwiftData schema, version 2: version 1's conversations and messages,
//  unchanged, plus context checkpoints. The same model rules apply: no
//  `@Attribute(.unique)`, every property defaulted, no relationships.
//

import Foundation
import SwiftData
import ChatContext

enum ChatHistorySchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            ChatHistorySchemaV1.ChatHistoryConversation.self,
            ChatHistorySchemaV1.ChatHistoryMessage.self,
            ChatHistoryCheckpoint.self,
        ]
    }

    /// A stable summary of a conversation's older turns (`ContextCheckpoint`).
    @Model
    final class ChatHistoryCheckpoint {
        var id: UUID = UUID()
        var conversationID: UUID = UUID()
        var coversThroughMessageID: UUID = UUID()
        var summary: String = ""
        var tokenEstimate: Int = 0
        var model: String = ""
        var createdAt: Date = Date()

        init(id: UUID, conversationID: UUID) {
            self.id = id
            self.conversationID = conversationID
        }
    }
}

enum ChatHistoryMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [ChatHistorySchemaV1.self, ChatHistorySchemaV2.self] }
    /// Version 2 only adds an entity, so the migration is lightweight.
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: ChatHistorySchemaV1.self, toVersion: ChatHistorySchemaV2.self)]
    }
}

typealias ChatHistoryCheckpoint = ChatHistorySchemaV2.ChatHistoryCheckpoint

extension ChatHistoryCheckpoint {
    var checkpoint: ContextCheckpoint {
        ContextCheckpoint(
            id: id,
            conversationID: conversationID,
            coversThroughMessageID: coversThroughMessageID,
            summary: summary,
            tokenEstimate: tokenEstimate,
            model: model,
            createdAt: createdAt
        )
    }

    func apply(_ checkpoint: ContextCheckpoint) {
        coversThroughMessageID = checkpoint.coversThroughMessageID
        summary = checkpoint.summary
        tokenEstimate = checkpoint.tokenEstimate
        model = checkpoint.model
        createdAt = checkpoint.createdAt
    }
}
