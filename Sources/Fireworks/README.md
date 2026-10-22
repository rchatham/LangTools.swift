# Fireworks

Fireworks AI support for LangTools, built on the OpenAI chat format. Base URL: `https://api.fireworks.ai/inference/v1/`.

## Usage

```swift
import Fireworks
import OpenAI

let client = Fireworks(apiKey: ProcessInfo.processInfo.environment["FIREWORKS_API_KEY"]!)
let request = OpenAI.ChatCompletionRequest(
    model: "accounts/fireworks/models/kimi-k2-instruct" as Fireworks.Model,
    messages: [.init(role: .user, content: "Hello")]
)
for try await chunk in client.stream(request: request) {
    print(chunk.choices.first?.delta?.content ?? "", terminator: "")
}
```

The request's model is tagged for Fireworks AI, so a `LangToolchain` that also holds OpenAI or another gateway routes it here. Streaming, tool calling, and structured output work as in the [OpenAI module](../OpenAI/README.md).

## Models

```swift
let models = try await client.listModels()   // GET /models
let chatModels = models.filter(\.isChatModel)
```

`Fireworks.knownModels` offers suggestions without a network call.

## Notes

- `listModels()` returns the first page of the catalog. Chat and tool support come from `supports_chat` and `supports_tools`; embedding models are excluded.
- Errors decode as `OpenAICompatibleErrorResponse`.
