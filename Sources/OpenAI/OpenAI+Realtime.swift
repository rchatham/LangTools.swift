import Foundation
import LangTools

public extension OpenAI {
    /// Create a new realtime session.
    struct RealtimeSessionCreateRequest: Codable, LangToolsRequest {
        public typealias Response = RealtimeSessionCreateResponse
        public typealias LangTool = OpenAI
        public static var endpoint: String { "realtime/sessions" }

        public let model: Model
        public let modalities: [String]?
        public let instructions: String?
        public let voice: String?
        public let temperature: Double?
        public let max_response_output_tokens: Int?

        public init(model: Model,
                    modalities: [String]? = nil,
                    instructions: String? = nil,
                    voice: String? = nil,
                    temperature: Double? = nil,
                    max_response_output_tokens: Int? = nil) {
            self.model = model
            self.modalities = modalities
            self.instructions = instructions
            self.voice = voice
            self.temperature = temperature
            self.max_response_output_tokens = max_response_output_tokens
        }
    }

    struct RealtimeSessionCreateResponse: Codable {
        public struct ClientSecret: Codable {
            public let value: String
            public let expires_at: Int
        }

        public let id: String
        public let object: String
        public let model: String
        public let modalities: [String]?
        public let instructions: String?
        public let voice: String?
        public let input_audio_format: String?
        public let output_audio_format: String?
        public let client_secret: ClientSecret?
    }

    /// Create a realtime transcription session.
    struct RealtimeTranscriptionSessionCreateRequest: Codable, LangToolsRequest {
        public typealias Response = RealtimeTranscriptionSessionCreateResponse
        public typealias LangTool = OpenAI
        public static var endpoint: String { "realtime/transcription_sessions" }

        public let input_audio_format: String?
        public let input_audio_transcription: InputAudioTranscription?
        public let turn_detection: TurnDetection?

        public struct InputAudioTranscription: Codable {
            public let model: String
            public let language: String?
            public let prompt: String?
        }

        public struct TurnDetection: Codable {
            public let type: String
            public let threshold: Double?
            public let prefix_padding_ms: Int?
            public let silence_duration_ms: Int?
        }

        public init(input_audio_format: String? = nil,
                    input_audio_transcription: InputAudioTranscription? = nil,
                    turn_detection: TurnDetection? = nil) {
            self.input_audio_format = input_audio_format
            self.input_audio_transcription = input_audio_transcription
            self.turn_detection = turn_detection
        }
    }

    struct RealtimeTranscriptionSessionCreateResponse: Codable {
        public struct ClientSecret: Codable {
            public let value: String
            public let expires_at: Int
        }

        public let id: String
        public let object: String
        public let modalities: [String]?
        public let input_audio_format: String?
        public let client_secret: ClientSecret?
    }

    /// Returns a configured WebSocket task for communicating with the realtime API.
    func realtimeWebSocketTask(clientSecret: String) -> URLSessionWebSocketTask {
        var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.path = "/v1/realtime"
        let url = components.url!
        var request = URLRequest(url: url)
        request.addValue("Bearer \(clientSecret)", forHTTPHeaderField: "Authorization")
        return session.webSocketTask(with: request)
    }
}
