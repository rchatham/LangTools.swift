# Groq

Groq support for LangTools, built on the OpenAI chat format. Base URL: `https://api.groq.com/openai/v1/`.

## Usage

```swift
import Groq
import OpenAI

let client = Groq(apiKey: ProcessInfo.processInfo.environment["GROQ_API_KEY"]!)
let request = OpenAI.ChatCompletionRequest(
    model: "llama-3.3-70b-versatile" as Groq.Model,
    messages: [.init(role: .user, content: "Hello")]
)
for try await chunk in client.stream(request: request) {
    print(chunk.choices.first?.delta?.content ?? "", terminator: "")
}
```

The request's model is tagged for Groq, so a `LangToolchain` that also holds OpenAI or another gateway routes it here. Streaming, tool calling, and structured output work as in the [OpenAI module](../OpenAI/README.md).

## Models

```swift
let models = try await client.listModels()   // GET /models
let chatModels = models.filter(\.isChatModel)
```

`Groq.knownModels` offers suggestions without a network call.

## Notes

- The catalog has no chat or tool flags; speech, guard, and inactive models are filtered by ID and `active`.
- `logprobs`, `top_logprobs`, `logit_bias`, and message `name` are removed because Groq rejects them.
- `n` must be 1.
- Errors decode as `OpenAICompatibleErrorResponse`.
