//
//  TodoWriteTool.swift
//  CLI
//
//  Tool for managing structured task lists during coding sessions
//

import Foundation
import OpenAI

/// A task item in the todo list
struct TodoItem: Codable, Identifiable, Equatable {
    let id: UUID
    var content: String
    var status: TodoStatus
    var activeForm: String

    init(content: String, status: TodoStatus = .pending, activeForm: String) {
        self.id = UUID()
        self.content = content
        self.status = status
        self.activeForm = activeForm
    }

    enum TodoStatus: String, Codable {
        case pending
        case inProgress = "in_progress"
        case completed
    }
}

/// Manages the todo list state
@MainActor
final class TodoManager: ObservableObject {
    /// Shared singleton instance
    static let shared = TodoManager()

    /// Current todo items
    @Published private(set) var todos: [TodoItem] = []

    /// Maximum items to keep
    private let maxItems = 50

    private init() {}

    /// Replace all todos with new list
    func setTodos(_ newTodos: [TodoItem]) {
        // Trim to max items
        if newTodos.count > maxItems {
            todos = Array(newTodos.prefix(maxItems))
        } else {
            todos = newTodos
        }
    }

    /// Add a single todo
    func addTodo(content: String, activeForm: String, status: TodoStatus = .pending) {
        let item = TodoItem(content: content, status: status, activeForm: activeForm)
        todos.append(item)

        // Trim if needed
        if todos.count > maxItems {
            todos = Array(todos.suffix(maxItems))
        }
    }

    /// Update a todo's status
    func updateStatus(id: UUID, status: TodoStatus) {
        if let index = todos.firstIndex(where: { $0.id == id }) {
            todos[index].status = status
        }
    }

    /// Mark a todo as in progress by content
    func markInProgress(content: String) {
        if let index = todos.firstIndex(where: { $0.content == content }) {
            todos[index].status = .inProgress
        }
    }

    /// Mark a todo as completed by content
    func markCompleted(content: String) {
        if let index = todos.firstIndex(where: { $0.content == content }) {
            todos[index].status = .completed
        }
    }

    /// Remove a todo by content
    func removeTodo(content: String) {
        todos.removeAll { $0.content == content }
    }

    /// Clear all todos
    func clearAll() {
        todos.removeAll()
    }

    /// Get todos by status
    func todos(withStatus status: TodoStatus) -> [TodoItem] {
        todos.filter { $0.status == status }
    }

    /// Current in-progress todo
    var currentTask: TodoItem? {
        todos.first { $0.status == .inProgress }
    }

    /// Progress summary
    var progressSummary: String {
        let completed = todos.filter { $0.status == .completed }.count
        let total = todos.count
        let pending = todos.filter { $0.status == .pending }.count
        let inProgress = todos.filter { $0.status == .inProgress }.count

        return "\(completed)/\(total) complete (\(inProgress) in progress, \(pending) pending)"
    }
}

/// Tool for writing/updating the todo list
struct TodoWriteTool: ExecutableTool {
    static let name = "todo_write"

    static let description = """
        Manage a structured task list for tracking progress on complex tasks.

        Use this tool to:
        - Plan multi-step tasks
        - Track progress on current work
        - Show the user what you're working on
        - Break down complex tasks into smaller steps

        When to use:
        - Complex tasks with 3+ steps
        - When the user provides multiple tasks
        - After receiving new instructions
        - To update task status as you work

        When NOT to use:
        - Single, trivial tasks
        - Purely conversational interactions
        """

    static let parametersSchema = OpenAI.Tool.FunctionSchema.Parameters(
        properties: [
            "todosJson": .init(
                type: "string",
                description: """
                    JSON array of todo items: [{"content":"Task description","status":"pending|in_progress|completed","activeForm":"Doing task"}]
                    - content: What needs to be done (imperative form)
                    - status: pending, in_progress, or completed
                    - activeForm: Present continuous form shown during execution
                    """
            )
        ],
        required: ["todosJson"]
    )

    static func execute(parameters: [String: Any]) async throws -> String {
        guard let jsonString = ToolRegistry.extractString(parameters, key: "todosJson"),
              let data = jsonString.data(using: .utf8) else {
            throw ToolError.missingRequiredParameter(tool: name, parameter: "todosJson")
        }

        // Decode the todos
        struct RawTodo: Codable {
            let content: String
            let status: String
            let activeForm: String
        }

        do {
            let rawTodos = try JSONDecoder().decode([RawTodo].self, from: data)
            let todoItems = rawTodos.map { raw in
                TodoItem(
                    content: raw.content,
                    status: TodoStatus(rawValue: raw.status) ?? .pending,
                    activeForm: raw.activeForm
                )
            }

            await MainActor.run {
                TodoManager.shared.setTodos(todoItems)
            }

            let summary = await MainActor.run {
                TodoManager.shared.progressSummary
            }

            return "Todo list updated. \(summary)"
        } catch {
            throw ToolError.invalidParameters(tool: name, reason: "Invalid JSON: \(error.localizedDescription)")
        }
    }
}

// Alias for consistency
typealias TodoStatus = TodoItem.TodoStatus
