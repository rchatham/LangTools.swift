//
//  TodoListView.swift
//  CLI
//
//  Views for displaying the todo list
//

import SwiftTUI
import Foundation

/// Main view for displaying the todo list
struct TodoListView: View {
    let todos: [TodoItem]
    let showCompleted: Bool

    init(todos: [TodoItem], showCompleted: Bool = true) {
        self.todos = todos
        self.showCompleted = showCompleted
    }

    var body: some View {
        VStack(alignment: .leading) {
            if todos.isEmpty {
                EmptyView()
            } else {
                // Header with progress
                headerView

                // Todos by status
                ForEach(filteredTodos) { todo in
                    TodoItemView(item: todo)
                }
            }
        }
    }

    private var headerView: some View {
        HStack {
            Text("📋")
                .foregroundColor(.cyan)
            Text("Tasks:")
                .foregroundColor(.cyan)
                .bold()

            let completed = todos.filter { $0.status == .completed }.count
            Text("\(completed)/\(todos.count)")
                .foregroundColor(.white)

            Spacer()
        }
    }

    private var filteredTodos: [TodoItem] {
        if showCompleted {
            return todos
        } else {
            return todos.filter { $0.status != .completed }
        }
    }
}

/// View for a single todo item
struct TodoItemView: View {
    let item: TodoItem

    var body: some View {
        HStack {
            Text("  ")
            statusIcon
            Text(displayText)
                .foregroundColor(textColor)
        }
    }

    private var statusIcon: some View {
        switch item.status {
        case .pending:
            return Text("○")
                .foregroundColor(.white)
        case .inProgress:
            return Text("◐")
                .foregroundColor(.yellow)
        case .completed:
            return Text("●")
                .foregroundColor(.green)
        }
    }

    private var displayText: String {
        switch item.status {
        case .pending, .completed:
            return item.content
        case .inProgress:
            return item.activeForm
        }
    }

    private var textColor: Color {
        switch item.status {
        case .pending:
            return .white
        case .inProgress:
            return .yellow
        case .completed:
            return .green
        }
    }
}

/// Compact todo indicator for status bar
struct TodoProgressIndicatorView: View {
    let todos: [TodoItem]

    var body: some View {
        if todos.isEmpty {
            EmptyView()
        } else {
            HStack {
                Text("📋")
                    .foregroundColor(.cyan)

                let completed = todos.filter { $0.status == .completed }.count
                let total = todos.count
                Text("\(completed)/\(total)")
                    .foregroundColor(.white)

                if let current = todos.first(where: { $0.status == .inProgress }) {
                    Text("- \(current.activeForm)")
                        .foregroundColor(.yellow)
                }
            }
        }
    }
}

/// View showing current task with status
struct CurrentTaskView: View {
    let currentTask: TodoItem?

    var body: some View {
        if let task = currentTask {
            HStack {
                Text("◐")
                    .foregroundColor(.yellow)
                Text(task.activeForm)
                    .foregroundColor(.yellow)
            }
        }
    }
}

// MARK: - Preview Helpers

#if DEBUG
extension TodoListView {
    static var preview: TodoListView {
        TodoListView(todos: [
            TodoItem(content: "Create ToolRegistry", status: .completed, activeForm: "Creating ToolRegistry"),
            TodoItem(content: "Implement ReadTool", status: .completed, activeForm: "Implementing ReadTool"),
            TodoItem(content: "Add unit tests", status: .inProgress, activeForm: "Adding unit tests"),
            TodoItem(content: "Update documentation", status: .pending, activeForm: "Updating documentation"),
            TodoItem(content: "Review code", status: .pending, activeForm: "Reviewing code")
        ])
    }
}
#endif
