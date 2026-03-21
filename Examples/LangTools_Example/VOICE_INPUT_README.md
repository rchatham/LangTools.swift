# Voice Input Integration Guide

This example demonstrates how to integrate speech-to-text (STT) functionality using the reorganized LangTools architecture.

## Overview

The voice input implementation consists of:
1. **AppleSpeech Module** - On-device speech recognition using Apple's Speech framework
2. **Audio Utilities** - Recording, conversion, and playback (in `Modules/Audio/`)
3. **ChatUI Integration** - Voice input handler protocol for chat interface
4. **VoiceInputHandlerExample** - Complete implementation example

## Architecture

```
┌─────────────────────────────────────┐
│   ChatUI (VoiceInputHandler)       │
│   Protocol-based voice input UI     │
└──────────────┬──────────────────────┘
               │
┌──────────────▼──────────────────────┐
│ VoiceInputHandlerExample            │
│ Implements VoiceInputHandler        │
│ - Manages recording state           │
│ - Handles permissions               │
│ - Coordinates transcription         │
└──────────────┬──────────────────────┘
               │
      ┌────────┴────────┐
      │                 │
┌─────▼─────┐    ┌─────▼─────────────┐
│ AVFoundation│   │ AppleSpeech Module │
│ Audio Engine│   │ Speech Recognition │
│ Recording   │   │ (SFSpeechRecognizer)│
└─────────────┘   └───────────────────┘
```

## Setup Instructions

### 1. Add Dependencies

The example app needs these package dependencies:

```swift
// Package.swift or Xcode project settings
dependencies: [
    .package(path: "../../"),  // LangTools.swift
    // Add ChatUI if not already included
]

// In your target:
dependencies: [
    .product(name: "AppleSpeech", package: "langtools.swift"),
    .product(name: "ChatUI", package: "ChatUI"),  // If using separate package
]
```

### 2. Add Required Permissions

Add these keys to your `Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>We need microphone access to transcribe your voice input</string>
<key>NSSpeechRecognitionUsageDescription</key>
<string>We need speech recognition to convert your voice to text</string>
```

### 3. Implement Voice Input Handler

See `LangTools_Example/VoiceInputHandlerExample.swift` for a complete implementation.

Key components:

```swift
import ChatUI
import AppleSpeech
import AVFoundation

@MainActor
class VoiceInputHandlerExample: ObservableObject, VoiceInputHandler {
    // Protocol requirements
    var isRecording: Bool { _isRecording }
    var isProcessing: Bool { _isProcessing }
    var audioLevel: Float { _audioLevel }
    var statusDescription: String { _statusDescription }

    func toggleRecording() async {
        if isRecording {
            await stopAndTranscribe()
        } else {
            await startRecording()
        }
    }

    private func stopAndTranscribe() async {
        // 1. Stop audio recording
        let audioData = stopAudioRecording()

        // 2. Convert CAF to WAV
        let wavURL = try convertToWAV(audioData: audioData)

        // 3. Create transcription request
        let request = AppleSpeech.TranscriptionRequest(
            audioURL: wavURL,
            locale: .current,
            reportPartialResults: true,
            taskHint: .unspecified
        )

        // 4. Execute transcription
        let transcript = try await request.execute()

        // 5. Store result for retrieval
        transcribedText = transcript
    }
}
```

### 4. Wire into ChatView

```swift
import SwiftUI
import ChatUI

@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            let messageService = MyMessageService()
            let voiceHandler = VoiceInputHandlerExample.shared

            ChatView(
                title: "My Chat App",
                messageService: messageService,
                voiceInputHandler: voiceHandler,  // ← Add this
                settingsView: { MySettingsView() }
            )
        }
    }
}
```

## Features Demonstrated

### 1. On-Device Speech Recognition
- Uses Apple's Speech framework for privacy-preserving transcription
- No API keys or internet connection required
- Supports multiple locales via `AppleSpeech.supportedLocales`

