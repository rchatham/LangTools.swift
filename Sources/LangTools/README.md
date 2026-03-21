# LangTools Core

Core protocols and utilities for working with Large Language Models (LLMs). This module provides the foundation for all LangTools implementations.

## Key Protocols

### LangTools

The primary protocol for LLM service implementations:

```swift
public protocol LangTools {
    associatedtype Model: RawRepresentable
    associatedtype ErrorResponse: Codable & Error
    
    func perform<Request: LangToolsRequest>(request: Request) async throws -> Request.Response
    func stream<Request: LangToolsStreamableRequest>(request: Request) -> AsyncThrowingStream<Request.Response, Error>
    
    static var requestValidators: [(any LangToolsRequest) -> Bool] { get }
    static func chatRequest(model: Model, messages: [any LangToolsMessage], tools: [any LangToolsTool]?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> any LangToolsChatRequest
}
```

### Request Types

#### LangToolsRequest
Base protocol for all requests:
```swift
public protocol LangToolsRequest: Encodable {
    associatedtype Response: Decodable
    associatedtype LangTool: LangTools
    static var endpoint: String { get }
    static var httpMethod: HTTPMethod { get }
}
```

#### LangToolsChatRequest
Protocol for chat-based interactions:
```swift
public protocol LangToolsChatRequest: LangToolsRequest where Response: LangToolsChatResponse {
    associatedtype Message: LangToolsMessage
    var messages: [Message] { get set }
}
```

#### LangToolsStreamableRequest
Protocol for streaming responses:
```swift
public protocol LangToolsStreamableRequest: LangToolsRequest where Response: LangToolsStreamableResponse {
    var stream: Bool? { get set }
}
```

### Message Types

#### LangToolsMessage
Protocol for chat messages:
```swift
public protocol LangToolsMessage: Codable {
    associatedtype Role: LangToolsRole
    associatedtype Content: LangToolsContent
    var role: Role { get }
    var content: Content { get }
}
```

#### LangToolsRole
Protocol for message roles:
```swift
public protocol LangToolsRole: Codable, Hashable {
    var isAssistant: Bool { get }
    var isUser: Bool { get }
    var isSystem: Bool { get }
    var isTool: Bool { get }
}
```

### Tool Integration

#### LangToolsTool
Protocol for tool definitions:
```swift
public protocol LangToolsTool: Codable {
    associatedtype ToolSchema: LangToolsToolSchema
    var name: String { get }
    var description: String? { get }
    var tool_schema: ToolSchema { get }
    var callback: (([String:JSON]) async throws -> String?)? { get }
}
```

## LangToolchain

`LangToolchain` is a unified interface for managing multiple LLM providers. It allows you to register different AI services (OpenAI, Anthropic, XAI, Gemini, Ollama) and automatically routes requests to the appropriate provider based on the request type.

### Overview

The `LangToolchain` provides:
- **Provider Registration**: Register multiple LLM providers in a single toolchain
- **Automatic Request Routing**: Requests are automatically routed to the provider that can handle them
- **Unified API**: Use `perform` and `stream` methods regardless of which provider handles the request
- **Provider Access**: Retrieve specific providers when needed for direct access

### Basic Usage

#### Initialize and Register Providers

```swift
import LangTools
import OpenAI
import Anthropic
import Gemini

// Create a toolchain instance
var langToolchain = LangToolchain()

// Register your AI providers
langToolchain.register(OpenAI(apiKey: "your-openai-key"))
langToolchain.register(Anthropic(apiKey: "your-anthropic-key"))
langToolchain.register(Gemini(apiKey: "your-gemini-key"))
```

#### Perform Requests

The toolchain automatically routes requests to the correct provider:

```swift
// OpenAI request - automatically routed to OpenAI provider
let openAIRequest = OpenAI.ChatCompletionRequest(
    model: .gpt4,
    messages: [OpenAI.Message(role: .user, content: "Hello!")]
)
let openAIResponse = try await langToolchain.perform(request: openAIRequest)

// Anthropic request - automatically routed to Anthropic provider
let anthropicRequest = Anthropic.MessageRequest(
    model: .claude35Sonnet_latest,
    messages: [Anthropic.Message(role: .user, content: "Hello!")]
)
let anthropicResponse = try await langToolchain.perform(request: anthropicRequest)
```

#### Streaming Responses

The toolchain supports streaming for providers that implement it:

