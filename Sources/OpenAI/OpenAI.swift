//
//  OpenAI.swift
//  OpenAI
//
//  Created by Reid Chatham on 3/9/23.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LangTools


final public class OpenAI: LangTools {
    public typealias Model = OpenAIModel
    public typealias ErrorResponse = OpenAIErrorResponse

    private var configuration: OpenAIConfiguration
    private var apiKey: String { configuration.apiKey }
    public var session: URLSession { configuration.session }

    public struct OpenAIConfiguration {
        public var baseURL: URL
        public let apiKey: String
        public var session: URLSession

        public init(baseURL: URL = URL(string: "https://api.openai.com/v1/")!, apiKey: String, session: URLSession = URLSession(configuration: .default, delegate: nil, delegateQueue: nil)) {
            self.baseURL = baseURL
            self.apiKey = apiKey
            self.session = session
        }
    }

    public static var requestValidators: [(any LangToolsRequest) -> Bool] {
        return [
            { ($0 as? ChatCompletionRequest).flatMap { OpenAIModel.openAIModels.contains($0.model) } ?? false },
            { $0 is AudioSpeechRequest },
            { $0 is AudioTranscriptionRequest },
            { $0 is ListModelDataRequest },
            { $0 is RetrieveModelRequest },
            { $0 is DeleteFineTunedModelRequest }
        ]
    }

    public init(baseURL: URL = URL(string: "https://api.openai.com/v1/")!, apiKey: String, session: URLSession = URLSession(configuration: .default, delegate: nil, delegateQueue: nil)) {
        configuration = OpenAIConfiguration(baseURL: baseURL, apiKey: apiKey)
    }

    public init(configuration: OpenAIConfiguration) {
        self.configuration = configuration
    }

