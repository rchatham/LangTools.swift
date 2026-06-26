# Phase 1: Foundation

## Goal
Integrate SwiftTUI and create the application shell while preserving existing functionality.

## Tasks

### 1.1 Add SwiftTUI Dependency
Update Package.swift to include SwiftTUI:

```swift
dependencies: [
    .package(url: "https://github.com/rensbreur/SwiftTUI", branch: "main")
],
```

### 1.2 Update ChatCLI Target
Add SwiftTUI and Agents dependencies to ChatCLI target:

```swift
.executableTarget(
    name: "ChatCLI",
    dependencies: [
        "LangTools",
        "OpenAI",
        "Anthropic",
        "XAI",
        "Gemini",
        "Ollama",
        "Agents",
        .product(name: "SwiftTUI", package: "SwiftTUI")
    ]
),
```

### 1.3 Create Directory Structure
```
Sources/ChatCLI/
├── Views/
├── ViewModels/
├── Tools/
├── Services/
├── App/
```

### 1.4 Implement MainView.swift
Root SwiftTUI view that contains the entire application:

```swift
import SwiftTUI

struct MainView: View {
    @State private var inputText: String = ""

    var body: some View {
        VStack {
            Text("SwiftClaude CLI")
            Text("Press Ctrl+C to exit")
            Spacer()
            TextField("Enter message...", text: $inputText)
        }
    }
}
```

### 1.5 Update main.swift Entry Point
Modify ChatCLI.swift to use SwiftTUI Application:

```swift
import SwiftTUI

@main
struct ChatCLI {
    static func main() async throws {
        Application(rootView: MainView()).start()
    }
}
```

### 1.6 Migrate ANSI Colors
Create SwiftTUI-compatible color utilities that work with the framework.

### 1.7 Create Configuration.swift
Settings management for user preferences:

```swift
struct Configuration {
    var model: Model
    var theme: Theme
    var workingDirectory: String
    // ...
}
```

### 1.8 Environment Detection
Detect working directory, git status, and other context:

```swift
struct Environment {
    static var workingDirectory: String
    static var gitBranch: String?
    static var isGitRepo: Bool
}
```

## Verification

```bash
swift build
# Should compile successfully with SwiftTUI

swift run ChatCLI
# Should show basic TUI window
# Should accept text input
# Should exit cleanly with Ctrl+C
```

## Success Criteria
- [ ] Build completes without errors
- [ ] Application window displays
- [ ] Text input works
- [ ] Ctrl+C exits cleanly
