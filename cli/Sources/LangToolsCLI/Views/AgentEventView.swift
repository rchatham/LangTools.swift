//
//  AgentEventView.swift
//  CLI
//
//  View for displaying agent task progress and results
//

import SwiftTUI
import Foundation

/// View showing an active agent task
struct AgentTaskView: View {
    let task: AgentTask
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading) {
            // Header
            HStack {
                Text("🤖")
                    .foregroundColor(.cyan)

                Text("Agent: \(task.agentType.rawValue)")
                    .foregroundColor(.cyan)
                    .bold()

                Text(" - \(task.description)")
                    .foregroundColor(.white)

                Spacer()

                statusIndicator
            }

            // Progress info
            if task.status == .running {
                HStack {
                    Text("  ⟳")
                        .foregroundColor(.yellow)
                    Text("Running...")
                        .foregroundColor(.yellow)
                    if let duration = task.duration {
                        Text("(\(formatDuration(duration)))")
                            .foregroundColor(.white)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch task.status {
        case .pending:
            Text("⏳ Pending")
                .foregroundColor(.white)
        case .running:
            Text("[Ctrl+C to cancel]")
                .foregroundColor(.white)
        case .completed:
            Text("✓ Done")
                .foregroundColor(.green)
        case .failed:
            Text("✗ Failed")
                .foregroundColor(.red)
        case .cancelled:
            Text("○ Cancelled")
                .foregroundColor(.yellow)
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 1 {
            return String(format: "%.0fms", seconds * 1000)
        } else if seconds < 60 {
            return String(format: "%.1fs", seconds)
        } else {
            let minutes = Int(seconds / 60)
            let secs = Int(seconds.truncatingRemainder(dividingBy: 60))
            return "\(minutes)m \(secs)s"
        }
    }
}

/// View for displaying agent task result
struct AgentResultView: View {
    let task: AgentTask
    let isCollapsed: Bool
    let onToggleCollapse: () -> Void

    /// Maximum lines to show
    private let maxDisplayLines = 15

    var body: some View {
        VStack(alignment: .leading) {
            // Header
            HStack {
                Text("🤖")
                    .foregroundColor(.cyan)

                Text("Agent Result:")
                    .foregroundColor(.cyan)
                    .bold()

                Text(" \(task.agentType.rawValue)")
                    .foregroundColor(.cyan)

                if let duration = task.duration {
                    Text(" (\(formatDuration(duration)))")
                        .foregroundColor(.white)
                }

                Text(isCollapsed ? " [+]" : " [-]")
                    .foregroundColor(.white)
            }

            // Result content
            if !isCollapsed {
                if let result = task.result {
                    resultContent(result)
                } else if let error = task.error {
                    Text("  Error: \(error)")
                        .foregroundColor(.red)
                }
            }
        }
    }

    @ViewBuilder
    private func resultContent(_ result: String) -> some View {
        let lines = result.components(separatedBy: .newlines)
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

    private func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 1 {
            return String(format: "%.0fms", seconds * 1000)
        } else if seconds < 60 {
            return String(format: "%.1fs", seconds)
        } else {
            let minutes = Int(seconds / 60)
            let secs = Int(seconds.truncatingRemainder(dividingBy: 60))
            return "\(minutes)m \(secs)s"
        }
    }
}

/// View for listing active agent tasks
struct ActiveAgentsView: View {
    let tasks: [AgentTask]
    let onCancel: (String) -> Void

    var body: some View {
        VStack(alignment: .leading) {
            if tasks.isEmpty {
                EmptyView()
            } else {
                Text("Active Agents:")
                    .foregroundColor(.cyan)
                    .bold()

                ForEach(tasks) { task in
                    AgentTaskView(task: task) {
                        onCancel(task.id)
                    }
                }
            }
        }
    }
}

/// View for agent task history
struct AgentHistoryView: View {
    let tasks: [AgentTask]
    let maxItems: Int

    init(tasks: [AgentTask], maxItems: Int = 5) {
        self.tasks = tasks
        self.maxItems = maxItems
    }

    var body: some View {
        VStack(alignment: .leading) {
            Text("Recent Agent Tasks:")
                .foregroundColor(.cyan)
                .bold()

            if tasks.isEmpty {
                Text("  No recent tasks")
                    .foregroundColor(.white)
            } else {
                ForEach(tasks.prefix(maxItems)) { task in
                    historyRow(task)
                }
            }
        }
    }

    private func historyRow(_ task: AgentTask) -> some View {
        HStack {
            Text("  \(statusIcon(task.status))")
                .foregroundColor(statusColor(task.status))

            Text(task.agentType.rawValue)
                .foregroundColor(.white)

            Text("- \(task.description)")
                .foregroundColor(.white)

            if let duration = task.duration {
                Text("(\(formatDuration(duration)))")
                    .foregroundColor(.white)
            }
        }
    }

    private func statusIcon(_ status: AgentTask.TaskStatus) -> String {
        switch status {
        case .pending: return "⏳"
        case .running: return "⟳"
        case .completed: return "✓"
        case .failed: return "✗"
        case .cancelled: return "○"
        }
    }

    private func statusColor(_ status: AgentTask.TaskStatus) -> Color {
        switch status {
        case .pending: return .white
        case .running: return .yellow
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .yellow
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 1 {
            return String(format: "%.0fms", seconds * 1000)
        } else if seconds < 60 {
            return String(format: "%.1fs", seconds)
        } else {
            let minutes = Int(seconds / 60)
            let secs = Int(seconds.truncatingRemainder(dividingBy: 60))
            return "\(minutes)m \(secs)s"
        }
    }
}

// MARK: - Preview Helpers

#if DEBUG
extension AgentTaskView {
    static var preview: AgentTaskView {
        AgentTaskView(
            task: AgentTask(
                id: "test-123",
                agentType: .explore,
                prompt: "Find all Swift files",
                description: "Exploring codebase",
                status: .running,
                startTime: Date()
            ),
            onCancel: {}
        )
    }
}

extension AgentResultView {
    static var preview: AgentResultView {
        AgentResultView(
            task: AgentTask(
                id: "test-123",
                agentType: .explore,
                prompt: "Find all Swift files",
                description: "Exploring codebase",
                status: .completed,
                result: "Found 42 Swift files...",
                startTime: Date().addingTimeInterval(-5),
                endTime: Date()
            ),
            isCollapsed: false,
            onToggleCollapse: {}
        )
    }
}
#endif
