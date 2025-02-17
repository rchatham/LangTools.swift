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
public enum LangToolError: Error {
    case invalidData
    case streamParsingFailure
    case invalidURL
    case requestFailed
    case invalidContentType
    case jsonParsingFailure(Error)
    case responseUnsuccessful(statusCode: Int, Error?)
    case apiError(Codable & Error)
    case failiedToDecodeStream(buffer: String, error: Error)
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
