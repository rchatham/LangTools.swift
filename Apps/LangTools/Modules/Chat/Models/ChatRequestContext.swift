//
//  ChatRequestContext.swift
//

import Foundation

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

    public init(
        systemPrompt: String,
        history: [Message],
        model: Model,
        settings: ChatConversationSettings = .default,
        inFlightMessageIDs: Set<UUID> = []
    ) {
        self.systemPrompt = systemPrompt
        self.history = history
        self.model = model
        self.settings = settings
        self.inFlightMessageIDs = inFlightMessageIDs
    }
}
