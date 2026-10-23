# AppleSpeech

On-device speech recognition using Apple's Speech framework.

## Overview

AppleSpeech provides privacy-first, offline-capable speech-to-text using Apple's Speech framework. It runs completely on-device without sending data to external servers.

## Features

- ✅ On-device processing (privacy-first)
- ✅ Offline capability
- ✅ Multiple language support
- ✅ Partial results during recognition
- ✅ Task hints for better accuracy
- ✅ iOS 16+, macOS 14+

## Usage

### Authorization

Request permission before using speech recognition:

```swift
import AppleLangTools

// Request authorization
let status = await AppleSpeech.requestAuthorization()
guard status == .authorized else {
    print("Speech recognition not authorized")
    return
}
```

### Basic Transcription

Transcribe an audio file:

```swift
// Create transcription request
let request = AppleSpeech.TranscriptionRequest(
    audioURL: audioFileURL,
    locale: Locale(identifier: "en-US")
)

// Execute transcription
do {
    let transcript = try await request.execute()
    print("Transcript: \(transcript)")
} catch {
    print("Transcription failed: \(error)")
}
```

### Language Support

Check supported locales:

```swift
let supportedLocales = AppleSpeech.supportedLocales
for locale in supportedLocales {
    print("Supported: \(locale.identifier)")
}
```

Use a specific language:

```swift
let request = AppleSpeech.TranscriptionRequest(
    audioURL: audioFileURL,
    locale: Locale(identifier: "es-ES") // Spanish (Spain)
)
```

### Task Hints

Provide hints for better recognition accuracy:

```swift
let request = AppleSpeech.TranscriptionRequest(
    audioURL: audioFileURL,
    locale: .current,
    taskHint: .dictation // or .search, .confirmation
)
```

## Platform Support

- iOS 16.0+
- macOS 14.0+

## Error Handling

```swift
do {
    let transcript = try await request.execute()
} catch AppleSpeechError.localeNotSupported(let locale) {
    print("Locale not supported: \(locale)")
} catch AppleSpeechError.permissionDenied {
    print("Permission denied")
} catch AppleSpeechError.noSpeechDetected {
    print("No speech found in audio")
} catch {
    print("Transcription error: \(error)")
}
```

## Privacy

AppleSpeech processes all audio on-device. No data is sent to external servers. Users must grant speech recognition permission in Settings > Privacy > Speech Recognition.

# AppleIntelligence

On-device text generation using Apple's Foundation Models framework, exposed through the same `LangTools` interface as the network providers.

## Requirements

- iOS 26 / macOS 26 / visionOS 26 on Apple Intelligence–capable hardware, with Apple Intelligence enabled.
- The iOS Simulator uses the host Mac's model, so the host must itself run macOS 26 with Apple Intelligence enabled.
- The type is available on every supported OS; check `AppleIntelligence.availability()` at runtime.

## Usage

```swift
import AppleLangTools
import LangTools

var toolchain = LangToolchain()
toolchain.register(AppleIntelligence())

let request = AppleIntelligence.ChatRequest(
    model: .onDevice,
    messages: [
        AppleIntelligence.Message(role: .system, string: "Be concise."),
        AppleIntelligence.Message(role: .user, string: "Name three moons of Jupiter."),
    ],
    stream: true,
    temperature: 0.4,
    maximumResponseTokens: 200
)

for try await chunk in toolchain.stream(request: request) {
    print(chunk.delta?.content ?? "", terminator: "")
}
```

Each request rebuilds a `LanguageModelSession` from the message history: system messages become instructions, earlier turns are replayed as transcript entries, and the final user message is the prompt.

## Limitations

- Tool calling and structured output are not bridged yet (`chatRequest` throws for either).
- The context window (~4K tokens) is shared by instructions, history, and the response. Older turns are dropped (newest first kept, ~1K tokens reserved for the reply) so long chats keep working; instructions and the current prompt are never trimmed.
