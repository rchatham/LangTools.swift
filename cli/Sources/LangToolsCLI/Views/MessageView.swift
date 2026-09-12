//
//  MessageView.swift
//  CLI
//
//  Individual message display with role-based styling
//

import SwiftTUI
import Foundation

/// View for displaying a single chat message
struct MessageView: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: .leading) {
            switch message.role {
            case .user:
                UserMessageView(content: message.content)
            case .assistant:
                AssistantMessageView(content: message.content)
            case .system:
                SystemMessageView(content: message.content)
            case .tool:
                ToolResultView(
                    toolName: message.toolName ?? "Tool",
                    content: message.content,
                    isCollapsed: message.isCollapsed
                )
            }
        }
    }
}

/// User message view with green styling
struct UserMessageView: View {
    let content: String

    var body: some View {
        HStack(alignment: .top) {
            Text("You:")
                .foregroundColor(.green)
                .bold()

            Text(" \(content)")
                .foregroundColor(.white)
        }
    }
}

/// Assistant message view with yellow styling
struct AssistantMessageView: View {
    let content: String

    var body: some View {
        VStack(alignment: .leading) {
            Text("Assistant:")
                .foregroundColor(.yellow)
                .bold()

            // Split content into lines for better display
            ForEach(contentLines.indices, id: \.self) { index in
                Text(contentLines[index])
                    .foregroundColor(.white)
            }
        }
    }

    private var contentLines: [String] {
        content.components(separatedBy: .newlines)
    }
}

/// System message view with cyan styling
struct SystemMessageView: View {
    let content: String

    var body: some View {
        VStack(alignment: .leading) {
            ForEach(contentLines.indices, id: \.self) { index in
                Text(contentLines[index])
                    .foregroundColor(.cyan)
            }
        }
    }

    private var contentLines: [String] {
        content.components(separatedBy: .newlines)
    }
}

/// Tool result view with collapsible output
struct ToolResultView: View {
    let toolName: String
    let content: String
    let isCollapsed: Bool

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Tool:")
                    .foregroundColor(.magenta)
                    .bold()

                Text(" \(toolName)")
                    .foregroundColor(.magenta)

                if isCollapsed {
                    Text(" [collapsed]")
                        .foregroundColor(.white)
                }
            }

            if !isCollapsed {
                // Show truncated output
                let lines = content.components(separatedBy: .newlines)
                let displayLines = lines.prefix(20)

                ForEach(displayLines.indices, id: \.self) { index in
                    Text("  \(displayLines[index])")
                        .foregroundColor(.white)
                }

                if lines.count > 20 {
                    Text("  ... (\(lines.count - 20) more lines)")
                        .foregroundColor(.white)
                }
            }
        }
    }
}

// MARK: - Previews

#if DEBUG
extension MessageView {
    static var userPreview: MessageView {
        MessageView(message: ChatMessage(role: .user, content: "Hello!"))
    }

    static var assistantPreview: MessageView {
        MessageView(message: ChatMessage(role: .assistant, content: "Hello! How can I help you today?"))
    }

    static var systemPreview: MessageView {
        MessageView(message: ChatMessage(role: .system, content: "System message"))
    }
}
#endif
