# ElevenLabs

ElevenLabs API integration for high-quality text-to-speech and speech-to-text.

## Features

- **Text-to-Speech**: High-quality voice synthesis with multiple models
- **WebSocket Streaming TTS**: Real-time text-to-speech with low latency
- **Speech-to-Text (Scribe)**: Real-time transcription via WebSocket
- **Voice Library**: Access to ElevenLabs voice library
- **Multiple Output Formats**: PCM, MP3, μ-law support

## Usage

### Basic TTS

```swift
import ElevenLabs

let elevenLabs = ElevenLabs(apiKey: "your-api-key")

// Simple TTS request
let request = ElevenLabs.TextToSpeechRequest(
    text: "Hello, world!",
    voiceId: "your-voice-id",
    modelId: ElevenLabsModel.elevenFlashV2_5.id
)

let audioData = try await elevenLabs.perform(request: request)
```

### WebSocket Streaming TTS

```swift
// Create WebSocket session for real-time TTS
let session = elevenLabs.createWebSocketSession(
    voiceId: "your-voice-id",
    modelId: ElevenLabsModel.elevenFlashV2_5.id,
    outputFormat: .pcm_24000
)

try await session.connect()

// Stream text and receive audio
Task {
    for try await chunk in session.audioStream {
        // Play audio chunk
        playAudio(chunk.audio)
    }
}

// Send text for synthesis
try await session.send(text: "Hello, ")
try await session.send(text: "how are you today?", flush: true)

// End the stream when done
try await session.endStream()
```

### Real-time Speech-to-Text

```swift
// Create STT session
let sttSession = elevenLabs.createSTTSession(
    modelId: ElevenLabsModel.scribeRealtimeV2.id,
    language: "en",
    enablePartials: true
)

try await sttSession.connect()

// Process transcriptions
Task {
    for try await transcription in sttSession.transcriptions {
        if transcription.isFinal {
            print("Final: \(transcription.text)")
        } else {
            print("Partial: \(transcription.text)")
        }
    }
}

// Send audio for transcription
try await sttSession.send(audio: audioData)
```

## Models

### TTS Models
- `elevenMultilingualV2` - Best quality, 29 languages
- `elevenFlashV2_5` - Fastest, 75ms latency
- `elevenTurboV2_5` - Fast, good quality
- `elevenTurboV2` - Previous generation turbo

### STT Models
- `scribeV1` - Standard transcription
- `scribeRealtimeV2` - Real-time streaming transcription

## Voice Settings

```swift
let settings = VoiceSettings(
    stability: 0.5,        // 0-1, higher = more stable
    similarityBoost: 0.75, // 0-1, higher = more similar to original
    style: 0.0,            // 0-1, style exaggeration
    useSpeakerBoost: true  // Enhance speaker clarity
)
```
