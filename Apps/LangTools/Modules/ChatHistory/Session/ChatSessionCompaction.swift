//
//  ChatSessionCompaction.swift
//  ChatHistory
//
//  Context compaction for every session a `ChatSessionManager` creates.
//

import Foundation
import Chat
import ChatContext

public extension ChatSessionHooks {
    /// A `makeRequestPreparer` that compacts each conversation's requests,
    /// keeping its checkpoints in the session's store.
    ///
    /// - Parameters:
    ///   - policy: the policy for a conversation, read on every request.
    ///   - summarizer: writes summaries; `nil` uses only extractive summaries.
    ///   - onEvent: diagnostics, for logging.
    static func compactingRequestPreparers(
        policy: @escaping @MainActor (ConversationRecord?) -> CompactionPolicy,
        summarizer: (any ConversationSummarizer)?,
        estimator: TokenEstimator = .standard,
        onEvent: (@MainActor (_ conversationID: UUID, _ event: CompactingRequestPreparer.Event) -> Void)? = nil
    ) -> @MainActor (ChatSessionContext) -> (@MainActor (ChatRequestContext) async throws -> ChatRequestContext)? {
        { context in
            let preparer = CompactingRequestPreparer(
                conversationID: context.conversationID,
                checkpoints: context.checkpoints,
                policy: { policy(context.record) },
                summarizer: summarizer,
                estimator: estimator
            )
            if let onEvent {
                let conversationID = context.conversationID
                preparer.onEvent = { onEvent(conversationID, $0) }
            }
            return preparer.requestPreparer
        }
    }
}
