# Additional providers: investigation and plan

## Scope

Assess what it takes to add more LLM providers to LangTools.swift, with Vercel AI Gateway and OpenRouter as the motivating cases and single-vendor OpenAI-compatible APIs (Groq, Mistral, DeepSeek, Cerebras, Together, Fireworks, Perplexity) as the follow-on set. This document records how the current provider layer works, where it will break for gateway-style providers, and the recommended order of work. No code changes are included.

## How providers work today

- `LangTools` (`Sources/LangTools/LangTools.swift`) is the provider protocol. A provider supplies a `Model: RawRepresentable` type, an `ErrorResponse`, a `URLSession`, `prepare(request:)`, a static `requestValidators` list, and a static `chatRequest(...)` factory. Streaming, tool-call completion loops, and error decoding live in protocol extensions, so a provider rarely overrides them.
- `LangToolchain` (`Sources/LangTools/LangToolchain.swift`) stores providers in a dictionary keyed by the provider's type name and routes each request to the first registered provider whose validators accept it.
- Three providers are thin wrappers over the `OpenAI` target: `XAI`, `Gemini`, and (for chat only) `Ollama`. `XAI` and `Gemini` are about 50 lines each. They own an `OpenAI` instance pointed at a different base URL, forward `prepare` to it, declare a static model enum, and add an `OpenAI.ChatCompletionRequest` initializer overload that takes their model type. Their validator is `OpenAIModel.<provider>Models.contains(request.model)`, a membership test against the static enum.
- `Ollama` is the one provider with a dynamic catalog. `OllamaModel.allCases` is a mutable static that the app and CLI populate after calling the list-models endpoint. It defines its own request types rather than reusing `ChatCompletionRequest`, so its validators are plain type checks.
- Each provider is its own SwiftPM target and product with a README resource and a dedicated test target. Tests use `MockURLProtocol` from `TestUtils` and a `configure(testURLSessionConfiguration:)` helper. CI runs every test target in `Package.swift` serially.

Adding a single-vendor OpenAI-compatible provider with a fixed catalog is therefore a copy of the `XAI` template: one source file, a README, a test target, two lines in `Package.swift`, and a README bullet. The gateway providers do not fit that template, for the reasons below.

## Where the current design breaks for gateways

### 1. Routing assumes a static model enum

`requestValidators` is static and matches by model membership. OpenRouter and Vercel AI Gateway each expose hundreds of models as `creator/model` slugs and the catalog changes weekly. An enum cannot track it, and a mutable static list (the Ollama approach) is a process-global that two gateway targets would race on.

Worse, both gateways use the same `creator/model` slug format, so a prefix or "contains a slash" heuristic cannot tell an OpenRouter request from a Vercel request when both are registered. `LangToolchain.perform` picks `langTools.values.first(where:)` on a dictionary, so overlapping validators resolve in an unspecified order.

Recommended fix (core, additive): give `OpenAIModel` an optional, non-encoded provider tag, set through a new `init(customModelID:provider:)`. A gateway validator then checks the tag instead of a model list. `OpenAIModel.==` compares `id` only today; it should also compare the tag, or two gateways' identically named models will collide in sets and comparisons. Also make `LangToolchain` iterate in registration order (an array alongside the dictionary) so overlaps resolve deterministically.

### 2. `ChatCompletionResponse` decoding is stricter than the gateways' output

`OpenAI.ChatCompletionResponse` and its nested types are decoded with synthesized `Codable`, which throws on any unknown enum value or missing non-optional field. Known hazards, in `Sources/OpenAI/OpenAI+ChatCompletionRequest.swift`:

- `Usage.CompletionTokensDetails` requires `accepted_prediction_tokens` and `rejected_prediction_tokens`. `Usage.PromptTokensDetails` requires `audio_tokens`. OpenRouter returns only the subset the upstream vendor reports (commonly `reasoning_tokens` alone, and `cached_tokens` alone). One missing key fails the whole response. Making every field in these two structs optional is a safe, source-compatible change.
- `Choice.FinishReason` has no `error` case. OpenRouter commits a 200 status once streaming starts and reports later failures as a chunk with `finish_reason: "error"`. Add the case, or decode unknown reasons leniently.
- `ServiceTier` only knows `auto` and `default`. Any other value from any provider fails decoding.
- A mid-stream OpenRouter error chunk carries a top-level `error` object. The stream loop in `LangTools.stream` treats a decode failure as "need more lines" and keeps appending, so one bad chunk poisons the rest of the stream and surfaces as `failedToDecodeStream` at the end. The response type should accept an optional `error` field so the chunk decodes and the error can be thrown immediately.
- OpenRouter emits SSE comment lines (`: OPENROUTER PROCESSING`) while a request is queued. The default `decodeStream` ignores lines that do not start with `data:`, so this already works.

### 3. Error bodies differ per provider

`OpenAIErrorResponse` requires `error.type` as a string and treats `error.code` as an optional string. OpenRouter's shape is `{ error: { code: Int, message: String, metadata: {...}? } }`. Decoding fails silently and the caller gets `responseUnsuccessful(statusCode:, nil)` with no message. Each new provider needs its own `ErrorResponse`, as `XAI` and `Gemini` already do.

### 4. No way to send provider-specific body fields or headers

`ChatCompletionRequest.encode(to:)` writes a fixed key set. OpenRouter accepts `provider` (routing preferences), `models` (fallback list), `route`, `transforms`, `reasoning`, and `usage: { include: true }`. DeepSeek, Groq, and Vercel also have vendor-specific keys. There is no escape hatch.

`OpenAIConfiguration` has no custom header support. OpenRouter's attribution headers (`HTTP-Referer`, `X-Title`) are optional but expected by its dashboard.

