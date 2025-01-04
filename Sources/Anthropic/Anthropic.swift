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

    private var apiKey: String { configuration.apiKey }
    private var configuration: AnthropicConfiguration 

    public struct AnthropicConfiguration {
        public var baseURL: URL
        public let apiKey: String

        public init(baseURL: URL = URL(string: "https://api.anthropic.com/v1/")!, apiKey: String) {
            self.baseURL = baseURL
            self.apiKey = apiKey
        }
    }

    public private(set) lazy var session: URLSession = URLSession(configuration: .default, delegate: streamManager, delegateQueue: nil)
    public private(set) lazy var streamManager: StreamSessionManager<Anthropic> = StreamSessionManager<Anthropic>()

    public var requestTypes: [(any LangToolsRequest) -> Bool] {
        return [
            { ($0 as? MessageRequest) != nil }
        ]
    }

    public init(baseURL: URL = URL(string: "https://api.anthropic.com/v1/")!, apiKey: String) {
        configuration = AnthropicConfiguration(baseURL: baseURL, apiKey: apiKey)
    }

    public init(configuration: AnthropicConfiguration) {
        self.configuration = configuration
    }

    internal func configure(testURLSessionConfiguration: URLSessionConfiguration) -> Self {
        session = URLSession(configuration: testURLSessionConfiguration, delegate: streamManager, delegateQueue: nil)
        return self
    }

    public func perform<Request: LangToolsRequest>(request: Request, completion: @escaping (Result<Request.Response, Error>) -> Void, didCompleteStreaming: ((Error?) -> Void)? = nil) {
        Task {
            if request.stream, let request = request as? MessageRequest { do { for try await response in stream(request: request) { completion(.success(response as! Request.Response)) }; didCompleteStreaming?(nil) } catch { didCompleteStreaming?(error) }}
            else { do { completion(.success(try await perform(request: request))) } catch { completion(.failure(error)) }}
        }
    }

    public func prepare(request: some LangToolsRequest) throws -> URLRequest {
        var urlRequest = URLRequest(url: configuration.baseURL.appending(path: request.endpoint))
        urlRequest.httpMethod = "POST"
        urlRequest.addValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.addValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.addValue(apiKey, forHTTPHeaderField: "x-api-key")
        do { urlRequest.httpBody = try JSONEncoder().encode(request) } catch { throw LangToolError.invalidData }
        return urlRequest
    }


    public static func processStream(data: Data, completion: @escaping (Data) -> Void) {
        String(data: data, encoding: .utf8)?.split(separator: "\n").filter{ $0.hasPrefix("data:") && !$0.contains("[DONE]") }.forEach { completion(Data(String($0.dropFirst(5)).utf8)) }
    }
}

public struct AnthropicErrorResponse: Codable, Error {
    public let type: String
    public let error: AnthropicAPIError
}

public struct AnthropicAPIError: Codable {
    public let type: AnthropicAPIErrorType
    public let message: String
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
        case claude35Opus_latest = "claude-3-5-opus-latest"
        case claude35Opus_20240229 = "claude-3-5-opus-20240229"
        case claude35Sonnet_latest = "claude-3-5-sonnet-latest"
        case claude35Sonnet_20241022 = "claude-3-5-sonnet-20241022"
        case claude35Sonnet_20240229 = "claude-3-5-sonnet-20240229"
        case claude35Sonnet_20240620 = "claude-3-5-sonnet-20240620"
        case claude3Haiku_latest = "claude-3-haiku-latest"
        case claude3Haiku_20241022 = "claude-3-haiku-20241022"
        case claude3Haiku_20240307 = "claude-3-haiku-20240307"
    }
}
