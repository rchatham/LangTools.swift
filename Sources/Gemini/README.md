# Gemini

Google's Gemini models in two formats from one `Gemini` client:

- **Native** (`models/{model}:generateContent`): `Gemini.GenerateContentRequest`, which `Gemini.chatRequest` builds for a `Gemini.Model`. It adds Google Search grounding, thinking configuration, safety settings, top-k, cached content, and media parts.
- **OpenAI-compatible** (`v1beta/openai/`): `OpenAI.ChatCompletionRequest` with a `Gemini.Model`, or with any ID as `OpenAICompatibleModel<Gemini>`.

```swift
let gemini = Gemini(apiKey: ProcessInfo.processInfo.environment["GEMINI_API_KEY"]!)
let request = Gemini.GenerateContentRequest(
    model: .gemini3Flash,                     // or modelID: "gemini-3.5-flash-preview"
    messages: [.init(role: .user, content: "What changed in Swift 6.2?")],
    googleSearch: true,
    generationConfig: .init(thinkingConfig: ["thinkingLevel": "low"])
)
for try await chunk in gemini.stream(request: request) { print(chunk.delta?.content ?? "", terminator: "") }
```

- **Grounding:** sources and supported spans arrive in `candidates[0].groundingMetadata`.
- **Tools:** `tools` takes `OpenAI.Tool`s and runs them through the LangTools tool loop; `functionCallingMode` sets `AUTO`, `ANY`, `NONE`, or `VALIDATED`.
- **Thought signatures:** Gemini 3 needs the signature it returned with a function call sent back with that call. Messages keep them; a call replayed without one gets Google's `skip_thought_signature_validator` placeholder.
- **History:** `Gemini.Message(_:)` converts another provider's messages, tool calls and results included.
- **Structured output:** `responseSchema` sets `responseJsonSchema` (`const` is sent as a one-value `enum`).
- **Failures:** blocked prompts, safety or malformed-call stops, and mid-stream errors throw `LangToolsError.apiError` (`Gemini.NativeError`); a stream must end with a finish reason.
- **Models:** `listModels()` reads the native catalog with token limits.
- **Errors:** `GeminiErrorResponse` decodes both APIs' error bodies; for a native error, `error.type` is its status.
