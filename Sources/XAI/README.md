# X.AI

Swift interface for X.AI's Grok models, part of the LangTools framework. The X.AI module uses OpenAI's request and response formats, allowing for easy integration with existing OpenAI-style code.

## Key Differences from OpenAI

1. **Model Selection**:
```swift
// Available X.AI models
.grok           // "grok-2-1212"
.grokVision    // "grok-2-vision-1212"
```

2. **Initialization**:
```swift
let xai = XAI(apiKey: "your-api-key")
```

3. **Base URL**:
- Default base URL is `https://api.x.ai/v1/`
- Uses X.AI's API infrastructure

4. **Request Limitations**:
- Some OpenAI-specific parameters may not be available
- Vision features are only available with the grokVision model

## Basic Usage

Since X.AI uses OpenAI's request format, you can use the same request structure:

```swift
let request = OpenAI.ChatCompletionRequest(
    model: XAI.Model.grok,  // Use Grok model
    messages: [
        Message(role: .user, content: "Tell me about AI.")
    ]
)

let response = try await xai.perform(request: request)
```

## Error Handling

X.AI errors have their own type:
```swift
do {
    let response = try await xai.perform(request: request)
} catch let error as XAIErrorResponse {
    print("X.AI API error:", error.error.message)
}
```

## For More Information

Refer to the [OpenAI Module Documentation](Sources/OpenAI/README.md) for detailed information about:
- Chat completion requests
- Streaming
- Message formats
- Response handling
- Best practices

The same patterns apply to X.AI, just use Grok models and initialization.

See also:
- [X.AI Platform Documentation](https://platform.x.ai/docs)
- [Grok API Reference](https://platform.x.ai/docs/api-reference)
