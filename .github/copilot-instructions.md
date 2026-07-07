# Copilot Instructions for LangTools.swift

## Project Overview

LangTools is a Swift framework for working with Large Language Models (LLMs) and AI services. It provides a unified interface for multiple AI providers and includes tools for building agents and specialized AI assistants.

### Architecture

The project follows a modular architecture with these key components:

- **LangTools Core**: Foundation protocols and utilities for LLM interactions
- **Provider Modules**: OpenAI, Anthropic, X.AI (XAI), Google Gemini, and Ollama implementations
- **Agents Module**: Framework for building specialized AI assistants with tools and delegation
- **ChatCLI**: Command-line interface executable for testing

### Module Structure

```
Sources/
├── LangTools/      # Core protocols and utilities
├── Agents/         # Agent framework
├── OpenAI/         # OpenAI implementation
├── Anthropic/      # Anthropic implementation
├── XAI/            # X.AI implementation
├── Gemini/         # Google Gemini implementation
├── Ollama/         # Ollama implementation
└── ChatCLI/        # CLI executable
```

## Build and Test Commands

### Building
```bash
swift build -v
```

### Testing
```bash
swift test -v
```

### Using Docker (multi-version testing)
```bash
make docker-test              # Test with Swift 5.9 (default)
make docker-test-all          # Test with Swift 5.9, 5.10, and 6.0
make docker-swift-5-10        # Test with specific Swift version
```

## Platform Support

- **macOS**: 14.0+
- **iOS**: 16.0+
- **watchOS**: 8.0+
- **Swift**: 5.9+

## Code Style and Conventions

### File Headers
All Swift files should include a standard header:
```swift
//
//  FileName.swift
//  LangTools
//
//  Created by [Author] on [Date].
//
```

### Protocol Design
- Use protocol-oriented design for extensibility
- Define associated types for type-safe implementations
- Provide protocol extensions for common functionality
- Use `any` keyword for existential types when needed

### Naming Conventions
- Protocols: Use descriptive names like `LangTools`, `LangToolsRequest`, `LangToolsMessage`
- Associated types: Use clear names that indicate their purpose (e.g., `Model`, `ErrorResponse`)
- Properties: Use clear, descriptive names in camelCase
- Methods: Follow Swift API Design Guidelines

### Async/Await
- Prefer async/await over completion handlers for new code
- Use `AsyncThrowingStream` for streaming responses
- Support both async and completion-based APIs where appropriate

### Error Handling
- Define specific error types conforming to `Error`
- Use `LangToolsError` enum for framework-level errors
- Throw descriptive errors with context
- Handle errors gracefully, especially in streaming

## Key Protocols and Patterns

### LangTools Protocol
The main protocol for LLM service implementations:
- `perform(request:)`: Execute synchronous requests
- `stream(request:)`: Handle streaming responses
- `chatRequest(model:messages:tools:)`: Create chat requests with tool support

### Request Types
- `LangToolsRequest`: Base protocol for all requests
- `LangToolsChatRequest`: Chat-specific requests
- `LangToolsStreamableRequest`: Requests supporting streaming

### Message Handling
- Use `LangToolsMessage` protocol for messages
- Support different roles: system, user, assistant, tool
- Handle content as text, tool calls, or complex structures

### Tool Integration
- Define tools using `LangToolsTool` protocol
- Provide JSON schemas for tool parameters
- Implement callbacks for tool execution
- Support tool event handling

## Testing Guidelines

### Test Structure
- Unit tests are in `Tests/` directory
- Each module has its own test target
- Use `TestUtils` for shared testing utilities
- Mock responses are stored in `Tests/TestUtils/Resources/`

### Writing Tests
- Test protocol conformance
- Verify request/response encoding/decoding
- Test streaming functionality
- Mock network calls to avoid external dependencies
- Test error cases and edge cases

### Running Tests
```bash
swift test -v                           # All tests
swift test --filter LangToolsTests      # Specific test target
```

## Dependencies and Package Structure

### Swift Package Manager
- Defined in `Package.swift`
- Modular product structure allows importing specific components
- Provider modules depend on core LangTools module
- Test targets use TestUtils for shared testing infrastructure

### Adding Dependencies
- Minimize external dependencies
- Document why new dependencies are needed
- Ensure compatibility with supported platforms
- Update Package.swift with proper version constraints

## Common Tasks

### Adding a New LLM Provider
1. Create a new module in `Sources/[ProviderName]/`
2. Implement the `LangTools` protocol
3. Define provider-specific request/response types
4. Add tests in `Tests/[ProviderName]Tests/`
5. Update `Package.swift` with new target
6. Add documentation in `Sources/[ProviderName]/README.md`

### Adding a New Tool
1. Conform to `LangToolsTool` protocol
2. Define tool schema with parameters
3. Implement callback function
4. Test tool execution and error handling
5. Document tool usage

### Implementing Streaming
1. Conform request to `LangToolsStreamableRequest`
2. Implement `decodeStream` method
3. Handle partial responses and buffer management
4. Return `AsyncThrowingStream` from stream method
5. Test streaming with mock data

## Important Notes

### Compatibility
- Use `#if canImport(FoundationNetworking)` for Linux support
- Handle platform-specific code appropriately
- Test with multiple Swift versions (5.9, 5.10, 6.0)

### Security
- Never commit API keys or secrets
- Use environment variables for sensitive data
- Validate and sanitize all inputs
- Handle errors without exposing sensitive information

### Documentation
- Each module should have a README.md
- Document public APIs with doc comments
- Provide usage examples
- Keep documentation up-to-date with code changes

### Resources
- README files can be included as package resources
- Use `.process("README.md")` in Package.swift
- Test resources go in `Tests/TestUtils/Resources/`

## Git Workflow

### Ignored Files
- `.DS_Store`, `/.build`, `build/`, `DerivedData/`
- `xcuserdata/`, `.swiftpm/`
- `.claude/`, `CLAUDE.md` (Claude Code local settings)
- `.netrc` (credentials)

### Commit Messages
- Use clear, descriptive commit messages
- Reference issue numbers when applicable
- Group related changes together

## Additional Resources

- Main README: `/README.md`
- Module READMEs: `Sources/[ModuleName]/README.md`
- Examples: `Examples/LangTools_Example/`
- Docker setup: `DOCKER.md`