```swift
let request = OpenAI.ChatCompletionRequest(
    model: .gpt4,
    messages: [OpenAI.Message(role: .user, content: "Write a story")],
    stream: true
)

for try await chunk in langToolchain.stream(request: request) {
    if let text = chunk.choices.first?.delta?.content {
        print(text, terminator: "")
    }
}
```

#### Accessing Specific Providers

When you need direct access to a specific provider:

```swift
// Get a specific provider from the toolchain
if let openai = langToolchain.langTool(OpenAI.self) {
    // Use OpenAI-specific features
    let audioRequest = OpenAI.AudioSpeechRequest(
        model: .tts_1_hd,
        input: "Hello, world!",
        voice: .alloy
    )
    let audioData = try await openai.perform(request: audioRequest)
}
```

### Error Handling

The toolchain throws `LangToolchainError` when no registered provider can handle a request:

```swift
do {
    let response = try await langToolchain.perform(request: request)
} catch LangToolchainError.toolchainCannotHandleRequest {
    print("No provider registered can handle this request")
} catch {
    print("Error: \(error)")
}
```

### Use with Agents

The toolchain works seamlessly with the Agents framework:

```swift
import Agents

// Get a specific provider for agent context
if let anthropic = langToolchain.langTool(Anthropic.self) {
    let context = AgentContext(
        langTool: anthropic,
        model: .claude35Sonnet_latest,
        messages: messages,
        eventHandler: { event in
            // Handle agent events
        }
    )
    let result = try await myAgent.execute(context: context)
}
```

### Best Practices

1. **Register providers at startup**: Initialize your toolchain and register all providers during app initialization
2. **Use automatic routing**: Let the toolchain route requests automatically for cleaner code
3. **Access providers directly when needed**: Use `langTool(_:)` for provider-specific features like audio
4. **Handle routing errors**: Always catch `LangToolchainError.toolchainCannotHandleRequest`
5. **Consider provider availability**: Some providers may not require API keys (e.g., local Ollama)

## Error Handling

The framework provides standard error types:

```swift
public enum LangToolsError: Error {
    case invalidData
    case streamParsingFailure
    case invalidURL
    case requestFailed
    case invalidContentType
    case jsonParsingFailure(Error)
    case responseUnsuccessful(statusCode: Int, Error?)
    case apiError(Codable & Error)
    case failedToDecodeStream(buffer: String, error: Error)
}
```

## JSON Utilities

The framework includes a flexible JSON type for handling dynamic data:

```swift
public enum JSON: Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSON])
    case array([JSON])
    case null
    
    // Convenience accessors
    var stringValue: String?
    var doubleValue: Double?
    var intValue: Int?
    var boolValue: Bool?
    var arrayValue: [JSON]?
    var objectValue: [String: JSON]?
}
```

## Best Practices

1. **Request Validation**
   - Implement `requestValidators` to verify request compatibility
   - Check model support and request parameters
   - Validate before sending to the API

2. **Error Handling**
   - Use specific error types for better error handling
   - Provide detailed error messages
   - Handle network and parsing errors appropriately

3. **Streaming**
   - Implement proper buffer management
   - Handle partial responses correctly
   - Maintain state during streaming

4. **Tool Integration**
   - Define clear tool schemas
   - Implement robust argument parsing
   - Handle tool errors gracefully

5. **Response Processing**
   - Validate response data
   - Handle different content types
   - Process streaming chunks efficiently

## Common Patterns

### Message Construction
```swift
extension LangTools {
    public func systemMessage(_ message: String) -> any LangToolsMessage {
        LangToolsMessageImpl(role: .system, string: message)
    }
    
    public func assistantMessage(_ message: String) -> any LangToolsMessage {
        LangToolsMessageImpl(role: .assistant, string: message)
    }
    
    public func userMessage(_ message: String) -> any LangToolsMessage {
        LangToolsMessageImpl(role: .user, string: message)
    }
}
```

### Tool Definition
```swift
let tool = Tool(
    name: "my_tool",
    description: "Tool description",
    tool_schema: .init(
        properties: [
            "param": .init(
                type: "string",
                description: "Parameter description"
            )
        ],
        required: ["param"]
    ),
    callback: { args in
        // Tool implementation
        return "Result"
    }
)
```

## Additional Resources

For implementation examples, see:
- [OpenAI Module Documentation](Sources/OpenAI/README.md)
- [Anthropic Module Documentation](Sources/Anthropic/README.md)
- [Agents Documentation](Sources/Agents/README.md)
