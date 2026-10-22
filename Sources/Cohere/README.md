# Cohere

Cohere support for LangTools, built on the OpenAI chat format. Base URL: `https://api.cohere.ai/compatibility/v1/`.

## Usage

```swift
import Cohere
import OpenAI

let client = Cohere(apiKey: ProcessInfo.processInfo.environment["COHERE_API_KEY"]!)
let request = OpenAI.ChatCompletionRequest(
    model: "command-a-03-2025" as Cohere.Model,
    messages: [.init(role: .user, content: "Hello")]
)
for try await chunk in client.stream(request: request) {
    print(chunk.choices.first?.delta?.content ?? "", terminator: "")
}
```

The request's model is tagged for Cohere, so a `LangToolchain` that also holds OpenAI or another gateway routes it here. Streaming, tool calling, and structured output work as in the [OpenAI module](../OpenAI/README.md).

## Models

Cohere has no model catalog on this API. Use `Cohere.knownModels`, or any model ID from Cohere's documentation.

## Notes

- The Compatibility API has no model catalog; `Cohere.knownModels` lists current Command models.
- `stream_options`, `n`, `parallel_tool_calls`, log-probability, and audio options are removed because Cohere rejects them.
- Structured output sends the schema directly under `json_schema`, which Cohere expects in place of OpenAI's `{name, schema, strict}` wrapper. This shape is taken from Cohere's error messages rather than a live call.
- Errors decode as `OpenAICompatibleErrorResponse`.
