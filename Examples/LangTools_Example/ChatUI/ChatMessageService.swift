//
//  MessageService.swift
//  LangTools_Example
//
//  Created by Reid Chatham on 2/16/25.
//

import Foundation
import Combine

public protocol ChatMessageInfo: ObservableObject, Identifiable, Hashable where ID == UUID {
    var uuid: UUID { get }
    var text: String? { get }

    var childChatMessages: [Self] { get }

    var isUser: Bool { get }
    var isAssistant: Bool { get }
    var isAgentEvent: Bool { get }
}

public protocol ChatMessageService: ObservableObject {
    associatedtype ChatMessage: ChatMessageInfo
    var chatMessages: [ChatMessage] { get set }
    func performChatCompletionRequest(message: String, stream: Bool) async throws
    func deleteMessage(id: UUID)
}


