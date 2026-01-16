//
//  LangTools+Realtime.swift
//  LangTools
//
//  Created by Reid Chatham on 1/16/26.
//

import Foundation

// MARK: - Realtime Session Protocol

/// Protocol for providers that support realtime audio/text streaming via WebSocket
public protocol LangToolsRealtime: LangTools {
    associatedtype RealtimeSession: LangToolsRealtimeSession

    /// Creates a new realtime session
    func createRealtimeSession(configuration: RealtimeSessionConfiguration) async throws -> RealtimeSession
}

// MARK: - Realtime Session

/// Protocol representing a realtime bidirectional session
public protocol LangToolsRealtimeSession: AnyObject {
    associatedtype ClientEvent: LangToolsRealtimeClientEvent
    associatedtype ServerEvent: LangToolsRealtimeServerEvent

    /// Unique identifier for this session
    var sessionId: String { get }

    /// Current state of the session
    var state: RealtimeSessionState { get }

    /// Stream of server events
    var events: AsyncThrowingStream<ServerEvent, Error> { get }

    /// Send a client event to the server
    func send(event: ClientEvent) async throws

    /// Update session configuration
    func updateSession(configuration: RealtimeSessionConfiguration) async throws

    /// Disconnect and clean up the session
    func disconnect() async
}

// MARK: - Session State

/// State of a realtime session
public enum RealtimeSessionState: String, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case error
}

// MARK: - Session Configuration

/// Configuration for a realtime session
public struct RealtimeSessionConfiguration: Codable, Sendable {
    /// Session type (conversation or transcription)
    public var type: SessionType?

    /// Modalities to use (text, audio, or both)
    public var modalities: [Modality]?

    /// Instructions for the model
    public var instructions: String?

    /// Voice for audio output
    public var voice: String?

    /// Audio format for input
    public var inputAudioFormat: AudioFormat?

    /// Audio format for output
    public var outputAudioFormat: AudioFormat?

    /// Enable input audio transcription
    public var inputAudioTranscription: InputAudioTranscription?

    /// Turn detection settings
    public var turnDetection: TurnDetection?

    /// Tools available to the model
    public var tools: [RealtimeTool]?

    /// Tool choice strategy
    public var toolChoice: ToolChoice?

    /// Temperature for generation
    public var temperature: Double?

    /// Maximum tokens for responses
    public var maxResponseOutputTokens: MaxTokens?

    public init(
        type: SessionType? = nil,
        modalities: [Modality]? = nil,
        instructions: String? = nil,
        voice: String? = nil,
        inputAudioFormat: AudioFormat? = nil,
        outputAudioFormat: AudioFormat? = nil,
        inputAudioTranscription: InputAudioTranscription? = nil,
        turnDetection: TurnDetection? = nil,
        tools: [RealtimeTool]? = nil,
        toolChoice: ToolChoice? = nil,
        temperature: Double? = nil,
        maxResponseOutputTokens: MaxTokens? = nil
    ) {
        self.type = type
        self.modalities = modalities
        self.instructions = instructions
        self.voice = voice
        self.inputAudioFormat = inputAudioFormat
        self.outputAudioFormat = outputAudioFormat
        self.inputAudioTranscription = inputAudioTranscription
        self.turnDetection = turnDetection
        self.tools = tools
        self.toolChoice = toolChoice
        self.temperature = temperature
        self.maxResponseOutputTokens = maxResponseOutputTokens
    }

    public enum SessionType: String, Codable, Sendable {
        case conversation
        case transcription
    }

    public enum Modality: String, Codable, Sendable {
        case text
        case audio
    }

    public enum AudioFormat: String, Codable, Sendable {
        case pcm16
        case g711_ulaw
        case g711_alaw

        public var sampleRate: Int {
            switch self {
            case .pcm16: return 24000
            case .g711_ulaw, .g711_alaw: return 8000
            }
        }
    }

    public struct InputAudioTranscription: Codable, Sendable {
        public var model: String?

        public init(model: String? = nil) {
            self.model = model
        }
    }

    public struct TurnDetection: Codable, Sendable {
        public var type: TurnDetectionType
        public var threshold: Double?
        public var prefixPaddingMs: Int?
        public var silenceDurationMs: Int?
        public var createResponse: Bool?
        public var interruptResponse: Bool?

