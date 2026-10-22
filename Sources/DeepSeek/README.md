# DeepSeek

DeepSeek support for LangTools, built on the OpenAI chat format. Base URL: `https://api.deepseek.com/`.

## Usage

```swift
import DeepSeek
import OpenAI

let client = DeepSeek(apiKey: ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"]!)
let request = OpenAI.ChatCompletionRequest(
    model: "deepseek-v4-flash" as DeepSeek.Model,
    messages: [.init(role: .user, content: "Hello")]
)
for try await chunk in client.stream(request: request) {
    print(chunk.choices.first?.delta?.content ?? "", terminator: "")
}
```

The request's model is tagged for DeepSeek, so a `LangToolchain` that also holds OpenAI or another gateway routes it here. Streaming, tool calling, and structured output work as in the [OpenAI module](../OpenAI/README.md).

## Models

```swift
let models = try await client.listModels()   // GET /models
let chatModels = models.filter(\.isChatModel)
```

`DeepSeek.knownModels` offers suggestions without a network call.

## Notes

- Assistant turns are sent with `reasoning_content` (empty when unknown), which thinking mode requires.
- Structured output is downgraded from `json_schema` to `json_object`, the only mode DeepSeek supports; describe the schema in the prompt.
- `seed` and `user` are removed.
- Errors decode as `OpenAICompatibleErrorResponse`.
