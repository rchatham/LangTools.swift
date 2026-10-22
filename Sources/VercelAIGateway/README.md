# VercelAIGateway

Vercel AI Gateway support for LangTools, built on the OpenAI chat format. Base URL: `https://ai-gateway.vercel.sh/v1/`.

## Usage

```swift
import VercelAIGateway
import OpenAI

let client = VercelAIGateway(apiKey: ProcessInfo.processInfo.environment["AI_GATEWAY_API_KEY"]!)
let request = OpenAI.ChatCompletionRequest(
    model: "openai/gpt-5" as VercelAIGateway.Model,
    messages: [.init(role: .user, content: "Hello")]
)
for try await chunk in client.stream(request: request) {
    print(chunk.choices.first?.delta?.content ?? "", terminator: "")
}
```

The request's model is tagged for Vercel AI Gateway, so a `LangToolchain` that also holds OpenAI or another gateway routes it here. Streaming, tool calling, and structured output work as in the [OpenAI module](../OpenAI/README.md).

## Models

```swift
let models = try await client.listModels()   // GET /models
let chatModels = models.filter(\.isChatModel)
```

`VercelAIGateway.knownModels` offers suggestions without a network call.

## Notes

- `GET /models` needs no key; chat models have `type: "language"` and tool support is the `tool-use` tag.
- `max_completion_tokens` is sent as `max_tokens`, the parameter the gateway documents.
- Claude models can also be called in Anthropic's Messages format; see below.
- Errors decode as `OpenAICompatibleErrorResponse`.

## Anthropic Messages format

Claude models can also be called in Anthropic's own format, keeping Anthropic features such as extended thinking and prompt caching:

```swift
import Anthropic
import VercelAIGateway

let gateway = VercelAnthropicGateway(apiKey: key)      // or authentication: .bearer for an OIDC token
let request = Anthropic.MessageRequest(model: .claude46Sonnet, messages: messages)
    .routed(to: VercelAnthropicGateway.anthropicProviderID)
let response = try await gateway.perform(request: request)
```

The request is sent to `https://ai-gateway.vercel.sh/v1/messages` with the model `anthropic/claude-sonnet-4.6` (see `Anthropic.Model.gatewayModelID`). Pass `modelID:` to `routed(to:modelID:)` to send any other gateway model ID. Unrouted requests stay with `Anthropic`, so both can share a `LangToolchain`.
