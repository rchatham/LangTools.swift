# Phase 5: Agent System

## Goal
Implement agent spawning and delegation like Claude Code's Task tool.

## Agent Types

```swift
enum AgentType: String, CaseIterable {
    case explore    // Codebase exploration, read-only tools
    case plan       // Architecture planning, read-only tools
    case general    // Full capabilities
    case bash       // Command execution specialist

    var availableTools: [String] {
        switch self {
        case .explore:
            return ["Read", "Glob", "Grep"]
        case .plan:
            return ["Read", "Glob", "Grep"]
        case .general:
            return ["Read", "Write", "Edit", "Bash", "Glob", "Grep"]
        case .bash:
            return ["Bash"]
        }
    }

    var systemPrompt: String {
        switch self {
        case .explore:
            return AgentPrompts.explore
        case .plan:
            return AgentPrompts.plan
        case .general:
            return AgentPrompts.general
        case .bash:
            return AgentPrompts.bash
        }
    }
}
```

## TaskTool

Spawns background agents:

```swift
struct TaskTool: LangToolsTool {
    static let name = "Task"
    static let description = "Launch specialized agents for complex tasks"

    struct Parameters: Codable {
        let description: String
        let prompt: String
        let subagent_type: String
        let run_in_background: Bool?
    }

    static func execute(parameters: Parameters) async throws -> String {
        let agentType = AgentType(rawValue: parameters.subagent_type) ?? .general

        let agent = TaskManager.shared.spawn(
            type: agentType,
            prompt: parameters.prompt
        )

        if parameters.run_in_background == true {
            return "Agent started in background. ID: \(agent.id)"
        } else {
            return try await agent.waitForCompletion()
        }
    }
}
```

## TaskManager

Manages agent lifecycle:

```swift
actor TaskManager {
    static let shared = TaskManager()

    private var agents: [UUID: AgentTask] = [:]
    private var results: [UUID: String] = [:]

    func spawn(type: AgentType, prompt: String) -> AgentTask {
        let agent = AgentTask(type: type, prompt: prompt)
        agents[agent.id] = agent

        Task {
            do {
                let result = try await agent.run()
                results[agent.id] = result
            } catch {
                results[agent.id] = "Error: \(error)"
            }
        }

        return agent
    }

    func getResult(_ id: UUID) async -> String? {
        return results[id]
    }

    func cancel(_ id: UUID) {
        agents[id]?.cancel()
    }
}
```

## AgentTask

Individual agent instance:

```swift
class AgentTask: Identifiable {
    let id = UUID()
    let type: AgentType
    let prompt: String

    private var task: Task<String, Error>?
    private var isCancelled = false

    func run() async throws -> String {
        // Create agent-specific message service
        let messageService = MessageService()

        // Set up with agent's system prompt
        messageService.systemPrompt = type.systemPrompt

        // Execute the prompt
        try await messageService.performMessageCompletionRequest(
            message: prompt,
            tools: type.availableTools
        )

        return messageService.lastResponse
    }

    func cancel() {
        isCancelled = true
        task?.cancel()
    }
}
```

## Agent Prompts

```swift
enum AgentPrompts {
    static let explore = """
    You are an exploration agent. Your job is to understand codebases.
    You have access to: Read, Glob, Grep
    Focus on finding patterns, architecture, and key files.
    Return concise summaries of what you find.
    """

    static let plan = """
    You are a planning agent. Your job is to design implementations.
    You have access to: Read, Glob, Grep
    Analyze existing patterns and propose solutions.
    Return structured plans with specific files and changes.
    """

    static let general = """
    You are a general-purpose agent. You can perform any task.
    You have full access to all tools.
    Complete the task efficiently and thoroughly.
    """

    static let bash = """
    You are a command execution specialist.
    You only have access to: Bash
    Execute commands carefully and return results.
    """
}
```

## Files to Create

```
Sources/ChatCLI/
├── Agents/
│   ├── TaskTool.swift
│   ├── TaskManager.swift
│   ├── AgentTask.swift
│   ├── AgentType.swift
│   └── AgentPrompts.swift
├── Views/
│   └── AgentEventView.swift
```

## Verification

```bash
swift run ChatCLI
# Ask: "Explore the codebase structure"
# Should spawn explore agent
# Should show progress
# Should integrate results
```

## Success Criteria
- [ ] TaskTool spawns agents correctly
- [ ] TaskManager handles lifecycle
- [ ] All agent types work
- [ ] Background execution works
- [ ] Cancellation works
- [ ] Results integrate properly
