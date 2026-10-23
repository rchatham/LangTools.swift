# VercelAIGateway

[Vercel AI Gateway](https://vercel.com/ai-gateway) routes `creator/model` IDs to many vendors, in OpenAI's chat format and Anthropic's Messages format, from one `VercelAIGateway` client (`https://ai-gateway.vercel.sh/v1/`).

```swift
let gateway = VercelAIGateway(apiKey: key)      // an AI Gateway key or a Vercel OIDC token, sent as a bearer token
let chat = OpenAI.ChatCompletionRequest(model: "openai/gpt-5" as VercelAIGateway.Model, messages: messages)
let claude = Anthropic.MessageRequest(model: .claude46Sonnet, messages: anthropicMessages).routed(to: VercelAIGateway.providerID)
```

- Messages requests go to `/messages` as `anthropic/claude-sonnet-4.6` (`gatewayModelID`; override with `routed(to:modelID:)`), keeping extended thinking and prompt caching.
- `listModels()` needs no key; chat models have `type: "language"`, and tool support is the `tool-use` tag.
- `max_completion_tokens` is sent as `max_tokens`, the parameter the gateway documents. Errors decode as `OpenAICompatibleErrorResponse`.