Recommended fix (core, additive): an `additionalParameters: [String: JSON]?` on `ChatCompletionRequest` that is merged into the encoded body, and an `additionalHeaders: [String: String]` on `OpenAIConfiguration`. Both benefit every OpenAI-compatible provider.

### 5. Model listing is not reusable

`OpenAI.ListModelDataRequest` is validated by the `OpenAI` provider only, so routing it through the toolchain always lands on OpenAI. Its `ModelData` requires `created` and `owned_by`, which the gateways' catalogs do not all include, and the gateways add fields the app will want (context length, pricing, supported parameters). Each gateway needs its own list-models request and response type, called directly on the instance the way the CLI calls `ollama.listModels()`.

### 6. The Anthropic-compatible path is closed to custom models

Both gateways also expose an Anthropic Messages endpoint (Vercel at `https://ai-gateway.vercel.sh`, OpenRouter in beta). The `Anthropic` target accepts a custom base URL, but `Anthropic.Model` is a closed enum with no custom-ID initializer, and `prepare` hardcodes the `x-api-key` header and `anthropic-version`. Opening this path is optional and can wait; it would let Claude models through a gateway keep native features such as prompt caching and extended thinking.

## Wire details for the two named gateways

| | OpenRouter | Vercel AI Gateway |
| --- | --- | --- |
| OpenAI-compatible base URL | `https://openrouter.ai/api/v1/` | `https://ai-gateway.vercel.sh/v1/` |
| Auth | `Authorization: Bearer <key>` | `Authorization: Bearer <AI_GATEWAY_API_KEY>` (OIDC also supported on Vercel) |
| Model ID format | `creator/model`, optional `:variant` suffix | `creator/model` |
| Catalog endpoint | `GET /models` (extra fields: pricing, context length, architecture) | `GET /models` |
| Extra request fields | `provider`, `models`, `route`, `transforms`, `reasoning`, `usage` | provider options for routing and fallback |
| Extra headers | `HTTP-Referer`, `X-Title` (attribution, optional) | none required |
| Error shape | `error.code` is an integer, with optional `metadata` | not verified from this environment |
| Also offers | Responses API (beta), Anthropic Messages (beta) | Responses API, Anthropic Messages |

The Vercel error shape and its exact provider-options key could not be confirmed here because the network proxy blocks `vercel.com` and `openrouter.ai`; both should be checked against live responses and captured as test fixtures.

## Single-vendor OpenAI-compatible providers

These fit the `XAI` template with small per-provider differences:

| Provider | Base URL | Notes |
| --- | --- | --- |
| Groq | `https://api.groq.com/openai/v1/` | non-standard path prefix |
| Mistral | `https://api.mistral.ai/v1/` | |
| DeepSeek | `https://api.deepseek.com/v1/` | vendor-specific reasoning fields |
| Cerebras | `https://api.cerebras.ai/v1/` | |
| Perplexity | `https://api.perplexity.ai/` | no `/v1` segment; search-specific response fields |
| Together | `https://api.together.xyz/v1/` | large catalog, better treated as dynamic |
| Fireworks | `https://api.fireworks.ai/inference/v1/` | model IDs are long `accounts/.../models/...` paths |

Each needs its own `ErrorResponse`, a model type, a `ChatCompletionRequest` initializer overload, a README, and a test target. Together and Fireworks have large catalogs and would benefit from the dynamic-model support built for the gateways.

## App and CLI touch points

Every new provider is a new case in several closed enums. Counting the Gemini case as a proxy: 32 references across 9 files in `Apps/LangTools` (`Model`, `ModelRoute`, `APIService`, `AccessDestination`, `AuthModels`, `ProviderAccessManager`, `NetworkClient.request`, `NetworkClient.agentContext`, settings and auth views, keychain) and 19 across 7 files in `cli`. A dynamic-catalog provider also needs the `OllamaService` fetch-and-cache pattern so the picker can show models.

The `Model.rawValue` format in the app is `route/slug`, split on the first slash. Gateway slugs contain slashes, so the route for OpenRouter or Vercel must be parsed with `maxSplits: 1` (already the case) and slugs must never be split further.

## Recommended sequencing

1. **Core hardening, no new provider.** Optional usage-detail fields, `error` finish reason and lenient enum decoding, optional top-level `error` on the chat response, `additionalParameters` on `ChatCompletionRequest`, `additionalHeaders` on `OpenAIConfiguration`, provider tag on `OpenAIModel`, deterministic toolchain order. Cover each with a fixture under `Tests/TestUtils/Resources`. This is the only step that touches shared code and it is source-compatible.
2. **OpenRouter target.** One key unlocks the most models, and its quirks (integer error codes, mid-stream errors, SSE comments, partial usage details) exercise every change from step 1. Ship with a models-list request, an opt-in live smoke test gated by an environment variable like `OllamaCloudIntegrationTests`, and the app and CLI wiring.
3. **Vercel AI Gateway target.** Nearly identical shape to OpenRouter. If the two share more than the base URL and error type, extract an internal helper inside the OpenAI target rather than a third public module.
4. **Single-vendor providers** from the table above, one at a time, in whatever order has demand. Each is a day of work once step 1 is in.
5. **Optional: Anthropic-compatible path through the gateways.** Custom model IDs and header configuration on the `Anthropic` target.

## Alternative considered

A single generic `OpenAICompatible` provider configured with an ID, base URL, key, and headers would avoid one module per provider. It is blocked by two protocol facts: `requestValidators` is static, so two instances of one type cannot claim different models, and `LangToolchain` keys providers by type name, so a second instance replaces the first. Lifting both (instance-level `canHandleRequest` as a protocol requirement with the current default, toolchain keyed by a provider ID) is a reasonable later refactor, but the per-module convention matches the existing targets, tests, and READMEs and is the faster path for the first two gateways.
