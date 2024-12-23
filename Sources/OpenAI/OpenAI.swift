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
            { ($0 as? ChatCompletionRequest) != nil },
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
    case chat, tts
}

public struct OpenAIModel: Codable, CaseIterable, Equatable {
    public static var allCases: [OpenAIModel] = openAIModelIds.map { OpenAIModel(model: $0)! }

    public init(rawValue: Int) {
        modelID = Self.allCases[rawValue].modelID
    }

    public init?(model: String) {
        if Self.openAIModelIds.contains(model) {
            self.modelID = model
        } else { return nil }
    }

    public init(customModelID: String) {
        modelID = customModelID
    }

    public var rawValue: Int { Self.allCases.firstIndex(where: { $0.modelID == modelID })! }

    public var modelID: String
    public var type: OpenAIModelType { modelID.hasPrefix("tts") ? .tts : .chat }

    public static let gpt35Turbo = OpenAIModel(model: "gpt-3.5-turbo")!
    public static let gpt35Turbo_0301 = OpenAIModel(model: "gpt-3.5-turbo-0301")!
    public static let gpt35Turbo_1106 = OpenAIModel(model: "gpt-3.5-turbo-1106")!
    public static let gpt35Turbo_16k = OpenAIModel(model: "gpt-3.5-turbo-16k")!
    public static let gpt35Turbo_Instruct = OpenAIModel(model: "gpt-3.5-turbo-instruct")!
    public static let gpt4 = OpenAIModel(model: "gpt-4")!
    public static let gpt4Turbo = OpenAIModel(model: "gpt-4-turbo")!
    public static let gpt4_0613 = OpenAIModel(model: "gpt-4-0613")!
    public static let gpt4Turbo_1106Preview = OpenAIModel(model: "gpt-4-1106-preview")!
    public static let gpt4_VisionPreview = OpenAIModel(model: "gpt-4-vision-preview")!
    public static let gpt4_32k = OpenAIModel(model: "gpt-4-32k")!
    public static let gpt4_32k_0613 = OpenAIModel(model: "gpt-4-32k-0613")!
    public static let gpt4o = OpenAIModel(model: "gpt-4o")!
    public static let gpt4o_2024_05_13 = OpenAIModel(model: "gpt-4o-2024-05-13")!
    public static let tts_1 = OpenAIModel(model: "tts-1")!
    public static let tts_1_hd = OpenAIModel(model: "tts-1-hd")!
    public static let whisper = OpenAIModel(model: "whisper-1")!

    private static var openAIModelIds: [String] = [
        "gpt-3.5-turbo",
        "gpt-3.5-turbo-0301",
        "gpt-3.5-turbo-1106",
        "gpt-3.5-turbo-16k",
        "gpt-3.5-turbo-instruct",
        "gpt-4",
        "gpt-4-turbo",
        "gpt-4-0613",
        "gpt-4-1106-preview",
        "gpt-4-vision-preview",
        "gpt-4-32k",
        "gpt-4-32k-0613",
        "gpt-4o",
        "gpt-4o-2024-05-13",
        "tts-1",
        "tts-1-hd",
        "whipser-1"
    ]

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        modelID = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(modelID)
    }
}
