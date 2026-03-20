# Phase 6: Advanced Features

## Goal
Add plan mode, session management, context handling, and advanced tools.

## Plan Mode

### Flow

```
EnterPlanMode
    ↓ (Read-only mode activated)
Exploration with Glob, Grep, Read
    ↓
Plan written to plan file
    ↓
ExitPlanMode
    ↓ (User reviews plan)
Approved → Implementation begins
Rejected → Revision cycle
```

### PlanMode State

```swift
class PlanMode: ObservableObject {
    @Published var isActive: Bool = false
    @Published var planFilePath: String?
    @Published var planContent: String = ""
    @Published var awaitingApproval: Bool = false

    func enter() {
        isActive = true
        planFilePath = createPlanFile()
    }

    func exit() async throws {
        awaitingApproval = true
        // Wait for user approval
    }

    func approve() {
        isActive = false
        awaitingApproval = false
    }

    func reject() {
        awaitingApproval = false
        // Continue in plan mode
    }
}
```

### Plan Mode Tools

```swift
struct EnterPlanModeTool: LangToolsTool {
    static let name = "EnterPlanMode"
    static let description = "Enter planning mode for complex tasks"

    static func execute(parameters: Empty) async throws -> String {
        await MainActor.run {
            PlanMode.shared.enter()
        }
        return "Plan mode activated. Explore and plan."
    }
}

struct ExitPlanModeTool: LangToolsTool {
    static let name = "ExitPlanMode"
    static let description = "Exit planning mode and request approval"

    static func execute(parameters: Empty) async throws -> String {
        try await PlanMode.shared.exit()
        return "Plan submitted for approval."
    }
}
```

## Todo Management

```swift
struct TodoWriteTool: LangToolsTool {
    static let name = "TodoWrite"
    static let description = "Manage task list for current session"

    struct Parameters: Codable {
        struct Todo: Codable {
            let content: String
            let status: String // pending, in_progress, completed
            let activeForm: String
        }
        let todos: [Todo]
    }

    static func execute(parameters: Parameters) async throws -> String {
        await MainActor.run {
            TodoManager.shared.update(parameters.todos)
        }
        return "Todos updated"
    }
}
```

## Session Management

```swift
class SessionManager {
    static let shared = SessionManager()

    private let sessionDir = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".swiftclaude/sessions")

    func save(_ session: ChatSession) throws {
        let data = try JSONEncoder().encode(session)
        let path = sessionDir.appendingPathComponent("\(session.id).json")
        try data.write(to: path)
    }

    func load(_ id: UUID) throws -> ChatSession {
        let path = sessionDir.appendingPathComponent("\(id).json")
        let data = try Data(contentsOf: path)
        return try JSONDecoder().decode(ChatSession.self, from: data)
    }

    func listSessions() -> [SessionSummary] {
        // List all saved sessions
    }
}

struct ChatSession: Codable {
    let id: UUID
    let messages: [Message]
    let createdAt: Date
    let lastModified: Date
    let workingDirectory: String
}
```

## Context Management

```swift
class ContextManager {
    private let maxTokens: Int = 100_000

    func trimContext(_ messages: [Message]) -> [Message] {
        var tokens = 0
        var result: [Message] = []

        // Keep system message
        if let system = messages.first(where: { $0.role == .system }) {
            result.append(system)
            tokens += estimateTokens(system.content)
        }

        // Add messages from newest to oldest until limit
        for message in messages.reversed() where message.role != .system {
            let messageTokens = estimateTokens(message.content)
            if tokens + messageTokens > maxTokens {
                break
            }
            result.insert(message, at: 1)
            tokens += messageTokens
        }

        return result
    }

    func summarize(_ messages: [Message]) async throws -> String {
        // Use LLM to summarize old messages
    }
}
```

## Slash Commands

```swift
enum SlashCommand: String, CaseIterable {
    case help
    case clear
    case model
    case session
    case save
    case load
    case exit

    static func parse(_ input: String) -> (SlashCommand, [String])? {
        guard input.hasPrefix("/") else { return nil }

        let parts = input.dropFirst().split(separator: " ")
        guard let first = parts.first,
              let command = SlashCommand(rawValue: String(first)) else {
            return nil
        }

        return (command, parts.dropFirst().map(String.init))
    }
}
```

## Files to Create

```
Sources/ChatCLI/
├── Features/
│   ├── PlanMode.swift
│   ├── SessionManager.swift
│   ├── ContextManager.swift
│   ├── SlashCommands.swift
│   └── TodoManager.swift
├── Tools/
│   ├── TodoWriteTool.swift
│   ├── WebFetchTool.swift
│   ├── EnterPlanModeTool.swift
│   ├── ExitPlanModeTool.swift
│   └── AskUserQuestionTool.swift
├── Views/
│   ├── PlanModeView.swift
│   └── TodoListView.swift
```

## Verification

```bash
swift run ChatCLI
# /help should show commands
# /save should persist session
# /load should restore session
# Plan mode should work end-to-end
```

## Success Criteria
- [ ] Plan mode flow complete
- [ ] Todo management works
- [ ] Sessions save/load correctly
- [ ] Context trimming works
- [ ] Slash commands parsed
- [ ] All tools integrated
