# OpenRouter

Swift interface for [OpenRouter](https://openrouter.ai), part of the LangTools framework. OpenRouter is an OpenAI-compatible gateway to models from many vendors, so this module uses the OpenAI module's request and response types.

## Initialization

```swift
let openRouter = OpenRouter(
    apiKey: "your-api-key",
    appURL: URL(string: "https://example.com"),  // optional, sent as HTTP-Referer
    appTitle: "My App"                            // optional, sent as X-OpenRouter-Title
)
```

The default base URL is `https://openrouter.ai/api/v1/`. The two app headers are optional; OpenRouter uses them to attribute usage to your app in its rankings.

## Models

Models are slugs such as `"anthropic/claude-sonnet-4.5"` or `"openai/gpt-5"`, optionally with a variant suffix such as `":free"`. The catalog changes often, so there is no static model list. Fetch it instead:

```swift
let models = try await openRouter.listModels()
let toolModels = try await openRouter.listModels(.init(supportedParameters: ["tools"]))
```

Each `ModelInfo` carries the context length, pricing, modalities, and supported parameters. `supportsTools` and `supportsStructuredOutput` read the supported parameters.

## Chat

```swift
let request = OpenAI.ChatCompletionRequest(
    model: "anthropic/claude-sonnet-4.5" as OpenRouter.Model,
    messages: [.init(role: .user, content: "Tell me about AI.")]
)
let response = try await openRouter.perform(request: request)
```

Streaming, tool calling, and structured output work as in the [OpenAI module](../OpenAI/README.md). An error that OpenRouter reports partway through a stream ends the stream by throwing `LangToolsError.apiError`.

## Routing

Choose upstream providers and fallback models:

```swift
let request = OpenAI.ChatCompletionRequest(
    model: "meta-llama/llama-3.3-70b-instruct",
    messages: messages,
    provider: .init(order: ["groq", "together"], allowFallbacks: false, sort: .throughput),
    fallbackModels: ["mistralai/mistral-large"]
)
```

`routing(provider:fallbackModels:)` adds the same options to an existing request. Other OpenRouter request fields can be set through `additionalParameters`.

## LangToolchain

OpenRouter models carry a provider tag, so a `LangToolchain` routes them to OpenRouter even when OpenAI, XAI, Gemini, or another gateway is registered too:

```swift
var toolchain = LangToolchain()
toolchain.register(OpenAI(apiKey: openAIKey))
toolchain.register(OpenRouter(apiKey: openRouterKey))

let request = OpenAI.ChatCompletionRequest(model: "openai/gpt-5" as OpenRouter.Model, messages: messages)
let response = try await toolchain.perform(request: request)  // served by OpenRouter
```

The tag is not encoded. Re-tag a request decoded from storage with `request.routed(to: OpenRouter.providerID)`.

## Error Handling

```swift
do {
    let response = try await openRouter.perform(request: request)
} catch LangToolsError.responseUnsuccessful(let status, let error as OpenRouterErrorResponse) {
    print("OpenRouter error \(status):", error.error.message)
}
```

## Live Smoke Test

`OpenRouterIntegrationTests` makes real, billed requests and is skipped by default:

```sh
LANGTOOLS_RUN_OPENROUTER_TESTS=1 OPENROUTER_API_KEY=... swift test --filter OpenRouterIntegrationTests
```

Set `OPENROUTER_TEST_MODEL` to override the default model, `openai/gpt-4o-mini`.

See also:
- [OpenRouter API reference](https://openrouter.ai/docs/api-reference/overview)
- [Provider routing](https://openrouter.ai/docs/features/provider-routing)
