# OpenAICompatible

Shared support for providers that serve OpenAI's Chat Completions format at their own base URL. OpenRouter, Vercel AI Gateway, Groq, Mistral, DeepSeek, Cerebras, Together AI, Fireworks AI, Cohere, xAI, and Gemini are built on it.

The OpenAI module only supplies the hooks this layer needs: the model's provider tag, `additionalParameters`, and tolerant response decoding. Everything provider-specific lives here or in the provider's own module.

## Adopting the protocol

A conforming class supplies its identity and an `OpenAI` client. Routing, request preparation, extra headers, model listing, and request building come from the protocol:

```swift
import OpenAICompatible

public final class MyProvider: OpenAICompatibleProvider {
    public typealias Model = OpenAICompatibleModel<MyProvider>
    public typealias ErrorResponse = OpenAICompatibleErrorResponse
    public static let providerID = LangToolsProviderID(rawValue: "myprovider")
    public static let displayName = "My Provider"
    public static let defaultBaseURL = URL(string: "https://api.example.com/v1/")!
    public static let apiKeyEnvironmentVariable = "MY_PROVIDER_API_KEY"
    public let openAI: OpenAI

    public init(apiKey: String) {
        openAI = Self.makeClient(baseURL: Self.defaultBaseURL, apiKey: apiKey, session: .shared, logger: nil)
    }

    // Optional: headers sent on every request, validated before sending.
    public var additionalHeaders: [String: String] { ["X-Title": "My App"] }

    // Optional: drop or rename fields the provider rejects.
    public static func adaptChatBody(_ body: inout [String: JSON]) {
        OpenAICompatibleBody.remove(["stream_options"], from: &body)
    }
}

let request = OpenAI.ChatCompletionRequest(model: "some-model" as MyProvider.Model, messages: messages)
let models = try await MyProvider(apiKey: key).listModels()   // GET /models, normalized
```

`OpenAICompatibleModel<MyProvider>` is a validated model ID whose `openAIModel` is tagged for the provider, so a `LangToolchain` that also holds OpenAI or another gateway routes the request to `MyProvider` even when they serve the same ID.

A provider with an established model enum or error type keeps it: declare your own `Model` and `ErrorResponse`, and override `chatRequest` to build requests from your model type (xAI and Gemini do this, and still accept `OpenAICompatibleModel<Self>` for IDs outside their enums).

## Serving more than one format

A provider that also has request types of its own, or serves Anthropic's Messages format through `AnthropicCompatibleProvider`, handles them in the same class. Combine the building blocks each protocol exposes:

```swift
public final class MyGateway: OpenAICompatibleProvider, AnthropicCompatibleProvider {
    // ...identity, `openAI`, and `anthropic` clients...

    public var session: URLSession { openAI.session }
    public var logger: LangToolsLogger? { openAI.logger }

    public static var requestValidators: [(any LangToolsRequest) -> Bool] {
        compatibleRequestValidators + anthropicRequestValidators + [{ $0 is MyCatalogRequest }]
    }

    public func prepare(request: some LangToolsRequest) throws -> URLRequest {
        if request is Anthropic.MessageRequest { return try prepareAnthropicCompatible(request: request) }
        return try prepareCompatible(request: request)
    }

    public static func chatRequest(model: any RawRepresentable, messages: [any LangToolsMessage], tools: [any LangToolsTool]?, responseSchema: JSONSchema?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> any LangToolsChatRequest {
        if let model = model as? Anthropic.Model {
            return try anthropicChatRequest(model: model, messages: messages, tools: tools, responseSchema: responseSchema, toolEventHandler: toolEventHandler)
        }
        guard let model = model as? Model else { throw LangToolsError.invalidArgument("Unsupported model \(model)") }
        return try compatibleChatRequest(model: model, messages: messages, tools: tools, responseSchema: responseSchema, toolEventHandler: toolEventHandler)
    }
}
```

OpenRouter and Vercel AI Gateway are built this way. The class's `ErrorResponse` must decode every format's error body; `OpenAICompatibleErrorResponse` decodes OpenAI-style, Anthropic-style, top-level `{"message": ...}`, and `{"detail": ...}` bodies.

## Model catalogs

`listModels()` reads `GET /models` as `{"data": [...]}` or a bare array and normalizes each entry into `OpenAICompatibleModelInfo`: `contextWindow`, `maxOutputTokens`, `supportsTools` (nil when the catalog does not say), and `isChatModel`. Entries that fail to decode are skipped. A provider without a catalog sets `supportsModelListing` to `false` and lists `knownModels`.
