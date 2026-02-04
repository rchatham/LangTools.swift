//
//  ToolExecutionView.swift
//  ChatCLI
//
//  View for displaying tool execution status and results
//

import SwiftTUI
import Foundation

/// View showing the currently executing tool
struct ToolExecutionView: View {
    let toolName: String
    let progressMessage: String?
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                // Spinner indicator
                Text("⚙")
                    .foregroundColor(.cyan)

                Text("Running: \(toolName)")
                    .foregroundColor(.cyan)
                    .bold()

                if let message = progressMessage {
                    Text(" - \(message)")
                        .foregroundColor(.white)
                }

                Spacer()

                Text("[Ctrl+C to cancel]")
                    .foregroundColor(.white)
            }
        }
    }
}

/// View for displaying a completed tool result
struct ToolResultDisplayView: View {
    let result: ToolExecutionResult
    let isCollapsed: Bool
    let onToggleCollapse: () -> Void

    /// Maximum lines to show when expanded
    private let maxDisplayLines = 20

    var body: some View {
        VStack(alignment: .leading) {
            // Header with tool name and duration
            HStack {
                Text("Tool:")
                    .foregroundColor(.magenta)
                    .bold()

                Text(" \(result.toolName)")
                    .foregroundColor(.magenta)

                Text(" (\(formattedDuration))")
                    .foregroundColor(.white)

                if result.truncated {
                    Text(" [truncated]")
                        .foregroundColor(.yellow)
                }

                Text(isCollapsed ? " [+]" : " [-]")
                    .foregroundColor(.white)
            }

            // Output content
            if !isCollapsed {
                outputView
            }
        }
    }

    @ViewBuilder
    private var outputView: some View {
        let lines = result.output.components(separatedBy: .newlines)
        let displayLines = Array(lines.prefix(maxDisplayLines))

        ForEach(displayLines.indices, id: \.self) { index in
            Text("  \(displayLines[index])")
                .foregroundColor(.white)
        }

        if lines.count > maxDisplayLines {
            Text("  ... (\(lines.count - maxDisplayLines) more lines)")
                .foregroundColor(.white)
        }
    }

    private var formattedDuration: String {
        if result.duration < 1 {
            return String(format: "%.0fms", result.duration * 1000)
        } else if result.duration < 60 {
            return String(format: "%.1fs", result.duration)
        } else {
            let minutes = Int(result.duration / 60)
            let seconds = Int(result.duration.truncatingRemainder(dividingBy: 60))
            return "\(minutes)m \(seconds)s"
        }
    }
}

/// View for approval requests
struct ApprovalRequestView: View {
    let request: ApprovalRequest
    let onApprove: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading) {
            // Warning banner
            HStack {
                Text("⚠")
                    .foregroundColor(.yellow)
                Text(" Approval Required")
                    .foregroundColor(.yellow)
                    .bold()
            }

            // Operation description
            Text("  \(request.description)")
                .foregroundColor(.white)

            // Parameters preview
            parameterPreview

            // Action prompt
            HStack {
                Text("  Approve? [y/n]: ")
                    .foregroundColor(.cyan)
            }
        }
    }

    @ViewBuilder
    private var parameterPreview: some View {
        // Show relevant parameters based on tool type
        switch request.toolName {
        case "write":
            if let path = request.parameters["file_path"] as? String {
                Text("  File: \(path)")
                    .foregroundColor(.white)
            }

        case "edit":
            if let path = request.parameters["file_path"] as? String {
                Text("  File: \(path)")
                    .foregroundColor(.white)
            }
            if let oldString = request.parameters["old_string"] as? String {
                let truncated = oldString.count > 50 ? String(oldString.prefix(50)) + "..." : oldString
                Text("  Replace: \"\(truncated)\"")
                    .foregroundColor(.white)
            }

        case "bash":
            if let command = request.parameters["command"] as? String {
                let lines = Array(command.components(separatedBy: .newlines).prefix(3))
                ForEach(lines.indices, id: \.self) { index in
                    let truncated = lines[index].count > 70 ? String(lines[index].prefix(70)) + "..." : lines[index]
                    Text("  $ \(truncated)")
                        .foregroundColor(.white)
                }
                if command.components(separatedBy: .newlines).count > 3 {
                    Text("  ...")
                        .foregroundColor(.white)
                }
            }

        default:
            EmptyView()
        }
    }
}

/// View for tool execution history
struct ToolHistoryView: View {
    let history: [ToolExecutionRecord]
    let maxItems: Int

    init(history: [ToolExecutionRecord], maxItems: Int = 5) {
        self.history = history
        self.maxItems = maxItems
    }

    var body: some View {
        VStack(alignment: .leading) {
            Text("Recent Tool Executions:")
                .foregroundColor(.cyan)
                .bold()

            if history.isEmpty {
                Text("  No recent executions")
                    .foregroundColor(.white)
            } else {
                ForEach(history.prefix(maxItems)) { record in
                    historyRow(record)
                }
            }
        }
    }

    private func historyRow(_ record: ToolExecutionRecord) -> some View {
        HStack {
            Text("  \(record.statusIcon)")
                .foregroundColor(statusColor(record.status))

            Text(record.toolName)
                .foregroundColor(.white)

            Text("(\(record.formattedDuration))")
                .foregroundColor(.white)

            Spacer()

            Text(formatTimestamp(record.timestamp))
                .foregroundColor(.white)
        }
    }

    private func statusColor(_ status: ToolExecutionRecord.ExecutionStatus) -> Color {
        switch status {
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .yellow
        }
    }

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

// MARK: - Preview Helpers

#if DEBUG
extension ToolExecutionView {
    static var preview: ToolExecutionView {
        ToolExecutionView(
            toolName: "bash",
            progressMessage: "Executing command...",
            onCancel: {}
        )
    }
}

extension ToolResultDisplayView {
    static var preview: ToolResultDisplayView {
        ToolResultDisplayView(
            result: ToolExecutionResult(
                toolName: "bash",
                output: "Line 1\nLine 2\nLine 3",
                exitCode: 0,
                duration: 1.5,
                truncated: false
            ),
            isCollapsed: false,
            onToggleCollapse: {}
        )
    }
}
#endif
