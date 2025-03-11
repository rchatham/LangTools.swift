//
//  MessageService.swift
//  LangTools_Example
//
//  Created by Reid Chatham on 2/16/25.
//

import Foundation
import Combine
import SwiftUI

public protocol ChatMessageInfo: Sendable, ObservableObject, Identifiable, Hashable where ID == UUID {
    var uuid: UUID { get }
    var text: String? { get }

    var parentMessage: Self? { get }
    var childChatMessages: [Self] { get }

    var isUser: Bool { get }
    var isAssistant: Bool { get }
    var isAgentEvent: Bool { get }
}

public protocol ChatMessageService: Sendable, ObservableObject {
    associatedtype ChatMessage: ChatMessageInfo
    var chatMessages: [ChatMessage] { get set }
    func send(message: String, stream: Bool) async throws
    func handleError(error: Error) -> ChatAlertInfo?
    func deleteMessage(id: UUID)
}

public struct ChatAlertInfo {
    public var title: String
    public var textField: TextFieldInfo?
    public var button: ButtonInfo?
    public var message: String?
    public init(title: String, textField: TextFieldInfo? = nil, button: ButtonInfo? = nil, message: String? = nil) {
        self.title = title
        self.textField = textField
        self.button = button
        self.message = message
    }
}

public struct TextFieldInfo {
    public var placeholder: String?
    public var label: String
    public var text: Binding<String>
    public init(placeholder: String? = nil, label: String, text: Binding<String>) {
        self.placeholder = placeholder
        self.label = label
        self.text = text
    }
}

public struct ButtonInfo {
    public var text: String
    public var action: (ChatAlertInfo) throws -> Void
    public var role: ButtonRole?
    public init(text: String, action: @escaping (ChatAlertInfo) throws -> Void = {_ in}, role: ButtonRole? = nil) {
        self.text = text
        self.action = action
        self.role = role
    }
}
