//
//  ChatHistoryView.swift
//  CLI
//
//  Scrollable chat history view
//

import SwiftTUI
import Foundation

/// Full scrollable chat history.
///
/// The complete message list renders inside SwiftTUI's `ScrollView`. The scroll
/// control stays pinned to the bottom (new messages auto-follow) until the user
/// scrolls up with PageUp/PageDown/Home/End — paging back to the bottom resumes
/// following. The vendored SwiftTUI clamps the renderer's draw rect to the
/// window, so content taller than the viewport is safe (older revisions
/// crashed in `Renderer.drawPixel` for exactly this case), and the keyboard
/// scrolling routes through `Application.handleInput` regardless of which
/// control holds focus.
struct ChatHistoryView: View {
    let messages: [ChatMessage]
    let isStreaming: Bool

    var body: some View {
        if messages.isEmpty && !isStreaming {
            emptyStateView
        } else {
            ScrollView {
                ForEach(messages.indices, id: \.self) { index in
                    MessageView(message: messages[index])
                }

                if isStreaming {
                    streamingIndicator
                }
            }
        }
    }

    private var emptyStateView: some View {
        VStack(alignment: .leading) {
            Text("Welcome to LangTools CLI!")
                .foregroundColor(.cyan)
            Text("Type a message to start chatting, or /help for commands.")
                .foregroundColor(.white)
        }
        .frame(maxHeight: .infinity, alignment: .bottomLeading)
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