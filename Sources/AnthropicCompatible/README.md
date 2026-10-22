# AnthropicCompatible

Shared support for providers that also serve Anthropic's Messages format, such as Vercel AI Gateway and OpenRouter. Requests keep Anthropic's types (`Anthropic.MessageRequest`, `Anthropic.MessageResponse`) and features such as extended thinking and prompt caching.

The Anthropic module only supplies the routing hook: `MessageRequest.routed(to:modelID:)`. Unrouted requests stay with `Anthropic`.

## Using a provider's Messages endpoint

```swift
let request = Anthropic.MessageRequest(model: .claude46Sonnet, messages: messages)
    .routed(to: OpenRouter.providerID)                       // sent as anthropic/claude-sonnet-4.6
let custom = request.routed(to: OpenRouter.providerID, modelID: "anthropic/claude-opus-5.5")
let response = try await openRouter.perform(request: request)
```

`Anthropic.Model.gatewayModelID` maps Anthropic's IDs to the `anthropic/<family>-<version>` IDs gateways use, dropping date and `-latest` suffixes.

## Adopting the protocol

```swift
import AnthropicCompatible

public final class MyGateway: AnthropicCompatibleProvider {
    public typealias Model = Anthropic.Model
    public typealias ErrorResponse = AnthropicCompatibleErrorResponse
    public static let providerID = LangToolsProviderID(rawValue: "mygateway")
    public let anthropic = Anthropic(baseURL: URL(string: "https://api.example.com/v1/")!, apiKey: key)

    // Optional: send the key as `Authorization: Bearer` instead of `x-api-key`.
    public var anthropicAuthentication: AnthropicCompatibleAuthentication { .bearer }

    // Optional: map models to the provider's own IDs.
    public static func anthropicModelID(for model: Anthropic.Model) -> String { model.gatewayModelID }
}
```

A provider that also serves OpenAI's format adopts both protocols in one class; see the [OpenAICompatible README](../OpenAICompatible/README.md#serving-more-than-one-format).
