# Anthropic

Swift interface for Anthropic's Claude models, part of the LangTools framework.

## Features

- 🤖 Chat completions with Claude models
- 🔄 Streaming support
- 🛠️ Tool calling and function integration
- 📝 System messages and instructions
- 🔍 Multi-part message content

## Available Models

```swift
// Claude 3
.claude3Opus_latest          // "claude-3-opus-latest"
.claude3Opus_20240229       // "claude-3-opus-20240229"
.claude35Sonnet_latest      // "claude-3-5-sonnet-latest"
.claude35Sonnet_20241022    // "claude-3-5-sonnet-20241022"
.claude35Sonnet_20240620    // "claude-3-5-sonnet-20240620"
.claude3Sonnet_20240229     // "claude-3-sonnet-20240229"
.claude35Haiku_latest       // "claude-3-5-haiku-latest"
.claude35Haiku_20241022     // "claude-3-5-haiku-20241022"
.claude3Haiku_20240307      // "claude-3-haiku-20240307"
```

## Basic Usage

### Initialize Anthropic Client

```swift
let anthropic = Anthropic(apiKey: "your-api-key")
```

### Chat Completions

Basic chat completion:
```swift
let request = Anthropic.MessageRequest(
    model: .claude35Sonnet_latest,
    messages: [
        Message(role: .user, content: "Tell me about AI safety.")
    ],
    system: "You are a knowledgeable AI researcher."
)

let response = try await anthropic.perform(request: request)
print(response.message?.content.text ?? "")
```

Streaming chat completion:
```swift
let request = Anthropic.MessageRequest(
    model: .claude35Sonnet_latest,
    messages: [
        Message(role: .user, content: "Write a story about space exploration.")
    ],
    stream: true
)

for try await chunk in anthropic.stream(request: request) {
    if let text = chunk.delta?.content {
        print(text, terminator: "")
    }
}
```

### Tool Calling

```swift
let searchTool = Anthropic.Tool(
    name: "search_database",
    description: "Search through scientific papers",
    tool_schema: .init(
        properties: [
            "query": .init(
                type: "string",
                description: "Search query"
            ),
            "limit": .init(
                type: "integer",
                description: "Maximum results to return"
            )
        ],
        required: ["query"]
    ),
    callback: { args in
        guard let query = args["query"]?.stringValue else {
            throw AgentError("Missing query")
        }
        // Implement search logic
        return "Search results for: \(query)"
    }
)

let request = Anthropic.MessageRequest(
    model: .claude35Sonnet_latest,
    messages: [
        Message(role: .user, content: "Find papers about quantum computing.")
    ],
    tools: [searchTool]
)

let response = try await anthropic.perform(request: request)
```

### Multi-Part Messages

Claude supports messages with multiple content parts:

```swift
let message = Message(
    role: .user,
    content: .array([
        .text(TextContent(text: "Analyze this image:")),
        .image(ImageContent(source: .init(
            data: imageBase64String,
            media_type: .jpeg
        )))
    ])
)

let request = Anthropic.MessageRequest(
    model: .claude35Sonnet_latest,
    messages: [message]
)
```

## Advanced Features

### System Messages

Set context and behavior with system messages:

```swift
let request = Anthropic.MessageRequest(
    model: .claude35Sonnet_latest,
    messages: [
        Message(role: .user, content: "Explain quantum entanglement.")
    ],
    system: """
    You are a physics professor explaining complex concepts to undergraduate students.
    Use analogies and clear explanations.
    Avoid excessive technical jargon.
    """
)
```

### Request Options

Available options for message requests:

```swift
let request = Anthropic.MessageRequest(
    model: .claude35Sonnet_latest,
    messages: messages,
    max_tokens: 1000,          // Maximum response length
    stop_sequences: ["END"],   // Custom stop sequences
    temperature: 0.7,          // Randomness (0.0 to 1.0)
    top_k: 10,                // Top-k sampling
    top_p: 0.9,               // Nucleus sampling
    metadata: Metadata(        // Request metadata
        user_id: "user123"
    )
)
```

## Error Handling

Anthropic errors are typed for better handling:

```swift
do {
    let response = try await anthropic.perform(request: request)
} catch let error as AnthropicErrorResponse {
    switch error.error.type {
    case .invalidRequestError:
        print("Invalid request:", error.error.message)
    case .authenticationError:
        print("Authentication failed:", error.error.message)
    case .permissionError:
        print("Permission denied:", error.error.message)
    case .apiError:
        print("API error:", error.error.message)
    default:
        print("Error:", error.error.message)
    }
}
```

## Best Practices

1. **Model Selection**: 
   - Use Claude 3 Opus for complex tasks requiring deep understanding
   - Use Claude 3.5 Sonnet for general purpose tasks
   - Use Claude 3.5 Haiku for quick, simple responses

2. **System Messages**:
   - Keep system messages focused and specific
   - Use them to set context and constraints
   - Avoid contradictory or overly complex instructions

3. **Error Handling**:
   - Always handle potential API errors
   - Implement proper retry logic for transient failures
   - Monitor rate limits and token usage

4. **Tool Integration**:
   - Define clear, focused tool capabilities
   - Provide detailed descriptions for tools
   - Handle tool errors gracefully

5. **Performance**:
   - Use streaming for long responses
   - Implement proper connection management
   - Monitor and optimize token usage

## Additional Resources

- [Anthropic Claude API Documentation](https://docs.anthropic.com/claude/reference/)
- [Claude System Prompting Guide](https://docs.anthropic.com/claude/docs/system-prompting)
- [Claude Best Practices](https://docs.anthropic.com/claude/docs/best-practices)
