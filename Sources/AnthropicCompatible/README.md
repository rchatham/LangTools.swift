# AnthropicCompatible

Shared support for providers that also serve Anthropic's Messages format, such as Vercel AI Gateway and OpenRouter. Requests keep Anthropic's types and features (extended thinking, prompt caching); the Anthropic module only adds the routing hook.

```swift
let request = Anthropic.MessageRequest(model: .claude46Sonnet, messages: messages)
    .routed(to: OpenRouter.providerID)          // sent as anthropic/claude-sonnet-4.6 (`gatewayModelID`)
let response = try await openRouter.perform(request: request)
```

Unrouted requests stay with `Anthropic`; `routed(to:modelID:)` overrides the model ID. To adopt the protocol, supply `providerID` and an `anthropic` client at the provider's base URL, and optionally `anthropicAuthentication` (`.bearer`) and `anthropicModelID(for:)`. A provider that also serves OpenAI's format adopts both protocols in one class; see [OpenAICompatible](../OpenAICompatible/README.md).
