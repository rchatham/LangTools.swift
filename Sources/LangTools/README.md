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

## LangToolchain

`LangToolchain` provides a unified interface for managing and routing requests to multiple LLM providers. It enables you to register different AI services and automatically routes requests to the appropriate provider based on the request type.

### Overview

When building applications that need to work with multiple LLM providers (OpenAI, Anthropic, Gemini, etc.), `LangToolchain` simplifies the process by:
- Managing multiple LangTools provider instances
- Automatically routing requests to the correct provider
- Providing a single interface for both regular and streaming requests

### Basic Usage

```swift
import LangTools
import OpenAI
import Anthropic

// Create a toolchain
var toolchain = LangToolchain()

// Register providers
toolchain.register(OpenAI(apiKey: "your-openai-key"))
toolchain.register(Anthropic(apiKey: "your-anthropic-key"))

// Perform requests - automatically routed to the correct provider
let openAIRequest = OpenAI.ChatCompletionRequest(
    model: .gpt4,
    messages: [Message(role: .user, content: "Hello!")]
)
let response = try await toolchain.perform(request: openAIRequest)

// Anthropic requests are also automatically routed
let anthropicRequest = Anthropic.MessageRequest(
    model: .claude35Sonnet_latest,
    messages: [Anthropic.Message(role: .user, content: "Hello!")]
)
let anthropicResponse = try await toolchain.perform(request: anthropicRequest)
```

### Registration

Register LangTools providers using the `register` method:

```swift
var toolchain = LangToolchain()

// Register individual providers
toolchain.register(OpenAI(apiKey: "your-openai-key"))
toolchain.register(Anthropic(apiKey: "your-anthropic-key"))
toolchain.register(XAI(apiKey: "your-xai-key"))
toolchain.register(Gemini(apiKey: "your-gemini-key"))
toolchain.register(Ollama()) // Ollama doesn't require an API key
```

You can also initialize with pre-registered providers:

```swift
let toolchain = LangToolchain(langTools: [
    "OpenAI": OpenAI(apiKey: "your-openai-key"),
    "Anthropic": Anthropic(apiKey: "your-anthropic-key")
])
```

### Retrieving Specific Providers

Access a specific registered provider using `langTool(_:)`:

```swift
if let openai = toolchain.langTool(OpenAI.self) {
    // Use OpenAI-specific features
    let audioRequest = OpenAI.AudioSpeechRequest(
        model: .tts_1_hd,
        input: "Hello!",
        voice: .alloy
    )
    let audioData: Data = try await openai.perform(request: audioRequest)
}
```

### Streaming Requests

`LangToolchain` supports streaming responses:

```swift
let request = OpenAI.ChatCompletionRequest(
    model: .gpt4,
    messages: [Message(role: .user, content: "Write a story")],
    stream: true
)

for try await chunk in toolchain.stream(request: request) {
    if let text = chunk.choices[0].delta?.content {
        print(text, terminator: "")
    }
}
```

### Error Handling

`LangToolchain` throws `LangToolchainError.toolchainCannotHandleRequest` when no registered provider can handle a request:

```swift
do {
    let response = try await toolchain.perform(request: someRequest)
} catch LangToolchainError.toolchainCannotHandleRequest {
    print("No registered provider can handle this request type")
} catch {
    print("Other error: \(error)")
}
```

### Use Cases

`LangToolchain` is particularly useful for:

1. **Multi-Provider Applications**: Applications that need to support multiple LLM providers
2. **Provider Abstraction**: Abstracting away the specific provider implementation details
3. **Dynamic Provider Selection**: Routing requests based on user preferences or configuration
4. **Fallback Strategies**: Implementing fallback logic when a provider is unavailable

## Additional Resources

For implementation examples, see:
- [OpenAI Module Documentation](Sources/OpenAI/README.md)
- [Anthropic Module Documentation](Sources/Anthropic/README.md)
- [Agents Documentation](Sources/Agents/README.md)
