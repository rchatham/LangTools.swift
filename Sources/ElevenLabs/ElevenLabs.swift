//
//  ElevenLabs.swift
//  ElevenLabs
//
//  Created by Reid Chatham on 1/16/26.
//

import Foundation
import LangTools
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - ElevenLabs Provider

/// ElevenLabs API provider for text-to-speech and speech-to-text
public final class ElevenLabs: LangTools {
    public typealias Model = ElevenLabsModel
    public typealias ErrorResponse = ElevenLabsErrorResponse

    private var configuration: ElevenLabsConfiguration
    private var apiKey: String { configuration.apiKey }
    public var session: URLSession { configuration.session }

    public struct ElevenLabsConfiguration {
        public var baseURL: URL
        public let apiKey: String
        public var session: URLSession

        public init(
            baseURL: URL = URL(string: "https://api.elevenlabs.io/v1/")!,
            apiKey: String,
            session: URLSession = URLSession(configuration: .default)
        ) {
            self.baseURL = baseURL
            self.apiKey = apiKey
            self.session = session
        }
    }

    public static var requestValidators: [(any LangToolsRequest) -> Bool] {
        return [
            { $0 is TextToSpeechRequest },
            { $0 is TextToSpeechStreamRequest },
            { $0 is VoicesListRequest },
            { $0 is ModelsListRequest }
        ]
    }

    public init(apiKey: String, session: URLSession = URLSession(configuration: .default)) {
        configuration = ElevenLabsConfiguration(apiKey: apiKey, session: session)
    }

    public init(configuration: ElevenLabsConfiguration) {
        self.configuration = configuration
    }

    public func prepare<Request: LangToolsRequest>(request: Request) throws -> URLRequest {
        var url = configuration.baseURL.appending(path: request.endpoint)

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = Request.httpMethod.rawValue
        urlRequest.addValue(apiKey, forHTTPHeaderField: "xi-api-key")

        if Request.httpMethod == .get { return urlRequest }

        urlRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            urlRequest.httpBody = try JSONEncoder().encode(request)
        } catch {
            throw LangToolsError.invalidData
        }

        return urlRequest
    }

    public static func chatRequest(model: any RawRepresentable, messages: [any LangToolsMessage], tools: [any LangToolsTool]?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> any LangToolsChatRequest {
        throw LangToolsError.invalidArgument("ElevenLabs does not support chat requests")
    }
}

// MARK: - Error Response

public struct ElevenLabsErrorResponse: Error, Codable {
    public let detail: Detail?

    public struct Detail: Codable {
        public let status: String?
        public let message: String?
    }
}

// MARK: - Models

public struct ElevenLabsModel: Codable, CaseIterable, Equatable, Identifiable, RawRepresentable {
    public static var allCases: [ElevenLabsModel] = ModelID.allCases.map { ElevenLabsModel(modelID: $0) }

    public init?(rawValue: String) {
        if ModelID(rawValue: rawValue) != nil {
            id = rawValue
        } else { return nil }
    }

    public init(modelID: ModelID) {
        id = modelID.rawValue
    }

    public init(customModelID: String) {
        id = customModelID
    }

    public var id: String
    public var rawValue: String { id }

    // TTS Models
    public static let elevenMultilingualV2 = ElevenLabsModel(modelID: .elevenMultilingualV2)
    public static let elevenTurboV2_5 = ElevenLabsModel(modelID: .elevenTurboV2_5)
    public static let elevenTurboV2 = ElevenLabsModel(modelID: .elevenTurboV2)
    public static let elevenMonolingualV1 = ElevenLabsModel(modelID: .elevenMonolingualV1)
    public static let elevenEnglishStsV2 = ElevenLabsModel(modelID: .elevenEnglishStsV2)
    public static let elevenFlashV2_5 = ElevenLabsModel(modelID: .elevenFlashV2_5)
    public static let elevenFlashV2 = ElevenLabsModel(modelID: .elevenFlashV2)

    // STT Models
    public static let scribeV1 = ElevenLabsModel(modelID: .scribeV1)
    public static let scribeRealtimeV2 = ElevenLabsModel(modelID: .scribeRealtimeV2)

    public enum ModelID: String, Codable, CaseIterable {
        // TTS Models
        case elevenMultilingualV2 = "eleven_multilingual_v2"
        case elevenTurboV2_5 = "eleven_turbo_v2_5"
        case elevenTurboV2 = "eleven_turbo_v2"
        case elevenMonolingualV1 = "eleven_monolingual_v1"
        case elevenEnglishStsV2 = "eleven_english_sts_v2"
        case elevenFlashV2_5 = "eleven_flash_v2_5"
        case elevenFlashV2 = "eleven_flash_v2"

        // STT Models
        case scribeV1 = "scribe_v1"
        case scribeRealtimeV2 = "scribe_realtime_v2"

        public var elevenLabsModel: ElevenLabsModel { ElevenLabsModel(modelID: self) }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        id = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(id)
    }

    public static func ==(_ lhs: ElevenLabsModel, _ rhs: ElevenLabsModel) -> Bool {
        return lhs.id == rhs.id
    }
}

// MARK: - Voice Settings

public struct VoiceSettings: Codable, Sendable {
    public var stability: Double
    public var similarityBoost: Double
    public var style: Double?
    public var useSpeakerBoost: Bool?

    public init(
        stability: Double = 0.5,
        similarityBoost: Double = 0.75,
        style: Double? = nil,
        useSpeakerBoost: Bool? = nil
    ) {
        self.stability = stability
        self.similarityBoost = similarityBoost
        self.style = style
        self.useSpeakerBoost = useSpeakerBoost
    }

    enum CodingKeys: String, CodingKey {
        case stability
        case similarityBoost = "similarity_boost"
        case style
        case useSpeakerBoost = "use_speaker_boost"
    }
}

// MARK: - Output Format

public enum ElevenLabsOutputFormat: String, Codable, CaseIterable, Sendable {
    case mp3_44100_64 = "mp3_44100_64"
    case mp3_44100_96 = "mp3_44100_96"
    case mp3_44100_128 = "mp3_44100_128"
    case mp3_44100_192 = "mp3_44100_192"
    case pcm_16000 = "pcm_16000"
    case pcm_22050 = "pcm_22050"
    case pcm_24000 = "pcm_24000"
    case pcm_44100 = "pcm_44100"
    case ulaw_8000 = "ulaw_8000"

    public var sampleRate: Int {
        switch self {
        case .mp3_44100_64, .mp3_44100_96, .mp3_44100_128, .mp3_44100_192, .pcm_44100:
            return 44100
        case .pcm_16000:
            return 16000
        case .pcm_22050:
            return 22050
        case .pcm_24000:
            return 24000
        case .ulaw_8000:
            return 8000
        }
    }

    public var isPCM: Bool {
        switch self {
        case .pcm_16000, .pcm_22050, .pcm_24000, .pcm_44100:
            return true
        default:
            return false
        }
    }
}
