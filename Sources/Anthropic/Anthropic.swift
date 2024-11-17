//
//  Anthropic.swift
//
//
//  Created by Reid Chatham on 7/20/24.
//

import Foundation
import LangTools


public final class Anthropic: LangTools {
    public typealias ErrorResponse = AnthropicErrorResponse

    public private(set) lazy var session: URLSession = URLSession(configuration: .default, delegate: streamManager, delegateQueue: nil)
    lazy public var streamManager: StreamSessionManager<Anthropic> = StreamSessionManager<Anthropic>()

    public static let url: URL = URL(string: "https://api.anthropic.com/v1/")!
    private let apiKey: String

    public var requestTypes: [(any LangToolsChatRequest) -> Bool] {
        return [
            { ($0 as? MessageRequest) != nil }
        ]
    }

    public init(apiKey: String) {
        self.apiKey = apiKey
    }

    internal func configure(testURLSessionConfiguration: URLSessionConfiguration) -> Self {
        session = URLSession(configuration: testURLSessionConfiguration, delegate: streamManager, delegateQueue: nil)
        return self
    }

    public func perform<ChatRequest: LangToolsChatRequest>(request: ChatRequest, completion: @escaping (Result<ChatRequest.ChatResponse, Error>) -> Void, didCompleteStreaming: ((Error?) -> Void)? = nil) {
        Task {
            if request.stream, let request = request as? MessageRequest { do { for try await response in stream(request: request) { completion(.success(response as! ChatRequest.ChatResponse)) }; didCompleteStreaming?(nil) } catch { didCompleteStreaming?(error) }}
            else { do { completion(.success(try await perform(request: request))) } catch { completion(.failure(error)) }}
        }
    }

    public func prepare<ChatRequest: LangToolsChatRequest>(request: ChatRequest) throws -> URLRequest {
        var urlRequest = URLRequest(url: ChatRequest.url)
        urlRequest.httpMethod = "POST"
        urlRequest.addValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.addValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.addValue(apiKey, forHTTPHeaderField: "x-api-key")
        do { urlRequest.httpBody = try JSONEncoder().encode(request) } catch { throw LangToolError<ErrorResponse>.invalidData }
        return urlRequest
    }

    public func completionRequest<ChatRequest: LangToolsChatRequest>(request: ChatRequest, response: ChatRequest.ChatResponse) throws -> ChatRequest? {
        return try (request as? MessageRequest)?.completion(response: response as! MessageResponse) as? ChatRequest
    }

    public static func processStream(data: Data, completion: @escaping (Data) -> Void) {
        String(data: data, encoding: .utf8)?.split(separator: "\n").filter{ $0.hasPrefix("data:") && !$0.contains("[DONE]") }.forEach { completion(Data(String($0.dropFirst(5)).utf8)) }
    }
}

public struct AnthropicErrorResponse: Codable, Error {
    let type: String
    let error: AnthropicAPIError
}

public struct AnthropicAPIError: Codable {
    let type: AnthropicAPIErrorType
    let message: String
}

// MARK: - API Error Types
public enum AnthropicAPIErrorType: String, Codable {
    case invalidRequestError = "invalid_request_error"
    case authenticationError = "authentication_error"
    case permissionError = "permission_error"
    case notFoundError = "not_found_error"
    case requestTooLarge = "request_too_large"
    case rateLimitError = "rate_limit_error"
    case apiError = "api_error"
    case overloadedError = "overloaded_error"
}

public extension Anthropic {
    enum Model: String, Codable, CaseIterable {
        case claude35Sonnet_20240620 = "claude-3-5-sonnet-20240620"
        case claude3Haiku_20240307 = "claude-3-haiku-20240307"
    }
}
