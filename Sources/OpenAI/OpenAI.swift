//
//  OpenAI.swift
//  OpenAI
//
//  Created by Reid Chatham on 3/9/23.
//

import Foundation
import LangTools


final public class OpenAI: NSObject, LangTools, URLSessionDelegate {
    
    public typealias ErrorResponse = OpenAIErrorResponse
    typealias OpenAIError = LangToolError<OpenAIErrorResponse>

    static let baseURL: URL = URL(string: "https://api.openai.com/v1/")!
    private let apiKey: String

    public private(set) lazy var session: URLSession = URLSession(configuration: .default, delegate: streamManager, delegateQueue: nil)
    public private(set) lazy var streamManager: StreamSessionManager = StreamSessionManager<OpenAI>()

    public init(apiKey: String) {
        self.apiKey = apiKey
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

    public func completionRequest<Request: LangToolsRequest>(request: Request, response: Request.Response) throws -> Request? {
        return try (request as? ChatCompletionRequest)?.completion(response: response as! ChatCompletionResponse) as? Request
    }

    public func prepare<Request: LangToolsRequest>(request: Request) throws -> URLRequest {
        var urlRequest = URLRequest(url: Request.url)
        urlRequest.httpMethod = "POST"
        urlRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        do { urlRequest.httpBody = try JSONEncoder().encode(request) } catch { throw LangToolError<ErrorResponse>.invalidData }
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

public extension OpenAI {
    enum Model: String, Codable, CaseIterable {
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
    }
}