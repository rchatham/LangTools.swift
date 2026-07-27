//
//  RealtimeTools.swift
//  RealtimeTools
//
//  Created by Reid Chatham on 1/16/26.
//

import Foundation
import LangTools

// MARK: - Realtime Pipeline Configuration

/// Configuration for a modular realtime pipeline with TTS/STT/LLM providers
public struct RealtimePipelineConfiguration: Sendable {
    /// Speech-to-Text provider configuration
    public var sttProvider: STTProviderConfiguration?

    /// Text-to-Speech provider configuration
    public var ttsProvider: TTSProviderConfiguration?

    /// LLM provider configuration (optional for direct speech-to-speech)
    public var llmProvider: LLMProviderConfiguration?

    /// Pipeline mode
    public var mode: PipelineMode

    /// Audio processing settings
    public var audioSettings: AudioProcessingSettings

    public init(
        sttProvider: STTProviderConfiguration? = nil,
        ttsProvider: TTSProviderConfiguration? = nil,
        llmProvider: LLMProviderConfiguration? = nil,
        mode: PipelineMode = .speechToSpeech,
        audioSettings: AudioProcessingSettings = .default
    ) {
        self.sttProvider = sttProvider
        self.ttsProvider = ttsProvider
        self.llmProvider = llmProvider
        self.mode = mode
        self.audioSettings = audioSettings
    }

    /// Pipeline operating mode
    public enum PipelineMode: String, Codable, Sendable {
        /// Direct speech-to-speech using native multimodal model (e.g., OpenAI Realtime)
        case speechToSpeech

        /// Separate STT -> LLM -> TTS pipeline
        case modular

        /// Transcription only (STT)
        case transcriptionOnly

        /// Text-to-Speech only
        case speechOnly
    }
}

// MARK: - STT Provider Configuration

/// Configuration for Speech-to-Text providers
public struct STTProviderConfiguration: Sendable {
    public var provider: STTProvider
    public var language: String?
    public var enableInterimResults: Bool
    public var enablePunctuation: Bool
    public var enableWordTimestamps: Bool
    public var customVocabulary: [String]?

    public init(
        provider: STTProvider,
        language: String? = nil,
        enableInterimResults: Bool = true,
        enablePunctuation: Bool = true,
        enableWordTimestamps: Bool = false,
        customVocabulary: [String]? = nil
    ) {
        self.provider = provider
        self.language = language
        self.enableInterimResults = enableInterimResults
        self.enablePunctuation = enablePunctuation
        self.enableWordTimestamps = enableWordTimestamps
        self.customVocabulary = customVocabulary
    }

    /// Available STT providers
    public enum STTProvider: String, Codable, Sendable {
        /// Apple's on-device Speech framework
        case appleOnDevice = "apple_on_device"

        /// OpenAI Whisper via API
        case openAIWhisper = "openai_whisper"

        /// OpenAI Realtime API (native speech-to-speech)
        case openAIRealtime = "openai_realtime"

        /// ElevenLabs Scribe
        case elevenLabsScribe = "elevenlabs_scribe"

        /// Custom provider
        case custom
    }
}

// MARK: - TTS Provider Configuration

/// Configuration for Text-to-Speech providers
public struct TTSProviderConfiguration: Sendable {
    public var provider: TTSProvider
    public var voice: String
    public var model: String?
    public var speed: Double
    public var stability: Double?
    public var similarityBoost: Double?
    public var style: Double?
    public var outputFormat: TTSOutputFormat

    public init(
        provider: TTSProvider,
        voice: String,
        model: String? = nil,
        speed: Double = 1.0,
        stability: Double? = nil,
        similarityBoost: Double? = nil,
        style: Double? = nil,
        outputFormat: TTSOutputFormat = .pcm16_24000
    ) {
        self.provider = provider
        self.voice = voice
        self.model = model
        self.speed = speed
        self.stability = stability
        self.similarityBoost = similarityBoost
        self.style = style
        self.outputFormat = outputFormat
    }

    /// Available TTS providers
    public enum TTSProvider: String, Codable, Sendable {
        /// Apple's on-device AVSpeechSynthesizer
        case appleOnDevice = "apple_on_device"

        /// OpenAI TTS
        case openAI = "openai"

        /// OpenAI Realtime API (native speech-to-speech)
        case openAIRealtime = "openai_realtime"

        /// ElevenLabs
        case elevenLabs = "elevenlabs"

        /// Custom provider
        case custom
    }

    /// TTS output format options
    public enum TTSOutputFormat: String, Codable, Sendable {
        case pcm16_24000 = "pcm_24000"
        case pcm16_22050 = "pcm_22050"
        case pcm16_16000 = "pcm_16000"
        case pcm16_44100 = "pcm_44100"
        case mp3_128 = "mp3_128kbps"
        case mp3_192 = "mp3_192kbps"
        case opus
        case mulaw_8000 = "ulaw_8000"

        public var sampleRate: Int {
            switch self {
            case .pcm16_24000: return 24000
            case .pcm16_22050: return 22050
            case .pcm16_16000: return 16000
            case .pcm16_44100: return 44100
            case .mp3_128, .mp3_192: return 44100
            case .opus: return 48000
            case .mulaw_8000: return 8000
            }
        }

