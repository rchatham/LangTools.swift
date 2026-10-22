# Perplexity

Perplexity's [Agent API](https://docs.perplexity.ai) for LangTools: web-grounded answers in OpenAI's Responses format, sent to `https://api.perplexity.ai/v1/agent`. Perplexity retired its Sonar Chat Completions API on 2026-09-27, so requests are `OpenAI.ResponsesRequest`s.

## Usage

```swift
import Perplexity
import OpenAI

let client = Perplexity(apiKey: ProcessInfo.processInfo.environment["PERPLEXITY_API_KEY"]!)
let request = OpenAI.ResponsesRequest(
    model: Perplexity.Model.medium,
    messages: [.init(role: .user, content: "What changed in Swift 6.2?")],
    stream: true
)
for try await chunk in client.stream(request: request) {
    print(chunk.delta?.content ?? "", terminator: "")
}
```

The request's model is tagged for Perplexity, so a `LangToolchain` that also holds OpenAI routes it here. `Perplexity.chatRequest(model:messages:...)` builds the same request, so agents and the toolchain's generic chat helpers work too.

## Models and presets

- Presets: `.fast`, `.low`, `.medium`, `.high`, `.xhigh`. Each bundles a model, search tools, and a reasoning budget; they are sent as `preset`.
- `.sonar` (`perplexity/sonar`), Perplexity's own model.
- Any model the Agent API routes to, by ID: `"openai/gpt-5.2" as Perplexity.Model`.

There is no catalog endpoint, so `listModels()` throws; use `Perplexity.knownModels`.

## Notes

- Function tools and structured output work as with OpenAI. The schema is sent as `response_format`, Perplexity's spelling.
- `tool_choice`, `parallel_tool_calls`, and `metadata` are dropped; the Agent API chooses tools itself.
- Search results and other native tool output items are decoded but not surfaced in `message`; answer text keeps its citations inline.
- A response with `status: "failed"` or a `response.failed` stream event throws `LangToolsError.apiError` with the provider's message.
- HTTP errors decode as `OpenAICompatibleErrorResponse`.
