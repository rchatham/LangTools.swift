//
//  LangTools_ExampleApp.swift
//  LangTools_Example
//
//  Created by Reid Chatham on 9/23/24.
//

import SwiftUI
import ChatUI

@main
struct LangTools_ExampleApp: App {
    var messageService = MessageService()
    var body: some Scene {
        WindowGroup {
            ChatView(viewModel: .init(messageService: messageService, settingsView: { ChatSettingsView(viewModel: ChatSettingsView.ViewModel { self.messageService.messages = [] }) } ))
        }
    }
}

extension MessageService: ChatMessageService {
    var chatMessages: [Message] {
        get { messages }
        set(newValue) { messages = newValue }
    }

    typealias ChatMessage = Message
}

extension Message: ChatMessageInfo {
    var childChatMessages: [Message] { childMessages }
}