        public init(
            type: TurnDetectionType = .serverVad,
            threshold: Double? = nil,
            prefixPaddingMs: Int? = nil,
            silenceDurationMs: Int? = nil,
            createResponse: Bool? = nil,
            interruptResponse: Bool? = nil
        ) {
            self.type = type
            self.threshold = threshold
            self.prefixPaddingMs = prefixPaddingMs
            self.silenceDurationMs = silenceDurationMs
            self.createResponse = createResponse
            self.interruptResponse = interruptResponse
        }

        public enum TurnDetectionType: String, Codable, Sendable {
            case serverVad = "server_vad"
            case none
        }

        enum CodingKeys: String, CodingKey {
            case type, threshold
            case prefixPaddingMs = "prefix_padding_ms"
            case silenceDurationMs = "silence_duration_ms"
            case createResponse = "create_response"
            case interruptResponse = "interrupt_response"
        }
    }

    public struct RealtimeTool: Codable, Sendable {
        public var type: String
        public var name: String
        public var description: String?
        public var parameters: JSON?

        public init(type: String = "function", name: String, description: String? = nil, parameters: JSON? = nil) {
            self.type = type
            self.name = name
            self.description = description
            self.parameters = parameters
        }
    }

    public enum ToolChoice: Codable, Sendable {
        case auto
        case none
        case required
        case function(String)

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let str = try? container.decode(String.self) {
                switch str {
                case "auto": self = .auto
                case "none": self = .none
                case "required": self = .required
                default: self = .function(str)
                }
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid tool choice")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .auto: try container.encode("auto")
            case .none: try container.encode("none")
            case .required: try container.encode("required")
            case .function(let name): try container.encode(name)
            }
        }
    }

    public enum MaxTokens: Codable, Sendable {
        case count(Int)
        case infinite

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let str = try? container.decode(String.self), str == "inf" {
                self = .infinite
            } else if let count = try? container.decode(Int.self) {
                self = .count(count)
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid max tokens")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .infinite: try container.encode("inf")
            case .count(let n): try container.encode(n)
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case type, modalities, instructions, voice, tools, temperature
        case inputAudioFormat = "input_audio_format"
        case outputAudioFormat = "output_audio_format"
        case inputAudioTranscription = "input_audio_transcription"
        case turnDetection = "turn_detection"
        case toolChoice = "tool_choice"
        case maxResponseOutputTokens = "max_response_output_tokens"
    }
}

// MARK: - Realtime Events

/// Base protocol for client events
public protocol LangToolsRealtimeClientEvent: Encodable, Sendable {
    var eventId: String? { get }
    var type: String { get }
}

/// Base protocol for server events
public protocol LangToolsRealtimeServerEvent: Decodable, Sendable {
    var eventId: String { get }
    var type: String { get }
}

// MARK: - Audio Buffer Protocol

/// Protocol for audio buffer management
public protocol LangToolsAudioBuffer: AnyObject {
    /// Append audio data to the buffer
    func append(audio: Data) async throws

    /// Commit the audio buffer for processing
    func commit() async throws

    /// Clear the audio buffer
    func clear() async throws
}

// MARK: - Interruption Handling

/// Protocol for handling interruptions in realtime sessions
public protocol LangToolsInterruptible: AnyObject {
    /// Cancel the current response generation
    func cancelResponse() async throws

    /// Whether the session is currently generating a response
    var isGenerating: Bool { get }
}

// MARK: - Realtime Event Handler

/// Handler for realtime events with type-erased callbacks
public final class RealtimeEventHandler: @unchecked Sendable {
    public typealias AudioHandler = @Sendable (Data) -> Void
    public typealias TextHandler = @Sendable (String) -> Void
    public typealias TranscriptHandler = @Sendable (String, Bool) -> Void // (transcript, isFinal)
    public typealias ErrorHandler = @Sendable (Error) -> Void
    public typealias StateHandler = @Sendable (RealtimeSessionState) -> Void
    public typealias InterruptionHandler = @Sendable () -> Void

    public var onAudioReceived: AudioHandler?
    public var onTextReceived: TextHandler?
    public var onTranscriptReceived: TranscriptHandler?
    public var onError: ErrorHandler?
    public var onStateChanged: StateHandler?
    public var onInterruption: InterruptionHandler?
    public var onSpeechStarted: InterruptionHandler?
    public var onSpeechStopped: InterruptionHandler?

    public init() {}
}
