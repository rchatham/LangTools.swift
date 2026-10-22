# TogetherAI

Together AI support for LangTools, built on the OpenAI chat format. Base URL: `https://api.together.xyz/v1/`.

## Usage

```swift
import TogetherAI
import OpenAI

let client = TogetherAI(apiKey: ProcessInfo.processInfo.environment["TOGETHER_API_KEY"]!)
let request = OpenAI.ChatCompletionRequest(
    model: "meta-llama/Llama-3.3-70B-Instruct-Turbo" as TogetherAI.Model,
    messages: [.init(role: .user, content: "Hello")]
)
for try await chunk in client.stream(request: request) {
    print(chunk.choices.first?.delta?.content ?? "", terminator: "")
}
```

The request's model is tagged for Together AI, so a `LangToolchain` that also holds OpenAI or another gateway routes it here. Streaming, tool calling, and structured output work as in the [OpenAI module](../OpenAI/README.md).

## Models

```swift
let models = try await client.listModels()   // GET /models
let chatModels = models.filter(\.isChatModel)
```

`TogetherAI.knownModels` offers suggestions without a network call.

## Notes

- `GET /models` returns a bare array; chat models have `type: "chat"`. The catalog has no tool-support flag.
- `logprobs: true` is sent as the `top_logprobs` count (default 1).
- Errors decode as `OpenAICompatibleErrorResponse`.
