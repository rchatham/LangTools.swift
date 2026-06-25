//
//  StatusLineView.swift
//  CLI
//
//  Status line displayed at the bottom showing current operation status
//

import SwiftTUI
import Foundation

/// Configurable status line displayed at the bottom of the TUI
struct StatusLineView: View {
    let status: String
    let isStreaming: Bool
    let currentTool: String?
    let errorMessage: String?
    let config: StatusLineConfig

    var body: some View {
        HStack {
            statusIndicator

            Spacer()

            if config.showErrorMessages, let error = errorMessage {
                Text(error)
                    .foregroundColor(.red)
            }
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if config.showToolExecution, let tool = currentTool {
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
                Text(status)
                    .foregroundColor(.green)
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
extension StatusLineView {
    static var readyPreview: StatusLineView {
        StatusLineView(
            status: "Ready",
            isStreaming: false,
            currentTool: nil,
            errorMessage: nil,
            config: StatusLineConfig()
        )
    }

    static var streamingPreview: StatusLineView {
        StatusLineView(
            status: "Streaming...",
            isStreaming: true,
            currentTool: nil,
            errorMessage: nil,
            config: StatusLineConfig()
        )
    }

    static var toolPreview: StatusLineView {
        StatusLineView(
            status: "Running tool",
            isStreaming: false,
            currentTool: "BashTool",
            errorMessage: nil,
            config: StatusLineConfig()
        )
    }
}
#endif
