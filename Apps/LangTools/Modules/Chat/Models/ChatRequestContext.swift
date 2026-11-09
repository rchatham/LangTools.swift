//
//  ChatRequestContext.swift
//

import Foundation
import LangTools

/// The inputs of one provider request, as seen by `MessageService.requestPreparer`.
///
/// `history` is the request snapshot after failed attempts and the
/// `maxContextMessages` limit have been applied, without the system message.
/// `systemPrompt` is the text of the system message that will be prepended.
public struct ChatRequestContext {
    public var systemPrompt: String
    public var history: [Message]
    public let model: Model
    /// The conversation settings this request was built with, including
    /// `contextWindowPercent`.
    public let settings: ChatConversationSettings
    /// Prompts of other sends in this conversation that are still producing
    /// output. Their turns are unfinished, so a preparer must not fold them
    /// into a summary.
    public let inFlightMessageIDs: Set<UUID>
    /// The tools offered with this request. Their definitions take up part
    /// of the context window too. Read-only: a preparer cannot change them.
    public let tools: [Tool]
    /// Set when the provider rejected this request as longer than its
    /// context window and `MessageService` is asking for a shorter one before
    /// it retries once. A preparer that returns the request unchanged lets
    /// the provider's error stand.
    public var contextOverflow: ContextOverflow?

    public init(
        systemPrompt: String,
        history: [Message],
        model: Model,
        settings: ChatConversationSettings = .default,
        inFlightMessageIDs: Set<UUID> = [],
        tools: [Tool] = [],
        contextOverflow: ContextOverflow? = nil
    ) {
        self.systemPrompt = systemPrompt
        self.history = history
        self.model = model
        self.settings = settings
        self.inFlightMessageIDs = inFlightMessageIDs
        self.tools = tools
        self.contextOverflow = contextOverflow
    }
}