    public func prepare<Request: LangToolsRequest>(request: Request) throws -> URLRequest {
        var url = configuration.baseURL.appending(path: request.endpoint)
        if Request.httpMethod == .get {
            if let id = (request as? any Identifiable)?.id as? String {
                url = url.appending(path: id)
            }
            let queryItems = Mirror(reflecting: request).children
                .filter { $0.label != nil && $0.label != "id" }
                .map { URLQueryItem(name: $0.label!, value: String(describing: $0.value))}
            if !queryItems.isEmpty {
                url = url.appending(queryItems: queryItems)
            }
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = Request.httpMethod.rawValue
        urlRequest.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        if Request.httpMethod == .get { return urlRequest }

        if let multipartRequest = (request as? MultipartFormDataEncodableRequest) {
            let formData = multipartRequest.multipartFormData()
            urlRequest.addValue(formData.contentType, forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = formData.body
        } else {
            urlRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")
            do { urlRequest.httpBody = try JSONEncoder().encode(request) } catch { throw LangToolsError.invalidData }
        }

        return urlRequest
    }
}

public struct OpenAIErrorResponse: Error, Codable {
    public let error: APIError

    public struct APIError: Error, Codable {
        public let message: String
        public let type: String
        public let param: String?
        public let code: String?
    }
}

public enum OpenAIModelType {
    case chat, tts, stt, embedding
}

public struct OpenAIModel: Codable, CaseIterable, Equatable, Identifiable, RawRepresentable {
    public static var allCases: [OpenAIModel] = openAIModels
    public static var chatModels: [OpenAIModel] { allCases.filter({ $0.type == .chat }) }
    public static var reasoning: [OpenAIModel] { [.o1, .o1_mini, .o1_preview, .o3_mini, .o4_mini] }
    public static var codex: [OpenAIModel] { [.gpt51_codex, .gpt53_codex] }
    public static var searchPreview: [OpenAIModel] { [.gpt4o_searchPreview, .gpt4o_mini_searchPreview] }
    static let openAIModels: [OpenAIModel] = ModelID.allCases.map { OpenAIModel(modelID: $0) }

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

    public var type: OpenAIModelType {
        id.hasPrefix("text") ? .embedding :
        id.hasPrefix("tts") ? .tts :
        id.hasPrefix("whisper") ? .stt : .chat
    }

    public static let gpt35Turbo = OpenAIModel(modelID: .gpt35Turbo)
    public static let gpt35Turbo_0301 = OpenAIModel(modelID: .gpt35Turbo_0301)
    public static let gpt35Turbo_1106 = OpenAIModel(modelID: .gpt35Turbo_1106)
    public static let gpt35Turbo_16k = OpenAIModel(modelID: .gpt35Turbo_16k)
    public static let gpt35TurboInstruct = OpenAIModel(modelID: .gpt35Turbo_Instruct)
    public static let gpt4 = OpenAIModel(modelID: .gpt4)
    public static let gpt4Turbo = OpenAIModel(modelID: .gpt4Turbo)
    public static let gpt4_0613 = OpenAIModel(modelID: .gpt4_0613)
    public static let gpt4Turbo_1106Preview = OpenAIModel(modelID: .gpt4Turbo_1106Preview)
    public static let gpt4VisionPreview = OpenAIModel(modelID: .gpt4_VisionPreview)
    public static let gpt4_32k_0613 = OpenAIModel(modelID: .gpt4_32k_0613)
    public static let gpt4o = OpenAIModel(modelID: .gpt4o)
    public static let gpt4o_mini = OpenAIModel(modelID: .gpt4o_mini)
    public static let gpt4o_2024_05_13 = OpenAIModel(modelID: .gpt4o_2024_05_13)
    public static let gpt4o_2024_08_06 = OpenAIModel(modelID: .gpt4o_2024_08_06)
    public static let gpt4o_2024_11_20 = OpenAIModel(modelID: .gpt4o_2024_11_20)
    public static let gpt4o_mini_2024_07_18 = OpenAIModel(modelID: .gpt4o_mini_2024_07_18)
    public static let gpt4o_realtimePreview = OpenAIModel(modelID: .gpt4o_realtimePreview)
    public static let gpt4o_miniRealtimePreview = OpenAIModel(modelID: .gpt4o_miniRealtimePreview)
    public static let gpt4o_audioPreview = OpenAIModel(modelID: .gpt4o_audioPreview)
    public static let gpt4o_audioPreview_2024_10_01 = OpenAIModel(modelID: .gpt4o_audioPreview_2024_10_01)
    public static let chatGPT4o_latest = OpenAIModel(modelID: .chatGPT4o_latest)
    public static let o1 = OpenAIModel(modelID: .o1)
    public static let o1_mini = OpenAIModel(modelID: .o1_mini)
    public static let o3_mini = OpenAIModel(modelID: .o3_mini)
    public static let o4_mini = OpenAIModel(modelID: .o4_mini)
    public static let o1_preview = OpenAIModel(modelID: .o1_preview)

    // GPT-4o Search Preview
    public static let gpt4o_searchPreview = OpenAIModel(modelID: .gpt4o_searchPreview)
    public static let gpt4o_mini_searchPreview = OpenAIModel(modelID: .gpt4o_mini_searchPreview)

    // GPT-4.1 Family
    public static let gpt41 = OpenAIModel(modelID: .gpt41)
    public static let gpt41_mini = OpenAIModel(modelID: .gpt41_mini)
    public static let gpt41_nano = OpenAIModel(modelID: .gpt41_nano)

    // GPT-5 Family
    public static let gpt5 = OpenAIModel(modelID: .gpt5)
    public static let gpt5_mini = OpenAIModel(modelID: .gpt5_mini)
    public static let gpt5_nano = OpenAIModel(modelID: .gpt5_nano)
    public static let gpt5_1 = OpenAIModel(modelID: .gpt5_1)
    public static let gpt5_2 = OpenAIModel(modelID: .gpt5_2)
    public static let gpt5_3 = OpenAIModel(modelID: .gpt5_3)

    // Codex Models
    public static let gpt51_codex = OpenAIModel(modelID: .gpt51_codex)
    public static let gpt53_codex = OpenAIModel(modelID: .gpt53_codex)

    public static let tts_1 = OpenAIModel(modelID: .tts_1)
    public static let tts_1_hd = OpenAIModel(modelID: .tts_1_hd)
    public static let whisper = OpenAIModel(modelID: .whisper)
    public static let textEmbeddingAda002 = OpenAIModel(modelID: .textEmbeddingAda002)
    public static let textEmbedding3Large = OpenAIModel(modelID: .textEmbedding3Large)
    public static let textEmbedding3Small = OpenAIModel(modelID: .textEmbedding3Small)

    public enum ModelID: String, Codable, CaseIterable {
        // MARK: - GPT-3.5 Models (Legacy)
        case gpt35Turbo = "gpt-3.5-turbo"
        case gpt35Turbo_0301 = "gpt-3.5-turbo-0301"
        case gpt35Turbo_1106 = "gpt-3.5-turbo-1106"
        case gpt35Turbo_16k = "gpt-3.5-turbo-16k"
        case gpt35Turbo_Instruct = "gpt-3.5-turbo-instruct"

        // MARK: - GPT-4 Models
        case gpt4 = "gpt-4"
        case gpt4Turbo = "gpt-4-turbo"
        case gpt4_0613 = "gpt-4-0613"
        case gpt4Turbo_1106Preview = "gpt-4-1106-preview"
        case gpt4_VisionPreview = "gpt-4-vision-preview"
        case gpt4_32k_0613 = "gpt-4-32k-0613"

        // MARK: - GPT-4o Models
        case gpt4o = "gpt-4o"
        case gpt4o_mini = "gpt-4o-mini"
        case gpt4o_2024_05_13 = "gpt-4o-2024-05-13"
        case gpt4o_2024_08_06 = "gpt-4o-2024-08-06"
        case gpt4o_2024_11_20 = "gpt-4o-2024-11-20"
        case gpt4o_mini_2024_07_18 = "gpt-4o-mini-2024-07-18"
        case gpt4o_realtimePreview = "gpt-4o-realtime-preview"
        case gpt4o_miniRealtimePreview = "gpt-4o-mini-realtime-preview"
        case gpt4o_audioPreview = "gpt-4o-audio-preview"
        case gpt4o_audioPreview_2024_10_01 = "gpt-4o-audio-preview-2024-10-01"
        case chatGPT4o_latest = "chatgpt-4o-latest"

        // MARK: - GPT-4o Search Preview Models
        case gpt4o_searchPreview = "gpt-4o-search-preview"
        case gpt4o_mini_searchPreview = "gpt-4o-mini-search-preview"

        // MARK: - GPT-4.1 Models
        case gpt41 = "gpt-4.1"
        case gpt41_mini = "gpt-4.1-mini"
        case gpt41_nano = "gpt-4.1-nano"

        // MARK: - GPT-5 Models
        case gpt5 = "gpt-5"
        case gpt5_mini = "gpt-5-mini"
        case gpt5_nano = "gpt-5-nano"
        case gpt5_1 = "gpt-5.1"
        case gpt5_2 = "gpt-5.2"
        case gpt5_3 = "gpt-5.3"

        // MARK: - Codex Models
        case gpt51_codex = "gpt-5.1-codex"
        case gpt53_codex = "gpt-5.3-codex"

        // MARK: - Reasoning Models (o-series)
        case o1 = "o1"
        case o1_mini = "o1-mini"
        case o1_preview = "o1-preview"
        case o3_mini = "o3-mini"
        case o4_mini = "o4-mini"

        // MARK: - Text-to-Speech Models
        case tts_1 = "tts-1"
        case tts_1_hd = "tts-1-hd"

        // MARK: - Speech-to-Text Models
        case whisper = "whisper-1"

        // MARK: - Embedding Models
        case textEmbeddingAda002 = "text-embedding-ada-002"
        case textEmbedding3Large = "text-embedding-3-large"
        case textEmbedding3Small = "text-embedding-3-small"

        public var openAIModel: OpenAIModel { OpenAIModel(modelID: self) }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        id = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(id)
    }

    public static func ==(_ lhs: OpenAIModel, _ rhs: OpenAIModel) -> Bool {
        return lhs.id == rhs.id
    }
}

// MARK: - Testing
extension OpenAI {
    internal func configure(testURLSessionConfiguration: URLSessionConfiguration) -> Self {
        configuration.session = URLSession(configuration: testURLSessionConfiguration, delegate: session.delegate, delegateQueue: session.delegateQueue)
        return self
    }
}
