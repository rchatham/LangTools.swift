# OpenRouter

[OpenRouter](https://openrouter.ai) is a gateway to models from many vendors, serving OpenAI's chat format and Anthropic's Messages format from one `OpenRouter` client.

```swift
let openRouter = OpenRouter(apiKey: key, appURL: URL(string: "https://example.com"), appTitle: "My App")  // app headers are optional
let request = OpenAI.ChatCompletionRequest(model: "anthropic/claude-sonnet-4.5" as OpenRouter.Model, messages: [.init(role: .user, content: "Hi")])
    .routing(provider: .init(order: ["anthropic", "bedrock"], allowFallbacks: false), fallbackModels: ["openai/gpt-5"])
let response = try await openRouter.perform(request: request)
```

- **Models** are slugs such as `"openai/gpt-5:free"`; `listModels()` reads the catalog (`metadata` keeps pricing and modalities).
- **Routing:** `routing(provider:fallbackModels:)` sets OpenRouter's `provider` and `models` fields; other fields go in `additionalParameters`.
- **Toolchain:** requests carry the OpenRouter tag, so a `LangToolchain` routes them here even with OpenAI or another gateway registered. Re-tag a decoded request with `routed(to: OpenRouter.providerID)`.
- **Messages format:** `Anthropic.MessageRequest(...).routed(to: OpenRouter.providerID)` is sent to `/messages` with the model's OpenRouter slug (`Anthropic.Model.gatewayModelID`, or `routed(to:modelID:)`).
- **Errors:** HTTP errors decode as `OpenRouterErrorResponse`; one sent mid-stream throws `LangToolsError.apiError`.
- **Live test:** `LANGTOOLS_RUN_OPENROUTER_TESTS=1 OPENROUTER_API_KEY=... swift test --filter OpenRouterIntegrationTests` (billed; `OPENROUTER_TEST_MODEL` overrides the model).
