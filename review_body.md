<!-- claude-code-review -->

## Code Review: `refactor/provider-abstractions` (#34) — Updated 2026-06-22

This PR introduces provider-neutral protocol abstractions for TTS and STT (Apple Speech, OpenAI Whisper, WhisperKit) in the same idiom as existing LangTools request types. The layering is well-considered and the test coverage for the new protocols is solid. A new review pass over the current branch confirms the retroactive conformance issue from the prior review is still open, and surfaces four additional actionable findings.

---

### Blockers / High priority

#### 1. `SpeechSynthesisProviding` has no async synthesis method — the protocol is unusable for API-backed TTS

`Sources/LangTools/LangTools+Providers.swift`, `Sources/OpenAI/OpenAISpeechSynthesisProvider.swift`

The protocol exposes only `speak(_ request:) throws` and `stopSpeaking()`. Its sole conformer, `OpenAISpeechSynthesisProvider`, unconditionally throws from `speak`, while the actual synthesis lives in `synthesize(_:voice:) async throws` — which is **not on the protocol**. A caller holding `any SpeechSynthesisProviding` cannot produce audio at all. Add `func synthesize(_ request: LangToolsSpeechSynthesisInput) async throws -> any LangToolsAudioResponse` to the protocol (with a default that throws `.unsupported` for on-device providers), or split into `LiveSpeechSynthesisProviding` / `AsyncSpeechSynthesisProviding`.

#### 2. `isSpeaking` never set to `true` in `OpenAISpeechSynthesisProvider`

`Sources/OpenAI/OpenAISpeechSynthesisProvider.swift`

`isSpeaking` is initialized `false`, `stopSpeaking()` sets it `false`, but `synthesize()` never toggles it. Any UI or guard checking `isSpeaking` always sees `false` even mid-network-call. Wrap the perform call: `isSpeaking = true; defer { isSpeaking = false }`.

#### 3. Retroactive conformances missing `@retroactive` — still open from prior review

`Sources/LangTools/LangTools+Speech.swift` lines 10 and 20:

The prior review noted `3c4eac9` as fixing this, but the annotation is absent from the current branch. Swift 5.7+ warns; Swift 6 strict mode errors. A downstream dependency that independently conforms `Data` to `LangToolsAudioResponse` produces undefined behavior at link time. Fix: `extension Data: @retroactive LangToolsAudioResponse` and `extension String: @retroactive LangToolsTranscriptionResponse`.

#### 4. `transcribe(audioData: Data)` hardcodes `.wav` but accepts any format — silent API error

`Sources/OpenAI/OpenAISpeechRecognitionProvider.swift`

The protocol-bridging overload calls `transcribe(audioData: audioData, fileType: .wav, ...)` unconditionally. A caller passing M4A or CAF gets an HTTP 400 or garbled transcription from Whisper with no diagnostic. Unlike `AppleSpeechRecognitionProvider` (which converts internally), this path does zero format conversion. Either convert to WAV inside the method, or surface the format requirement at the type level.

---

### Medium priority

#### 5. `voiceIdentifier` in `LangToolsSpeechSynthesisInput` is silently ignored

`Examples/LangTools_Example/Modules/Chat/Services/NetworkClient.swift` / `Sources/OpenAI/OpenAISpeechSynthesisProvider.swift`

The voice is specified twice at the call site (`voiceIdentifier: "alloy"` in the input struct and `voice: .alloy` as a parameter). Inside `synthesize`, `OpenAI.AudioSpeechRequest` is built from the typed `voice:` argument; `request.voiceIdentifier` is never read. Changing `voiceIdentifier` has no effect. Either parse `request.voiceIdentifier` to derive the voice enum (removing the redundant parameter), or drop `voiceIdentifier` from `LangToolsSpeechSynthesisInput`.

#### 6. `speak` throws `liveRecognitionUnsupported` — wrong error domain for synthesis

`Sources/OpenAI/OpenAISpeechSynthesisProvider.swift`

`OpenAISpeechProviderError.liveRecognitionUnsupported` is the STT provider's error; its `errorDescription` says "does not support live recognition." Throwing it from a TTS `speak()` call surfaces a recognition-domain message for a synthesis failure. Add `liveSynthesisUnsupported` (or a shared `liveOutputUnsupported`) and use it here.

#### 7. `@available` on a protocol requirement without availability on the protocol — false safety signal

`Sources/LangTools/LangTools+Providers.swift`

`startDualLanguageRecognition` carries `@available(iOS 16, macOS 13, *)` but the enclosing `SpeechRecognitionProviding` protocol has no availability restriction. Code calling this method on a concrete conformer on iOS 15 compiles without an `#available` check and reaches a runtime throw. Either restrict the protocol itself with `@available(iOS 16, macOS 13, *)` or factor the method into a separate `DualLanguageSpeechRecognitionProviding` protocol that carries the availability.

---

### Low priority / Cleanup

#### 8. Duplicate WAV conversion logic in Apple and WhisperKit targets

`Sources/Apple/AppleSpeechRecognitionProvider.swift` (`AppleLangToolsAudioConverter`) and `Sources/WhisperKit/WhisperKitSpeechRecognitionProvider.swift` (`WhisperKitLangToolsAudioConverter`) are identical AVFoundation implementations differing only in error type. A fix to the conversion logic (e.g. resampling to 16 kHz for Whisper) must be applied in both places independently. Extract into a single shared internal utility.

---

### Summary

| # | Severity | Finding |
|---|----------|---------|
| 1 | High | `SpeechSynthesisProviding` has no async synthesis — abstraction broken for API TTS |
| 2 | High | `isSpeaking` never `true` during active `synthesize()` call |
| 3 | High | `@retroactive` still missing on `Data`/`String` conformances (from prior review) |
| 4 | High | `transcribe(audioData:)` hardcodes `.wav` — silent API errors for other formats |
| 5 | Medium | `voiceIdentifier` in `LangToolsSpeechSynthesisInput` silently ignored |
| 6 | Medium | Wrong error domain (`liveRecognitionUnsupported`) thrown by synthesis provider |
| 7 | Medium | `@available` on protocol requirement without protocol-level availability |
| 8 | Low | Duplicate WAV converter in Apple and WhisperKit targets |

Items 1–4 should be addressed before merge.
