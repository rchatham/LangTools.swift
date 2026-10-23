# Perplexity

Perplexity's Agent API (`https://api.perplexity.ai/v1/agent`): web-grounded answers in OpenAI's Responses format. Perplexity retired Sonar Chat Completions on 2026-09-27, so requests are `OpenAI.ResponsesRequest`s, which `Perplexity.chatRequest` also builds.

```swift
let perplexity = Perplexity(apiKey: key)
let request = OpenAI.ResponsesRequest(model: Perplexity.Model.medium, messages: [.init(role: .user, content: "What changed in Swift 6.2?")], stream: true)
for try await chunk in perplexity.stream(request: request) { print(chunk.delta?.content ?? "", terminator: "") }
```

- Models: presets `.fast` through `.xhigh` (sent as `preset`), `.sonar`, or any routed model by ID such as `"openai/gpt-5.2"`. There is no catalog endpoint.
- Function tools and structured output work as with OpenAI (the schema is sent as `response_format`); `tool_choice`, `parallel_tool_calls`, and `metadata` are dropped.
- Search results are decoded but not surfaced in `message`. A `failed` response or `response.failed` event throws `LangToolsError.apiError`; HTTP errors decode as `OpenAICompatibleErrorResponse`.
