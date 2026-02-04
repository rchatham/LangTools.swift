# Phase 2: Core Tools

## Goal
Implement all file and shell operation tools following the LangToolsTool protocol pattern.

## Tool Specifications

### ReadTool
Read files with line number support.

**Parameters:**
- `file_path`: String (required) - absolute path to file
- `offset`: Int? - line number to start from (default: 1)
- `limit`: Int? - number of lines to read (default: 2000)

**Returns:** Content with line numbers formatted as "   1\t line content"

**Behavior:**
- Supports text files, images (base64), PDFs, notebooks
- Truncates lines > 2000 characters
- Returns error for directories

### WriteTool
Create or overwrite files.

**Parameters:**
- `file_path`: String (required) - absolute path
- `content`: String (required) - content to write

**Behavior:**
- Creates parent directories if needed
- Overwrites existing files
- Returns success/failure status

### EditTool
Exact string replacement in files.

**Parameters:**
- `file_path`: String (required) - absolute path
- `old_string`: String (required) - exact text to find
- `new_string`: String (required) - replacement text
- `replace_all`: Bool? - replace all occurrences (default: false)

**Behavior:**
- Fails if old_string not found
- Fails if old_string not unique (unless replace_all=true)
- Preserves file permissions

### BashTool
Execute shell commands.

**Parameters:**
- `command`: String (required) - command to execute
- `timeout`: Int? - milliseconds (max: 600000, default: 120000)
- `working_directory`: String? - execution directory
- `run_in_background`: Bool? - async execution

**Behavior:**
- Inherits environment from user shell
- Captures stdout and stderr
- Returns exit code

### GlobTool
Pattern-based file matching.

**Parameters:**
- `pattern`: String (required) - glob pattern (e.g., "**/*.swift")
- `path`: String? - base directory (default: cwd)

**Returns:** File paths sorted by modification time (newest first)

### GrepTool
Regex-based content search.

**Parameters:**
- `pattern`: String (required) - regex pattern
- `path`: String? - directory to search (default: cwd)
- `glob`: String? - file filter pattern
- `type`: String? - file type filter (swift, py, js, etc.)
- `output_mode`: String? - "content", "files_with_matches", "count"
- `context_lines`: Int? - lines before/after matches (-A, -B, -C)
- `case_insensitive`: Bool? - case insensitive search (-i)

**Returns:** Matching content or file paths based on output_mode

## Implementation Pattern

Each tool follows the LangToolsTool protocol:

```swift
struct ReadTool: LangToolsTool {
    static let name = "Read"
    static let description = "Read file contents with line numbers"

    struct Parameters: Codable {
        let file_path: String
        let offset: Int?
        let limit: Int?
    }

    static func execute(parameters: Parameters) async throws -> String {
        // Implementation
    }
}
```

## Files to Create

```
Sources/ChatCLI/
├── Tools/
│   ├── ToolRegistry.swift
│   ├── ReadTool.swift
│   ├── WriteTool.swift
│   ├── EditTool.swift
│   ├── BashTool.swift
│   ├── GlobTool.swift
│   └── GrepTool.swift
├── Services/
│   ├── FileSystemService.swift
│   └── ProcessService.swift

Tests/ChatCLITests/
├── Tools/
│   ├── ReadToolTests.swift
│   ├── WriteToolTests.swift
│   ├── EditToolTests.swift
│   ├── BashToolTests.swift
│   ├── GlobToolTests.swift
│   └── GrepToolTests.swift
```

## Verification

```bash
swift test --filter ChatCLITests
# All tool tests should pass

swift run ChatCLI
# Tools should be registered and executable
```

## Success Criteria
- [ ] All 6 tools implemented
- [ ] ToolRegistry manages registration
- [ ] FileSystemService abstracts file ops
- [ ] ProcessService handles shell execution
- [ ] Unit tests pass for all tools
