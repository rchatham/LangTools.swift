# Cohere

Cohere support for LangTools, in two formats from one `Cohere` client:

- The **Compatibility API** (`https://api.cohere.com/compatibility/v1/`) takes `OpenAI.ChatCompletionRequest`s. `Cohere.chatRequest(...)` builds these.
- The **native v2 Chat API** (`https://api.cohere.com/v2/chat`) takes `Cohere.ChatRequest`s, adding grounding documents with citations, tool plans, `k` sampling, and thinking budgets.

## Usage

```swift
import Cohere
import OpenAI

let client = Cohere(apiKey: ProcessInfo.processInfo.environment["COHERE_API_KEY"]!)

// OpenAI format
let request = OpenAI.ChatCompletionRequest(
    model: "command-a-03-2025" as Cohere.Model,
    messages: [.init(role: .user, content: "Hello")]
)
for try await chunk in client.stream(request: request) {
    print(chunk.choices.first?.delta?.content ?? "", terminator: "")
}

// Native format, grounded in documents
let native = Cohere.ChatRequest(
    model: "command-a-03-2025",
    messages: [.init(role: .user, content: "Where is the Eiffel Tower?")],
    documents: [.string("The Eiffel Tower is in Paris.")]
)
let response = try await client.perform(request: native)
print(response.message?.content.text ?? "", response.message?.citations ?? [])
```

Both requests carry a model tagged for Cohere, so a `LangToolchain` that also holds OpenAI or another gateway routes them here. Streaming, tool calling, and structured output work in both formats; native tool calls stream through `tool-call-start` and `tool-call-delta` events and run like any other LangTools tool.

## Models

```swift
let models = try await client.listModels()   // GET v1/models?endpoint=chat
```

`listModels()` reads Cohere's native catalog, skipping deprecated models; `features` such as `tools` set `supportsTools`. `Cohere.knownModels` lists current Command models without a network call.

## Notes

- Compatibility API: `stream_options`, `n`, `parallel_tool_calls`, log-probability, and audio options are removed because Cohere rejects them. Structured output sends the schema directly under `json_schema`, which Cohere expects in place of OpenAI's `{name, schema, strict}` wrapper.
- Native API: `tool_choice` is `.required` or `.none`; omit it to let the model choose. A tool call's `"null"` arguments read as empty. A stream must end with `message-end`, and a `message-end` carrying an error throws `LangToolsError.apiError`.
- Errors decode as `OpenAICompatibleErrorResponse` in both formats.
