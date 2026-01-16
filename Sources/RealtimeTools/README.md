# RealtimeTools

RealtimeTools provides a configurable pipeline architecture for real-time audio processing with TTS (Text-to-Speech), STT (Speech-to-Text), and LLM providers.

## Features

- **Modular Pipeline Architecture**: Mix and match different providers for STT, TTS, and LLM
- **Multiple Pipeline Modes**: Speech-to-speech, modular (STT→LLM→TTS), transcription-only, or speech-only
- **Interruption Handling**: Built-in support for user interruptions with configurable behavior
- **VAD (Voice Activity Detection)**: Configurable voice activity detection for turn-based conversations
- **On-Device Support**: Integration with Apple's Speech framework for on-device recognition
- **Audio Processing**: Configurable sample rates, formats, and audio processing settings

## Usage

### Basic Pipeline Setup

```swift
import RealtimeTools

// Create a modular pipeline with Apple STT and ElevenLabs TTS
let pipeline = RealtimePipelineBuilder()
    .withMode(.modular)
    .withSTT(STTProviderConfiguration(provider: .appleOnDevice))
    .withTTS(TTSProviderConfiguration(provider: .elevenLabs, voice: "your-voice-id"))
    .withLLM(LLMProviderConfiguration(provider: .openAI, model: "gpt-4o"))
    .withInterruption(InterruptionConfiguration(enabled: true, mode: .immediate))
    .build()

// Set up event handlers
pipeline.eventHandler = RealtimeEventHandler()
pipeline.eventHandler?.onAudioReceived = { audioData in
    // Play the audio
}
pipeline.eventHandler?.onTranscriptReceived = { text, isFinal in
    // Display transcription
}

// Start the pipeline
try await pipeline.start()

// Send audio for processing
try await pipeline.sendAudio(audioData)
```

### Preset Configurations

```swift
// OpenAI Realtime (native speech-to-speech)
let openAIPipeline = RealtimePipelineBuilder.openAIRealtime().build()

// Modular with ElevenLabs
let elevenLabsPipeline = RealtimePipelineBuilder
    .modularWithElevenLabs(voice: "voice-id", llmModel: "gpt-4o")
    .build()

// Transcription only
let transcriptionPipeline = RealtimePipelineBuilder.transcriptionOnly().build()
```

## Provider Configuration

### STT Providers
- `appleOnDevice` - Apple's on-device Speech framework
- `openAIWhisper` - OpenAI Whisper API
- `openAIRealtime` - OpenAI Realtime API (native)
- `elevenLabsScribe` - ElevenLabs Scribe

### TTS Providers
- `appleOnDevice` - Apple's AVSpeechSynthesizer
- `openAI` - OpenAI TTS
- `openAIRealtime` - OpenAI Realtime API (native)
- `elevenLabs` - ElevenLabs

### LLM Providers
- `openAI` - OpenAI GPT models
- `anthropic` - Anthropic Claude models
- `openAIRealtime` - OpenAI Realtime API (native)
