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

    public private(set) lazy var session: URLSession = URLSession(configuration: .default, delegate: nil, delegateQueue: nil)

    public var requestTypes: [(any LangToolsRequest) -> Bool] {
        return [
            { $0 is MessageRequest }
        ]
    }

    public init(baseURL: URL = URL(string: "https://api.anthropic.com/v1/")!, apiKey: String) {
        configuration = AnthropicConfiguration(baseURL: baseURL, apiKey: apiKey)
    }

    public init(configuration: AnthropicConfiguration) {
        self.configuration = configuration
    }

    internal func configure(testURLSessionConfiguration: URLSessionConfiguration) -> Self {
        session = URLSession(configuration: testURLSessionConfiguration, delegate: nil, delegateQueue: nil)
        return self
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

    public static func decodeStream<T: Decodable>(_ buffer: String) throws -> T? {
        if buffer.hasPrefix("event:") { return nil }
        return if buffer.hasPrefix("data:") && !buffer.contains("[DONE]"), let data = buffer.dropFirst(5).data(using: .utf8) { try Self.decodeResponse(data: data) } else { nil }
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
        case claude35Opus_latest = "claude-3-opus-latest"
        case claude35Opus_20240229 = "claude-3-opus-20240229"
        case claude35Sonnet_latest = "claude-3-5-sonnet-latest"
        case claude35Sonnet_20241022 = "claude-3-5-sonnet-20241022"
        case claude35Sonnet_20240229 = "claude-3-sonnet-20240229"
        case claude3Haiku_latest = "claude-3-5-haiku-latest"
        case claude3Haiku_20241022 = "claude-3-5-haiku-20241022"
        case claude3Haiku_20240307 = "claude-3-haiku-20240307"
    }
}
