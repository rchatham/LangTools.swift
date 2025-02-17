# Gemini

Swift interface for Google's Gemini models, part of the LangTools framework. The Gemini module uses OpenAI's request and response formats, allowing for easy integration with existing OpenAI-style code.

## Key Differences from OpenAI

1. **Model Selection**:
```swift
// Available Gemini models
.gemini2Flash           // "gemini-2.0-flash-exp"
.gemini15Flash          // "gemini-1.5-flash"
.gemini15Flash8B        // "gemini-1.5-flash-8b"
.gemini15Pro            // "gemini-1.5-pro"
.gemini10Pro            // "gemini-1.0-pro"

// Versioned models
.gemini15FlashLatest    // "gemini-1.5-flash-latest"
.gemini15Flash001       // "gemini-1.5-flash-001"
.gemini15Flash002       // "gemini-1.5-flash-002"
.gemini15Flash8BLatest  // "gemini-1.5-flash-8b-latest"
.gemini15Flash8B001     // "gemini-1.5-flash-8b-001"
.gemini15ProLatest      // "gemini-1.5-pro-latest"
.gemini15Pro001         // "gemini-1.5-pro-001"
.gemini15Pro002         // "gemini-1.5-pro-002"
```

2. **Initialization**:
```swift
let gemini = Gemini(apiKey: "your-api-key")
```

3. **Base URL**:
- Default base URL is `https://generativelanguage.googleapis.com/v1beta/openai/`
- Uses Google's API infrastructure

4. **Request Limitations**:
- Some OpenAI-specific parameters may not be available

## Basic Usage

Since Gemini uses OpenAI's request format, you can use the same request structure:

```swift
let request = OpenAI.ChatCompletionRequest(
    model: Gemini.Model.gemini15Pro,  // Use Gemini model
    messages: [
        Message(role: .user, content: "Tell me about quantum computing.")
    ]
)

let response = try await gemini.perform(request: request)
```

## Error Handling

Gemini errors have their own type:
```swift
do {
    let response = try await gemini.perform(request: request)
} catch let error as GeminiErrorResponse {
    print("Gemini API error:", error.error.message)
}
```

## For More Information

Refer to the [OpenAI Module Documentation](Sources/OpenAI/README.md) for detailed information about:
- Chat completion requests
- Streaming
- Message formats
- Response handling
- Best practices

The same patterns apply to Gemini, just use Gemini models and initialization.

See also:
- [Google Generative AI Documentation](https://ai.google.dev/docs)
- [Gemini API Reference](https://ai.google.dev/api/rest/v1)
