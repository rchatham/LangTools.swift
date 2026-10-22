# Mistral

Mistral support for LangTools, built on the OpenAI chat format. Base URL: `https://api.mistral.ai/v1/`.

## Usage

```swift
import Mistral
import OpenAI

let client = Mistral(apiKey: ProcessInfo.processInfo.environment["MISTRAL_API_KEY"]!)
let request = OpenAI.ChatCompletionRequest(
    model: "mistral-large-latest" as Mistral.Model,
    messages: [.init(role: .user, content: "Hello")]
)
for try await chunk in client.stream(request: request) {
    print(chunk.choices.first?.delta?.content ?? "", terminator: "")
}
```

The request's model is tagged for Mistral, so a `LangToolchain` that also holds OpenAI or another gateway routes it here. Streaming, tool calling, and structured output work as in the [OpenAI module](../OpenAI/README.md).

## Models

```swift
let models = try await client.listModels()   // GET /models
let chatModels = models.filter(\.isChatModel)
```

`Mistral.knownModels` offers suggestions without a network call.

## Notes

- Mistral answers 422 for unknown fields. `stream_options`, `user`, `service_tier`, `store`, `metadata`, log-probability options, and audio options are removed; `seed` becomes `random_seed` and `max_completion_tokens` becomes `max_tokens`.
- Reasoning models may return content as an array of parts; text parts are kept and `thinking` parts skipped.
- Chat and tool support come from the catalog's `capabilities.completion_chat` and `capabilities.function_calling`.
- Errors decode as `OpenAICompatibleErrorResponse`.
