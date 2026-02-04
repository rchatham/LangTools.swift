//
//  StatusBarView.swift
//  ChatCLI
//
//  Status bar showing current operation and message count
//

import SwiftTUI
import Foundation

/// Status bar view at the bottom of the chat
struct StatusBarView: View {
    let statusMessage: String
    let messageCount: Int
    let currentTool: String?
    let isStreaming: Bool
    let errorMessage: String?

    var body: some View {
        HStack {
            statusIndicator

            Spacer()

            if let error = errorMessage {
                Text("Error: \(error)")
                    .foregroundColor(.red)

                Spacer()
            }

            Text("Messages: \(messageCount)")
                .foregroundColor(.white)
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if let tool = currentTool {
            HStack {
                Text("⚙")
                    .foregroundColor(.cyan)
                Text("Running: \(tool)")
                    .foregroundColor(.cyan)
            }
        } else if isStreaming {
            HStack {
                Text("⟳")
                    .foregroundColor(.yellow)
                Text("Streaming...")
                    .foregroundColor(.yellow)
            }
        } else if errorMessage != nil {
            HStack {
                Text("✗")
                    .foregroundColor(.red)
                Text("Error")
                    .foregroundColor(.red)
            }
        } else {
            HStack {
                Text("✓")
                    .foregroundColor(.green)
                Text(statusMessage)
                    .foregroundColor(.green)
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
extension StatusBarView {
    static var readyPreview: StatusBarView {
        StatusBarView(
            statusMessage: "Ready",
            messageCount: 5,
            currentTool: nil,
            isStreaming: false,
            errorMessage: nil
        )
    }

    static var streamingPreview: StatusBarView {
        StatusBarView(
            statusMessage: "Streaming...",
            messageCount: 5,
            currentTool: nil,
            isStreaming: true,
            errorMessage: nil
        )
    }

    static var toolPreview: StatusBarView {
        StatusBarView(
            statusMessage: "Running tool",
            messageCount: 5,
            currentTool: "BashTool",
            isStreaming: false,
            errorMessage: nil
        )
    }
}
#endif
