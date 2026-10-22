# Cerebras

Cerebras support for LangTools, built on the OpenAI chat format. Base URL: `https://api.cerebras.ai/v1/`.

## Usage

```swift
import Cerebras
import OpenAI

let client = Cerebras(apiKey: ProcessInfo.processInfo.environment["CEREBRAS_API_KEY"]!)
let request = OpenAI.ChatCompletionRequest(
    model: "gpt-oss-120b" as Cerebras.Model,
    messages: [.init(role: .user, content: "Hello")]
)
for try await chunk in client.stream(request: request) {
    print(chunk.choices.first?.delta?.content ?? "", terminator: "")
}
```

The request's model is tagged for Cerebras, so a `LangToolchain` that also holds OpenAI or another gateway routes it here. Streaming, tool calling, and structured output work as in the [OpenAI module](../OpenAI/README.md).

## Models

```swift
let models = try await client.listModels()   // GET /models
let chatModels = models.filter(\.isChatModel)
```

`Cerebras.knownModels` offers suggestions without a network call.

## Notes

- The default catalog has IDs only, so context windows and tool support are unknown until requested.
- Errors decode as `OpenAICompatibleErrorResponse`.
