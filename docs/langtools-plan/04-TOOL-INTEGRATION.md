# Phase 4: Tool Integration

## Goal
Connect tools to the chat interface with real-time feedback and proper event handling.

## Tool Execution Flow

```
User Message
    ↓
LLM Response with tool_use
    ↓
ToolExecutor.execute()
    ↓ (UI shows "Running: Bash...")
Tool callback executes
    ↓
Result captured
    ↓ (UI shows tool result - collapsible)
LLM continues with tool_result
    ↓
Final response displayed
```

## ToolExecutor

Central execution engine:

```swift
actor ToolExecutor {
    private var registry: ToolRegistry
    private var isExecuting: Bool = false
    private var currentTask: Task<String, Error>?

    func execute(_ toolCall: ToolCall) async throws -> String {
        isExecuting = true
        defer { isExecuting = false }

        // Notify UI of tool start
        await MainActor.run {
            ChatViewModel.shared.currentTool = toolCall.name
        }

        // Execute tool
        let result = try await registry.execute(toolCall)

        // Notify UI of completion
        await MainActor.run {
            ChatViewModel.shared.currentTool = nil
        }

        return result
    }

    func cancel() {
        currentTask?.cancel()
    }
}
```

## Tool Events

Using LangToolsToolEvent for UI feedback:

```swift
enum ToolEvent {
    case started(name: String, parameters: [String: Any])
    case progress(message: String)
    case completed(result: String)
    case failed(error: Error)
    case cancelled
}
```

## ToolExecutionView

Shows running tool status:

```swift
struct ToolExecutionView: View {
    let toolName: String
    let isExecuting: Bool

    var body: some View {
        if isExecuting {
            HStack {
                Text("Running: ")
                Text(toolName).foregroundColor(.yellow)
                Text("...")
            }
        }
    }
}
```

## Tool Approval Workflow

For dangerous operations (file writes, bash commands):

```swift
enum ToolApproval {
    case autoApprove      // Safe operations
    case requireApproval  // File writes, deletes
    case deny             // Blocked operations
}

func shouldApprove(_ tool: ToolCall) -> ToolApproval {
    switch tool.name {
    case "Read", "Glob", "Grep":
        return .autoApprove
    case "Write", "Edit", "Bash":
        return .requireApproval
    default:
        return .deny
    }
}
```

## Timeout Handling

```swift
func executeWithTimeout(_ tool: ToolCall, timeout: Duration) async throws -> String {
    try await withThrowingTaskGroup(of: String.self) { group in
        group.addTask {
            try await self.execute(tool)
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw ToolError.timeout
        }

        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
```

## Files to Create

```
Sources/ChatCLI/
├── Tools/
│   └── ToolExecutor.swift
├── Views/
│   └── ToolExecutionView.swift
├── ViewModels/
│   └── ToolExecutionState.swift
```

## Verification

```bash
swift run ChatCLI
# Ask: "List files in the current directory"
# Should see tool execution status
# Should see formatted output
# Should handle errors gracefully
```

## Success Criteria
- [ ] ToolExecutor handles all tool calls
- [ ] UI shows tool execution status
- [ ] Tool results display correctly
- [ ] Approval workflow works
- [ ] Timeout and cancellation work
- [ ] Error recovery is graceful
