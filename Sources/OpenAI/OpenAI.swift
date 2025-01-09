//
//  OpenAI.swift
//  OpenAI
//
//  Created by Reid Chatham on 3/9/23.
//

import Foundation
import LangTools


final public class OpenAI: LangTools {
    public typealias Model = OpenAIModel
    public typealias ErrorResponse = OpenAIErrorResponse

    private var apiKey: String { configuration.apiKey }
    private var configuration: OpenAIConfiguration

    public struct OpenAIConfiguration {
        public var baseURL: URL
        public let apiKey: String

        public init(baseURL: URL = URL(string: "https://api.openai.com/v1/")!, apiKey: String) {
            self.baseURL = baseURL
            self.apiKey = apiKey
        }
    }

    public private(set) lazy var session: URLSession = URLSession(configuration: .default, delegate: streamManager, delegateQueue: nil)
    public private(set) lazy var streamManager: StreamSessionManager = StreamSessionManager<OpenAI>()

    public var requestTypes: [(any LangToolsRequest) -> Bool] {
        return [
            { ($0 as? ChatCompletionRequest).flatMap { OpenAIModel.openAIModels.contains($0.model) } ?? false },
            { ($0 as? AudioSpeechRequest) != nil },
            { ($0 as? AudioTranscriptionRequest) != nil }
        ]
    }

    public init(baseURL: URL = URL(string: "https://api.openai.com/v1/")!, apiKey: String) {
        configuration = OpenAIConfiguration(baseURL: baseURL, apiKey: apiKey)
    }

    public init(configuration: OpenAIConfiguration) {
        self.configuration = configuration
    }

    internal func configure(testURLSessionConfiguration: URLSessionConfiguration) -> Self {
        session = URLSession(configuration: testURLSessionConfiguration, delegate: streamManager, delegateQueue: nil)
        return self
    }

    public func prepare<Request: LangToolsRequest>(request: Request) throws -> URLRequest {
        var url = configuration.baseURL.appending(path: request.endpoint)
        if Request.httpMethod == .get {
            url = url.appending(queryItems: Mirror(reflecting: request).children.compactMap { if let label = $0.label { URLQueryItem(name: label, value: String(describing: $0.value)) } else { nil }})
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = Request.httpMethod.rawValue
        urlRequest.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if Request.httpMethod == .get { return urlRequest }
        if let request = (request as? MultipartFormDataEncodableRequest) {
            urlRequest.addValue("multipart/form-data", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = request.httpBody
        } else {
            urlRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")
            do { urlRequest.httpBody = try JSONEncoder().encode(request) } catch { throw LangToolError.invalidData }
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
    case chat, tts, stt
}

public struct OpenAIModel: Codable, CaseIterable, Equatable, Identifiable, RawRepresentable {
    public static var allCases: [OpenAIModel] = openAIModels
    public static var chatModels: [OpenAIModel] { allCases.filter({ $0.type == .chat }) }
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

    public var type: OpenAIModelType { id.hasPrefix("tts") ? .tts : (id.hasPrefix("whisper") ? .stt : .chat) }

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
    public static let gpt4o_2024_05_13 = OpenAIModel(modelID: .gpt4o_2024_05_13)
    public static let tts_1 = OpenAIModel(modelID: .tts_1)
    public static let tts_1_hd = OpenAIModel(modelID: .tts_1_hd)
    public static let whisper = OpenAIModel(modelID: .whisper)

    public enum ModelID: String, Codable, CaseIterable {
        case gpt35Turbo = "gpt-3.5-turbo"
        case gpt35Turbo_0301 = "gpt-3.5-turbo-0301"
        case gpt35Turbo_1106 = "gpt-3.5-turbo-1106"
        case gpt35Turbo_16k = "gpt-3.5-turbo-16k"
        case gpt35Turbo_Instruct = "gpt-3.5-turbo-instruct"
        case gpt4 = "gpt-4"
        case gpt4Turbo = "gpt-4-turbo"
        case gpt4_0613 = "gpt-4-0613"
        case gpt4Turbo_1106Preview = "gpt-4-1106-preview"
        case gpt4_VisionPreview = "gpt-4-vision-preview"
        case gpt4_32k_0613 = "gpt-4-32k-0613"
        case gpt4o = "gpt-4o"
        case gpt4o_2024_05_13 = "gpt-4o-2024-05-13"
        case tts_1 = "tts-1"
        case tts_1_hd = "tts-1-hd"
        case whisper = "whisper-1"

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