        public var isPCM: Bool {
            switch self {
            case .pcm16_24000, .pcm16_22050, .pcm16_16000, .pcm16_44100:
                return true
            default:
                return false
            }
        }
    }
}

// MARK: - LLM Provider Configuration

/// Configuration for LLM providers in the pipeline
public struct LLMProviderConfiguration: Sendable {
    public var provider: LLMProvider
    public var model: String
    public var systemPrompt: String?
    public var temperature: Double?
    public var maxTokens: Int?

    public init(
        provider: LLMProvider,
        model: String,
        systemPrompt: String? = nil,
        temperature: Double? = nil,
        maxTokens: Int? = nil
    ) {
        self.provider = provider
        self.model = model
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.maxTokens = maxTokens
    }

    /// Available LLM providers
    public enum LLMProvider: String, Codable, Sendable {
        case openAI = "openai"
        case anthropic = "anthropic"
        case openAIRealtime = "openai_realtime"
        case custom
    }
}

// MARK: - Audio Processing Settings

/// Settings for audio processing in the pipeline
public struct AudioProcessingSettings: Sendable {
    /// Sample rate for audio input
    public var inputSampleRate: Int

    /// Sample rate for audio output
    public var outputSampleRate: Int

    /// Number of audio channels
    public var channels: Int

    /// Bits per sample
    public var bitsPerSample: Int

    /// Enable echo cancellation
    public var echoCancellation: Bool

    /// Enable noise suppression
    public var noiseSuppression: Bool

    /// Enable automatic gain control
    public var automaticGainControl: Bool

    /// Voice Activity Detection configuration
    public var vadConfig: VADConfiguration?

    public init(
        inputSampleRate: Int = 16000,
        outputSampleRate: Int = 24000,
        channels: Int = 1,
        bitsPerSample: Int = 16,
        echoCancellation: Bool = true,
        noiseSuppression: Bool = true,
        automaticGainControl: Bool = true,
        vadConfig: VADConfiguration? = nil
    ) {
        self.inputSampleRate = inputSampleRate
        self.outputSampleRate = outputSampleRate
        self.channels = channels
        self.bitsPerSample = bitsPerSample
        self.echoCancellation = echoCancellation
        self.noiseSuppression = noiseSuppression
        self.automaticGainControl = automaticGainControl
        self.vadConfig = vadConfig
    }

    public static let `default` = AudioProcessingSettings()

    /// Optimized for OpenAI Realtime
    public static let openAIRealtime = AudioProcessingSettings(
        inputSampleRate: 24000,
        outputSampleRate: 24000,
        channels: 1,
        bitsPerSample: 16
    )

    /// Optimized for ElevenLabs
    public static let elevenLabs = AudioProcessingSettings(
        inputSampleRate: 16000,
        outputSampleRate: 22050,
        channels: 1,
        bitsPerSample: 16
    )
}

// MARK: - VAD Configuration

/// Voice Activity Detection configuration
public struct VADConfiguration: Sendable {
    public var mode: VADMode
    public var threshold: Double
    public var minSpeechDuration: TimeInterval
    public var maxSpeechDuration: TimeInterval
    public var silenceTimeout: TimeInterval
    public var prefixPadding: TimeInterval

    public init(
        mode: VADMode = .automatic,
        threshold: Double = 0.5,
        minSpeechDuration: TimeInterval = 0.1,
        maxSpeechDuration: TimeInterval = 30.0,
        silenceTimeout: TimeInterval = 0.5,
        prefixPadding: TimeInterval = 0.3
    ) {
        self.mode = mode
        self.threshold = threshold
        self.minSpeechDuration = minSpeechDuration
        self.maxSpeechDuration = maxSpeechDuration
        self.silenceTimeout = silenceTimeout
        self.prefixPadding = prefixPadding
    }

    public enum VADMode: String, Codable, Sendable {
        /// Use server-side VAD (e.g., OpenAI Realtime)
        case server

        /// Use on-device VAD
        case onDevice

        /// Automatic based on provider capabilities
        case automatic

        /// Manual push-to-talk
        case manual
    }
}

// MARK: - Interruption Configuration

/// Configuration for handling interruptions
public struct InterruptionConfiguration: Sendable {
    /// Enable interruption support
    public var enabled: Bool

    /// How to handle interruptions
    public var mode: InterruptionMode

    /// Minimum audio played before allowing interruption (in seconds)
    public var minPlaybackBeforeInterrupt: TimeInterval

    /// Debounce time for speech detection to prevent false interrupts
    public var speechDetectionDebounce: TimeInterval

    public init(
        enabled: Bool = true,
        mode: InterruptionMode = .immediate,
        minPlaybackBeforeInterrupt: TimeInterval = 0.5,
        speechDetectionDebounce: TimeInterval = 0.1
    ) {
        self.enabled = enabled
        self.mode = mode
        self.minPlaybackBeforeInterrupt = minPlaybackBeforeInterrupt
        self.speechDetectionDebounce = speechDetectionDebounce
    }

    public enum InterruptionMode: String, Codable, Sendable {
        /// Immediately stop playback and cancel response
        case immediate

        /// Fade out audio and cancel response
        case fadeOut

        /// Queue the interruption until current response completes
        case queued

        /// Only interrupt at natural sentence boundaries
        case sentenceBoundary
    }
}
