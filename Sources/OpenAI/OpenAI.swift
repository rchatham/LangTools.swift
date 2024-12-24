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

    public init(apiKey: String) {
        configuration = OpenAIConfiguration(apiKey: apiKey)
    }

    public init(configuration: OpenAIConfiguration) {
        self.configuration = configuration
    }

    internal func configure(testURLSessionConfiguration: URLSessionConfiguration) -> Self {
        session = URLSession(configuration: testURLSessionConfiguration, delegate: streamManager, delegateQueue: nil)
        return self
    }

    public func perform<Request: LangToolsRequest>(request: Request, completion: @escaping (Result<Request.Response, Error>) -> Void, didCompleteStreaming: ((Error?) -> Void)? = nil) {
        Task {
            if request.stream, let request = request as? ChatCompletionRequest { do { for try await response in stream(request: request) { completion(.success(response as! Request.Response)) }; didCompleteStreaming?(nil) } catch { didCompleteStreaming?(error) }}
            else { do { completion(.success(try await perform(request: request))) } catch { completion(.failure(error)) }}
        }
    }


    public func prepare(request: some LangToolsRequest) throws -> URLRequest {
        var urlRequest = URLRequest(url: configuration.baseURL.appending(path: request.path))
        urlRequest.httpMethod = "POST"
        urlRequest.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let request = (request as? MultipartFormDataEncodableRequest) {
            urlRequest.addValue("multipart/form-data", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = request.httpBody
        } else {
            urlRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")
            do { urlRequest.httpBody = try JSONEncoder().encode(request) } catch { throw LangToolError<ErrorResponse>.invalidData }
        }
        return urlRequest
    }

    public static func processStream(data: Data, completion: @escaping (Data) -> Void) {
        String(data: data, encoding: .utf8)?.split(separator: "\n").filter{ $0.hasPrefix("data:") && !$0.contains("[DONE]") }.forEach { completion(Data(String($0.dropFirst(5)).utf8)) }
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

public struct OpenAIModel: Codable, CaseIterable, Equatable, Identifiable {
    public static var allCases: [OpenAIModel] = openAIModels
    public static var chatModels: [OpenAIModel] { allCases.filter({ $0.type == .chat }) }
    static let openAIModels: [OpenAIModel] = ModelID.allCases.map { OpenAIModel(modelID: $0) }

    public init(rawValue: Int) {
        id = Self.allCases[rawValue].id
    }

    public init?(modelIDString: String) {
        if let modelID = ModelID(rawValue: modelIDString), ModelID.allCases.contains(modelID) {
            id = modelIDString
        } else { return nil }
    }

    public init(modelID: ModelID) {
        id = modelID.rawValue
    }

    public init(customModelID: String) {
        id = customModelID
        Self.allCases.append(self)
    }

    public var id: String
    public var rawValue: Int { Self.allCases.firstIndex(where: { $0.id == id })! }

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
    public static let gpt4_32k = OpenAIModel(modelID: .gpt4_32k)
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
        case gpt4_32k = "gpt-4-32k"
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
}
