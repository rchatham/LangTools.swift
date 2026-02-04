# Phase 3: Chat Interface

## Goal
Build the SwiftTUI-based chat interface with proper view hierarchy and state management.

## View Hierarchy

```
MainView
├── HeaderView              (1 line: model, cwd, git branch)
├── ChatHistoryView         (flexible: scrollable message list)
│   ├── MessageView[]
│   │   ├── UserMessageView
│   │   ├── AssistantMessageView
│   │   └── ToolResultView
│   └── StreamingView       (when active)
├── StatusBarView           (1 line: tool status, token count)
└── InputView               (1 line: "> " prompt + text)
```

## Component Specifications

### HeaderView
Displays context information:
- Current model name
- Working directory (shortened)
- Git branch (if in repo)

```swift
struct HeaderView: View {
    let model: String
    let workingDirectory: String
    let gitBranch: String?

    var body: some View {
        HStack {
            Text("Model: \(model)")
            Spacer()
            Text(workingDirectory)
            if let branch = gitBranch {
                Text("(\(branch))")
            }
        }
        .foregroundColor(.cyan)
    }
}
```

### ChatHistoryView
Scrollable view of conversation messages:
- Supports user, assistant, and tool messages
- Auto-scrolls to bottom on new messages
- Handles streaming content

### MessageView
Container that routes to appropriate message type:
- UserMessageView: Green "You:" prefix
- AssistantMessageView: Yellow "Assistant:" prefix
- ToolResultView: Collapsible tool output

### InputView
Text input with history:
- ">" prompt
- Up/down arrow for history
- Enter to submit
- Ctrl+C to cancel

### StatusBarView
Shows current operation status:
- "Streaming..." during response
- "Running: BashTool..." during tool execution
- Token count and cost

## ChatViewModel

Central state manager using @MainActor:

```swift
@MainActor
class ChatViewModel: ObservableObject {
    @Published var messages: [Message] = []
    @Published var isStreaming: Bool = false
    @Published var currentTool: String? = nil
    @Published var inputHistory: [String] = []

    func sendMessage(_ text: String) async
    func handleToolExecution(_ tool: String) async
    func cancelOperation()
}
```

## Keyboard Shortcuts

| Key | Action |
|-----|--------|
| Enter | Submit message |
| Up/Down | Navigate input history |
| Ctrl+C | Cancel current operation |
| Ctrl+L | Clear screen |
| Ctrl+D | Exit application |

## Files to Create

```
Sources/ChatCLI/
├── Views/
│   ├── HeaderView.swift
│   ├── ChatHistoryView.swift
│   ├── MessageView.swift
│   ├── UserMessageView.swift
│   ├── AssistantMessageView.swift
│   ├── ToolResultView.swift
│   ├── InputView.swift
│   ├── StatusBarView.swift
│   └── StreamingView.swift
├── ViewModels/
│   └── ChatViewModel.swift
```

## Verification

```bash
swift run ChatCLI
# Should display formatted header
# Should show working directory and git branch
# Should accept and display user input
# Should show styled responses
# Should support input history
```

## Success Criteria
- [ ] All views implemented and styled
- [ ] ChatViewModel manages state
- [ ] Input history works
- [ ] Streaming responses display correctly
- [ ] Keyboard shortcuts function
