# SwiftClaude Implementation Loop

You are implementing Claude Code capabilities for langtools-cli. Execute autonomously until complete.

## Loop Protocol

1. **Read Progress**: Check `docs/swiftclaude-plan/PROGRESS.md` for current state
2. **Identify Next Task**: Find first incomplete item in current phase
3. **Implement**: Write code, tests, and documentation
4. **Verify**: Run `swift build` and relevant tests
5. **Update Progress**: Mark completed items in PROGRESS.md
6. **Commit**: `git add . && git commit -m "feat(swiftclaude): <description>"`
7. **Loop**: Return to step 1

## Phase Order
1. FOUNDATION -> 2. CORE-TOOLS -> 3. CHAT-INTERFACE -> 4. TOOL-INTEGRATION
-> 5. AGENT-SYSTEM -> 6. ADVANCED-FEATURES -> 7. POLISH-TESTING

## Completion Criteria
- All items in PROGRESS.md marked [x]
- `swift build` succeeds
- `swift test` passes
- App launches and responds to input

## Error Recovery
- If build fails: Fix errors, do not proceed until green
- If test fails: Fix test or implementation
- If stuck > 3 attempts: Document blocker in PROGRESS.md, move to next item

## Current Working Directory
/Users/reidchatham/Developer/langtools-cli

## Key Commands
- Build: `swift build`
- Test: `swift test`
- Run: `swift run ChatCLI`

## Key Files Reference

### Package.swift
Add SwiftTUI dependency and update ChatCLI target.

### Sources/ChatCLI/
Main implementation directory. Preserve existing files, add new subdirectories:
- Views/
- ViewModels/
- Tools/
- Services/
- Agents/
- Features/
- Errors/
- Theming/
- Utilities/

### Existing Files to Preserve
- ChatCLI.swift - Entry point (modify for SwiftTUI)
- MessageService.swift - Chat logic (enhance)
- NetworkClient.swift - API handling (keep)
- Model.swift - Model definitions (keep)
- LangToolchain.swift - Provider routing (keep)
- Utilities.swift - Helper functions (keep)
- Message.swift - Message types (keep)
