# Gemini

Google's Gemini models for LangTools, in two formats from one `Gemini` client:

- The **OpenAI-compatible API** (`https://generativelanguage.googleapis.com/v1beta/openai/`) takes `OpenAI.ChatCompletionRequest`s. `Gemini.chatRequest(...)` builds these.
- The **native API** (`models/{model}:generateContent`) takes `Gemini.GenerateContentRequest`s, adding grounding with Google Search, thinking configuration and thought signatures, safety settings, top-k sampling, cached content, and inline media parts.

```swift
let gemini = Gemini(apiKey: ProcessInfo.processInfo.environment["GEMINI_API_KEY"]!)
```

## OpenAI format

```swift
let request = OpenAI.ChatCompletionRequest(
    model: Gemini.Model.gemini3Flash,
    messages: [.init(role: .user, content: "Tell me about quantum computing.")]
)
let response = try await gemini.perform(request: request)
```

`Gemini.Model` cases route here untagged. Any other model ID can be sent as `"gemini-3.5-flash-preview" as OpenAICompatibleModel<Gemini>`; streaming, tool calling, and structured output work as in the [OpenAI module](../OpenAI/README.md).

## Native format

```swift
let request = Gemini.GenerateContentRequest(
    model: .gemini3Flash,                     // or modelID: "gemini-3.5-flash-preview"
    messages: [.init(role: .user, content: "What changed in Swift 6.2?")],
    googleSearch: true,
    generationConfig: .init(thinkingConfig: .init(thinkingLevel: "low"))
)
for try await chunk in gemini.stream(request: request) {
    print(chunk.delta?.content ?? "", terminator: "")
}
```

- **Grounding:** `googleSearch: true` adds the Google Search tool; sources and supported spans arrive in `candidates[0].groundingMetadata`.
- **Function calling:** `tools` takes `OpenAI.Tool`s, sent as `functionDeclarations`, and runs them through the LangTools tool loop. `functionCallingMode` sets `AUTO`, `ANY`, `NONE`, or `VALIDATED`.
- **Thought signatures:** Gemini 3 requires the signature it returned with a function call to come back with that call. Messages keep them, and a call replayed without one (for example, from another provider's history) gets Google's documented `skip_thought_signature_validator` placeholder.
- **Structured output:** `responseSchema` sets `responseMimeType` and `responseJsonSchema`. `const` is sent as a one-value `enum`, which Gemini accepts.
- **Thinking:** `thinkingConfig` takes `thinkingLevel` (Gemini 3) or `thinkingBudget` (Gemini 2.5); with `includeThoughts`, thought summaries arrive as `thought` parts and are left out of `content`.
- **Media:** build a `Gemini.Message` from `Part`s with `inlineData` or `fileData`.
- **Failures:** a blocked prompt, a candidate stopped for safety, recitation, or a malformed function call, and an error sent mid-stream throw `LangToolsError.apiError` (`Gemini.NativeError`). A stream must end with a finish reason.

The model travels in the URL, so a request can name any model by `modelID`, including `tunedModels/...`. Its `model` property is the matching `Gemini.Model` case, or `.gemini3Flash` for IDs outside the enum.

## Models

```swift
let models = try await gemini.listModels()   // GET v1beta/models, all pages
let chatModels = models.filter(\.isChatModel) // supports generateContent
```

Entries carry `contextWindow` (`inputTokenLimit`) and `maxOutputTokens` (`outputTokenLimit`).

## Errors

`GeminiErrorResponse` decodes both the OpenAI-compatible error body and the native `{"error": {"code", "message", "status"}}` body, where `error.type` is the status:

```swift
do {
    let response = try await gemini.perform(request: request)
} catch LangToolsError.responseUnsuccessful(_, let error as GeminiErrorResponse) {
    print("Gemini API error:", error.error.message)
}
```

See also the [Gemini API reference](https://ai.google.dev/api).