### 2. Real-Time Audio Monitoring
- Visual feedback via `audioLevel` property
- Waveform visualization available in ChatUI

### 3. Asynchronous Permission Handling
```swift
let authorized = await AppleSpeech.requestAuthorization()
if authorized == .authorized {
    // Proceed with recording
}
```

### 4. Audio Format Conversion
- Records in CAF format (Core Audio Format)
- Converts to WAV for Speech framework compatibility
- Automatic cleanup of temporary files

## API Reference

### AppleSpeech Module

#### Request Authorization
```swift
let status = await AppleSpeech.requestAuthorization()
// Returns: SFSpeechRecognizerAuthorizationStatus
```

#### Check Supported Locales
```swift
let locales = AppleSpeech.supportedLocales
// Returns: Set<Locale>
```

#### Create Transcription Request
```swift
let request = AppleSpeech.TranscriptionRequest(
    audioURL: URL,              // Path to audio file (WAV format)
    locale: Locale,             // Transcription language
    reportPartialResults: Bool, // Stream partial results
    taskHint: SFSpeechRecognitionTaskHint  // Optimization hint
)

let transcript = try await request.execute()
```

### VoiceInputHandler Protocol

```swift
protocol VoiceInputHandler: AnyObject {
    // State properties
    var isRecording: Bool { get }
    var isProcessing: Bool { get }
    var audioLevel: Float { get }  // 0.0 to 1.0
    var statusDescription: String { get }
    var partialText: String { get }
    var pendingTranscribedText: String? { get set }

    // Settings
    var isEnabled: Bool { get }
    var replaceSendButton: Bool { get }

    // Actions
    func toggleRecording() async
    func cancelRecording()
    func getTranscribedText() -> String?
}
```

## Troubleshooting

### Build Errors

**"No such module 'AppleSpeech'"**
- Ensure AppleSpeech is added as a package dependency
- Clean build folder: `swift package clean`

**"No such module 'ChatUI'"**
- Add ChatUI package to your project
- Or copy VoiceInputHandler protocol locally

### Runtime Issues

**"Speech recognition not available"**
- Check device/simulator supports Speech framework
- Verify Info.plist contains required permission keys
- Some languages may not be supported - check `AppleSpeech.supportedLocales`

**"Microphone permission denied"**
- Request permissions before first use
- Guide users to Settings app to grant permission

### Audio Quality

**Poor transcription accuracy:**
- Ensure quiet environment
- Speak clearly and at moderate pace
- Check microphone is not obstructed
- Try different `task Hint` values (dictation, search, confirmation)

## Next Steps

### Add More STT Providers

The architecture supports multiple STT providers:

1. **OpenAI Whisper** (already in OpenAI module)
2. **WhisperKit** (local ML-based, requires separate module)
3. **Custom providers** via `LangToolsSTTRequest` protocol

### Add Audio Playback

Use the audio components in ChatUI:

```swift
import ChatUI

AudioMessageView(
    isPlaying: $isPlaying,
    currentTime: player.currentTime,
    duration: player.duration,
    audioLevel: player.level,
    onPlayPause: { player.togglePlayback() },
    onSeek: { time in player.seek(to: time) }
)
```

### Settings Integration

Add STT provider selection to your settings view:

```swift
Picker("STT Provider", selection: $selectedProvider) {
    Text("Apple Speech").tag(STTProvider.appleSpeech)
    Text("OpenAI Whisper").tag(STTProvider.openAI)
    Text("WhisperKit").tag(STTProvider.whisperKit)
}
```

## Resources

- [AppleSpeech Module Documentation](../../Sources/AppleSpeech/README.md)
- [ChatUI Audio Components](../../../ChatUI/Sources/ChatUI/Audio/)
- [Apple Speech Framework](https://developer.apple.com/documentation/speech)
- [LangTools STT Protocol](../../Sources/LangTools/LangTools+Request.swift)

## License

Same as LangTools.swift project.
