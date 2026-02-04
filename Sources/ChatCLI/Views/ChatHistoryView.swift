//
//  ChatHistoryView.swift
//  ChatCLI
//
//  Scrollable view of chat messages
//

import SwiftTUI
import Foundation

/// Scrollable chat history view
struct ChatHistoryView: View {
    let messages: [ChatMessage]
    let isStreaming: Bool

    var body: some View {
        VStack(alignment: .leading) {
            if messages.isEmpty {
                emptyStateView
            } else {
                ForEach(messages.indices, id: \.self) { index in
                    MessageView(message: messages[index])
                }
            }

            if isStreaming {
                streamingIndicator
            }
        }
        .frame(minHeight: 5)
    }

    private var emptyStateView: some View {
        VStack(alignment: .leading) {
            Text("Welcome to SwiftClaude CLI!")
                .foregroundColor(.cyan)
            Text("")
            Text("Type a message to start chatting, or /help for commands.")
                .foregroundColor(.white)
        }
    }

    private var streamingIndicator: some View {
        HStack {
            Text("⠋")
                .foregroundColor(.yellow)
            Text("Thinking...")
                .foregroundColor(.yellow)
                .italic()
        }
    }
}

// MARK: - Preview

#if DEBUG
extension ChatHistoryView {
    static var preview: ChatHistoryView {
        ChatHistoryView(
            messages: [
                ChatMessage(role: .user, content: "Hello!"),
                ChatMessage(role: .assistant, content: "Hi there! How can I help?")
            ],
            isStreaming: false
        )
    }
}
#endif
