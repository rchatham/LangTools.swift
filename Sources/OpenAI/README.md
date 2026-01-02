# OpenAI

Swift interface for OpenAI's APIs, part of the LangTools framework.

## Features

- 🤖 Chat Completions with GPT models
- 🗣️ Text-to-Speech and Speech-to-Text
- 📊 Embeddings generation
- 🔄 Streaming support
- 🛠️ Function calling and tools
- 📝 Multi-choice responses
- ⚡ Realtime WebSocket API

## Available Models

```swift
// Chat models
.gpt35Turbo              // "gpt-3.5-turbo"
.gpt35Turbo_0301        // "gpt-3.5-turbo-0301"
.gpt35Turbo_1106        // "gpt-3.5-turbo-1106"
.gpt35Turbo_16k         // "gpt-3.5-turbo-16k"
.gpt35Turbo_Instruct    // "gpt-3.5-turbo-instruct"
.gpt4                   // "gpt-4"
.gpt4Turbo             // "gpt-4-turbo"
.gpt4_0613             // "gpt-4-0613"
.gpt4Turbo_1106Preview // "gpt-4-1106-preview"
.gpt4_VisionPreview    // "gpt-4-vision-preview"
.gpt4_32k_0613        // "gpt-4-32k-0613"

// GPT-4 Omega models
.gpt4o                  // "gpt-4o"
.gpt4o_mini            // "gpt-4o-mini"
.gpt4o_2024_05_13      // "gpt-4o-2024-05-13"
.gpt4o_realtimePreview // "gpt-4o-realtime-preview"
.gpt4o_miniRealtimePreview // "gpt-4o-mini-realtime-preview"
.gpt4o_audioPreview    // "gpt-4o-audio-preview"
.chatGPT4o_latest      // "chatgpt-4o-latest"

// O1 models
.o1                    // "o1"
.o1_mini              // "o1-mini"
.o1_preview           // "o1-preview"

// Audio models
.tts_1                 // Text-to-Speech
.tts_1_hd             // High-quality Text-to-Speech
.whisper              // Speech-to-Text

// Embedding models
.textEmbeddingAda002         // "text-embedding-ada-002"
.textEmbedding3Large         // "text-embedding-3-large"
.textEmbedding3Small         // "text-embedding-3-small"
```

## Basic Usage

### Initialize OpenAI Client

```swift
let openai = OpenAI(apiKey: "your-api-key")
```

### Chat Completions

Basic chat completion:
```swift
let request = OpenAI.ChatCompletionRequest(
    model: .gpt35Turbo,
    messages: [
        Message(role: .system, content: "You are a helpful assistant."),
        Message(role: .user, content: "Hello!")
    ]
)

let response = try await openai.perform(request: request)
print(response.choices[0].message?.content.text ?? "")
```

Streaming chat completion:
```swift
let request = OpenAI.ChatCompletionRequest(
    model: .gpt35Turbo,
    messages: [
        Message(role: .user, content: "Write a story about a robot.")
    ],
    stream: true
)

for try await chunk in openai.stream(request: request) {
    if let text = chunk.choices[0].delta?.content {
        print(text, terminator: "")
    }
}
```

### Function Calling

```swift
let weatherTool = OpenAI.Tool(
    name: "get_weather",
    description: "Get the current weather",
    tool_schema: .init(
        properties: [
            "location": .init(
                type: "string",
                description: "City name"
            ),
            "unit": .init(
                type: "string",
                enumValues: ["celsius", "fahrenheit"]
            )
        ],
        required: ["location"]
    ),
    callback: { args in
        guard let location = args["location"]?.stringValue else {
            throw AgentError("Missing location")
        }
        // Implement weather lookup
        return "Weather data for \(location)"
    }
)

let request = OpenAI.ChatCompletionRequest(
    model: .gpt35Turbo,
    messages: [
        Message(role: .user, content: "What's the weather in London?")
    ],
    tools: [weatherTool]
)

let response = try await openai.perform(request: request)
```

### Text-to-Speech

```swift
let request = OpenAI.AudioSpeechRequest(
    model: .tts_1_hd,
    input: "Hello, how are you today?",
    voice: .alloy,
    responseFormat: .mp3,
    speed: 1.0
)

let audioData = try await openai.perform(request: request)
// Use the audio data (e.g., save to file or play)
```

### Speech-to-Text

```swift
let request = OpenAI.AudioTranscriptionRequest(
    file: audioFileData,
    fileType: .mp3,
    model: .whisper,
    prompt: "This is a conversation about weather.",
    language: "en"
)

let transcription = try await openai.perform(request: request)
print(transcription.text)
```

### Embeddings

```swift
let request = OpenAI.EmbeddingsRequest(
    input: .string("Hello, world!"),
    model: .textEmbedding3Small
)

let response = try await openai.perform(request: request)
let embedding = response.data[0].embedding
```

### Realtime Sessions

Create a realtime session and connect via WebSocket:

```swift
let session = try await openai.perform(request:
    OpenAI.RealtimeSessionCreateRequest(model: .gpt4o_realtimePreview)
)

let socket = openai.realtimeWebSocketTask(clientSecret: session.client_secret!.value)
socket.resume()
```

## Advanced Features

### Multiple Choices

Request multiple completions and choose between them:

```swift
let request = OpenAI.ChatCompletionRequest(
    model: .gpt35Turbo,
    messages: [Message(role: .user, content: "Write a tagline")],
    n: 3,
    choose: { choices in
        // Used in conjunction with automatic tool completion.
        // Choose the shortest response:
        choices.min { $0.message?.content.text?.count ?? 0 < $1.message?.content.text?.count ?? 0 }?.index ?? 0
    }
)

let response = try await openai.perform(request: request)
```

### Request Options

The `ChatCompletionRequest` supports various options:

```swift
let request = OpenAI.ChatCompletionRequest(
    model: .gpt4,
    messages: messages,
    temperature: 0.7,          // Randomness (0.0 to 1.0)
    top_p: 0.9,               // Nucleus sampling
    max_tokens: 1000,         // Maximum length
    presence_penalty: 0.5,     // Penalize repeated topics
    frequency_penalty: 0.5,    // Penalize repeated tokens
    stop: .array(["END"]),    // Stop sequences
    user: "user123",          // User identifier
    seed: 42                  // Reproducible results
)
```

## Error Handling

OpenAI errors are typed for better handling:

```swift
do {
    let response = try await openai.perform(request: request)
} catch let error as OpenAIErrorResponse {
    switch error.error.type {
    case "invalid_request_error":
        print("Invalid request:", error.error.message)
    case "authentication_error":
        print("Authentication failed:", error.error.message)
    default:
        print("Error:", error.error.message)
    }
}
```

## Working with Files

For audio and file-based requests, use Swift's Data type:

```swift
let fileURL = URL(fileURLWithPath: "audio.mp3")
let audioData = try Data(contentsOf: fileURL)

let request = OpenAI.AudioTranscriptionRequest(
    file: audioData,
    fileType: .mp3
)
```

## Best Practices

1. **API Key Management**: Store your API key securely and never commit it to version control
2. **Error Handling**: Always handle potential errors, especially for network requests
3. **Streaming**: Use streaming for long responses to provide better user experience
4. **Resource Management**: Be mindful of token usage and implement proper rate limiting
5. **Model Selection**: Choose the appropriate model for your use case considering cost and capabilities

## Additional Resources

- [OpenAI API Documentation](https://platform.openai.com/docs/api-reference)
- [OpenAI Models Overview](https://platform.openai.com/docs/models)
- [OpenAI Guidelines](https://platform.openai.com/docs/guides/safety-best-practices)
