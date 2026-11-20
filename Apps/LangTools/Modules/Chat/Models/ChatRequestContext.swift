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

    public init(systemPrompt: String, history: [Message], model: Model) {
        self.systemPrompt = systemPrompt
        self.history = history
        self.model = model
    }
}
