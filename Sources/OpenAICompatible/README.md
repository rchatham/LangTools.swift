# OpenAICompatible

Shared support for providers that serve OpenAI's Chat Completions or Responses format at their own base URL, and the single-vendor providers built on it:

| Provider | Base URL | Dialect handled |
|---|---|---|
| `Groq` | `api.groq.com/openai/v1` | Log-probability options and message `name` removed |
| `Mistral` | `api.mistral.ai/v1` | OpenAI-only fields removed (Mistral answers 422); `seed` → `random_seed`, `max_completion_tokens` → `max_tokens` |
| `DeepSeek` | `api.deepseek.com` | `reasoning_content` added to assistant turns (thinking mode); `json_schema` → `json_object` |
| `Cerebras` | `api.cerebras.ai/v1` | — |
| `TogetherAI` | `api.together.xyz/v1` | `logprobs` sent as a count |
| `Fireworks` | `api.fireworks.ai/inference/v1` | `listModels()` reads the first catalog page |

OpenRouter, Vercel AI Gateway, Cohere, Perplexity, xAI, and Gemini build on it in their own modules.

```swift
let groq = Groq(apiKey: key)
let request = OpenAI.ChatCompletionRequest(model: "llama-3.3-70b-versatile" as Groq.Model, messages: [.init(role: .user, content: "Hi")])
for try await chunk in groq.stream(request: request) { print(chunk.choices.first?.delta?.content ?? "", terminator: "") }
let models = try await groq.listModels()      // GET /models, normalized; `knownModels` offers suggestions
```

`OpenAICompatibleModel<Provider>` is a validated ID whose `openAIModel` is tagged for the provider, so a `LangToolchain` routes it there even when OpenAI or a gateway serves the same ID.

## Adopting the protocol

```swift
public final class MyProvider: OpenAICompatibleProvider {
    public typealias Model = OpenAICompatibleModel<MyProvider>
    public typealias ErrorResponse = OpenAICompatibleErrorResponse
    public static let providerID = LangToolsProviderID(rawValue: "myprovider"), displayName = "My Provider", apiKeyEnvironmentVariable = "MY_PROVIDER_API_KEY"
    public static let defaultBaseURL = URL(string: "https://api.example.com/v1/")!
    public let openAI: OpenAI
    public init(apiKey: String) { openAI = Self.makeClient(baseURL: Self.defaultBaseURL, apiKey: apiKey, session: .shared, logger: nil) }

    // Optional hooks
    public var additionalHeaders: [String: String] { ["X-Title": "My App"] }      // validated before sending
    public static func adaptChatBody(_ body: inout [String: JSON]) { OpenAICompatibleBody.remove(["stream_options"], from: &body) }
}
```

- **Responses format:** `compatibleFormats` (`.responses`, or both) routes tagged `OpenAI.ResponsesRequest`s to the provider, with `adaptResponsesBody` for its dialect. Perplexity serves only this format.
- **More formats in one class:** a provider with request types of its own, or Anthropic's Messages format (`AnthropicCompatibleProvider`), combines `compatibleRequestValidators`, `prepareCompatible(request:)` (or `prepareNative` for its own API), and `compatibleChatRequest` with them, as OpenRouter, Vercel AI Gateway, Cohere, and Gemini do.
- **Own model enum:** xAI and Gemini keep theirs and override `chatRequest`, still accepting `OpenAICompatibleModel<Self>` for other IDs.
- **Catalogs:** `listModels()` reads `{"data": [...]}` or a bare array into `OpenAICompatibleModelInfo` (`contextWindow`, `maxOutputTokens`, `supportsTools`, `isChatModel`, raw `metadata`), skipping malformed entries. A provider with its own catalog API overrides it; one without sets `supportsModelListing` to `false`.
- **Errors:** `OpenAICompatibleErrorResponse` decodes OpenAI-style, top-level `{"message"}`, and `{"detail"}` bodies.
