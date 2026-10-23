# Cohere

Cohere in two formats from one `Cohere` client:

- **Native v2 Chat** (`api.cohere.com/v2/chat`): `Cohere.ChatRequest`, which `Cohere.chatRequest` builds. It adds grounding documents with citations, tool plans, `k` sampling, and thinking budgets.
- **Compatibility API** (`api.cohere.com/compatibility/v1/`): `OpenAI.ChatCompletionRequest` with a `Cohere.Model`.

```swift
let cohere = Cohere(apiKey: ProcessInfo.processInfo.environment["COHERE_API_KEY"]!)
let request = Cohere.ChatRequest(
    model: "command-a-03-2025",
    messages: [.init(role: .user, content: "Where is the Eiffel Tower?")],
    documents: [.string("The Eiffel Tower is in Paris.")]
)
let response = try await cohere.perform(request: request)
print(response.message?.content.text ?? "", response.message?.citations ?? [])
```

- Streaming, tool calling (streamed through `tool-call-start`/`tool-call-delta`), and structured output work in both formats. `Cohere.Message(_:)` converts another provider's messages, tool calls and results included.
- `listModels()` reads the native catalog (`v1/models?endpoint=chat`), skipping deprecated models.
- Native: `tool_choice` is `.required` or `.none`; `"null"` arguments read as empty; a stream must end with `message-end`, and one carrying an error throws.
- Compatibility API: options Cohere rejects are removed, and the schema is sent bare under `json_schema`.
- Errors decode as `OpenAICompatibleErrorResponse`.
