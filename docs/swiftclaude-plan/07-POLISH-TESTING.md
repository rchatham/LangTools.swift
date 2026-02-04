# Phase 7: Polish & Testing

## Goal
Error handling, theming, comprehensive tests, and final polish.

## Error Handling

### Error Types

```swift
enum ChatCLIError: LocalizedError {
    // Tool errors
    case toolNotFound(name: String)
    case toolExecutionFailed(tool: String, reason: String)
    case toolTimeout(tool: String, timeout: Duration)

    // File system errors
    case fileNotFound(path: String)
    case fileNotReadable(path: String)
    case fileNotWritable(path: String)
    case invalidPath(path: String)

    // Process errors
    case commandFailed(command: String, exitCode: Int, stderr: String)
    case commandTimeout(command: String)

    // Network errors
    case apiKeyMissing(service: String)
    case networkError(underlying: Error)
    case rateLimited(retryAfter: TimeInterval?)

    // Agent errors
    case agentFailed(type: AgentType, reason: String)
    case agentCancelled(id: UUID)

    // Configuration errors
    case invalidConfiguration(key: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .toolNotFound(let name):
            return "Tool '\(name)' not found"
        case .toolExecutionFailed(let tool, let reason):
            return "Tool '\(tool)' failed: \(reason)"
        // ... etc
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .apiKeyMissing(let service):
            return "Run /model to configure \(service) API key"
        case .fileNotFound(let path):
            return "Check if the file exists: \(path)"
        // ... etc
        }
    }
}
```

### Error Display

```swift
struct ErrorView: View {
    let error: ChatCLIError

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Error:").foregroundColor(.red)
                Text(error.localizedDescription)
            }
            if let suggestion = error.recoverySuggestion {
                Text("Suggestion: \(suggestion)")
                    .foregroundColor(.yellow)
            }
        }
    }
}
```

## Theming

### Theme Manager

```swift
struct Theme {
    let name: String
    let userMessageColor: Color
    let assistantMessageColor: Color
    let toolStatusColor: Color
    let errorColor: Color
    let headerColor: Color
    let inputPromptColor: Color
}

class ThemeManager {
    static let shared = ThemeManager()

    @Published var current: Theme = .default

    static let `default` = Theme(
        name: "Default",
        userMessageColor: .green,
        assistantMessageColor: .yellow,
        toolStatusColor: .cyan,
        errorColor: .red,
        headerColor: .blue,
        inputPromptColor: .green
    )

    static let minimal = Theme(
        name: "Minimal",
        userMessageColor: .white,
        assistantMessageColor: .white,
        toolStatusColor: .white,
        errorColor: .red,
        headerColor: .white,
        inputPromptColor: .white
    )
}
```

## Syntax Highlighting

```swift
struct SyntaxHighlighter {
    static func highlight(_ code: String, language: String) -> AttributedString {
        // Simple keyword-based highlighting
        var result = AttributedString(code)

        let keywords: [String: [String]] = [
            "swift": ["func", "var", "let", "struct", "class", "enum", "if", "else", "for", "while"],
            "python": ["def", "class", "if", "else", "for", "while", "import", "from"],
            "javascript": ["function", "const", "let", "var", "if", "else", "for", "while"]
        ]

        guard let langs = keywords[language] else { return result }

        for keyword in langs {
            // Apply highlighting
        }

        return result
    }
}
```

## Progress Indicators

```swift
struct ProgressIndicator: View {
    let message: String
    @State private var frame: Int = 0

    private let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    var body: some View {
        HStack {
            Text(frames[frame])
            Text(message)
        }
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                frame = (frame + 1) % frames.count
            }
        }
    }
}
```

## Diff View

```swift
struct DiffView: View {
    let oldContent: String
    let newContent: String

    var body: some View {
        VStack(alignment: .leading) {
            ForEach(computeDiff(), id: \.self) { line in
                HStack {
                    if line.hasPrefix("+") {
                        Text(line).foregroundColor(.green)
                    } else if line.hasPrefix("-") {
                        Text(line).foregroundColor(.red)
                    } else {
                        Text(line)
                    }
                }
            }
        }
    }

    func computeDiff() -> [String] {
        // Simple line-by-line diff
    }
}
```

## Integration Tests

```swift
final class ChatFlowTests: XCTestCase {
    func testBasicConversation() async throws {
        let vm = ChatViewModel()
        await vm.sendMessage("Hello")

        XCTAssertEqual(vm.messages.count, 2)
        XCTAssertEqual(vm.messages[0].role, .user)
        XCTAssertEqual(vm.messages[1].role, .assistant)
    }

    func testToolExecution() async throws {
        let vm = ChatViewModel()
        await vm.sendMessage("List files in /tmp")

        // Verify tool was called
        XCTAssertTrue(vm.messages.contains { $0.content.contains("GlobTool") })
    }
}

final class ToolChainTests: XCTestCase {
    func testReadWriteEdit() async throws {
        let path = "/tmp/test_\(UUID()).txt"

        // Write
        try await WriteTool.execute(.init(file_path: path, content: "Hello"))

        // Read
        let content = try await ReadTool.execute(.init(file_path: path))
        XCTAssertTrue(content.contains("Hello"))

        // Edit
        try await EditTool.execute(.init(
            file_path: path,
            old_string: "Hello",
            new_string: "World"
        ))

        // Verify
        let edited = try await ReadTool.execute(.init(file_path: path))
        XCTAssertTrue(edited.contains("World"))

        // Cleanup
        try FileManager.default.removeItem(atPath: path)
    }
}
```

## Files to Create

```
Sources/ChatCLI/
├── Errors/
│   └── ChatCLIError.swift
├── Theming/
│   ├── ThemeManager.swift
│   └── Themes.swift
├── Utilities/
│   ├── SyntaxHighlighter.swift
│   ├── DiffView.swift
│   └── ProgressIndicator.swift

Tests/ChatCLITests/
├── Integration/
│   ├── ChatFlowTests.swift
│   ├── ToolChainTests.swift
│   └── AgentTests.swift
```

## User Configuration

```swift
// ~/.swiftclaude/config.json
struct UserConfig: Codable {
    var theme: String = "default"
    var defaultModel: String = "claude-3-sonnet"
    var autoApproveTools: [String] = ["Read", "Glob", "Grep"]
    var historySize: Int = 100
    var shortcuts: [String: String] = [:]
}
```

## Verification

```bash
swift test
# All tests pass

swift run ChatCLI
# Full interactive session works
# Errors display helpfully
# Themes apply correctly
# Syntax highlighting works
```

## Success Criteria
- [ ] Comprehensive error types
- [ ] Helpful error messages with suggestions
- [ ] Theme system works
- [ ] Syntax highlighting for code blocks
- [ ] Diff view for edits
- [ ] Progress indicators
- [ ] All integration tests pass
- [ ] User config loads correctly
