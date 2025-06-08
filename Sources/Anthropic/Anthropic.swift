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

    private var configuration: AnthropicConfiguration
    private var apiKey: String { configuration.apiKey }
    public var session: URLSession { configuration.session }

    public struct AnthropicConfiguration {
        public var baseURL: URL
        public let apiKey: String
        public var session: URLSession

        public init(baseURL: URL = URL(string: "https://api.anthropic.com/v1/")!, apiKey: String, session: URLSession = URLSession(configuration: .default, delegate: nil, delegateQueue: nil)) {
            self.baseURL = baseURL
            self.apiKey = apiKey
            self.session = session
        }
    }

    public static var requestValidators: [(any LangToolsRequest) -> Bool] {
        return [
            { $0 is MessageRequest }
        ]
    }

    public init(baseURL: URL = URL(string: "https://api.anthropic.com/v1/")!, apiKey: String, session: URLSession = URLSession(configuration: .default, delegate: nil, delegateQueue: nil)) {
        configuration = AnthropicConfiguration(baseURL: baseURL, apiKey: apiKey)
    }

    public init(configuration: AnthropicConfiguration) {
        self.configuration = configuration
    }

    public func prepare(request: some LangToolsRequest) throws -> URLRequest {
        var urlRequest = URLRequest(url: configuration.baseURL.appending(path: request.endpoint))
        urlRequest.httpMethod = "POST"
        urlRequest.addValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.addValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.addValue(apiKey, forHTTPHeaderField: "x-api-key")
        do { urlRequest.httpBody = try JSONEncoder().encode(request) } catch { throw LangToolsError.invalidData }
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
        case claude3Opus_latest = "claude-3-opus-latest"
        case claude3Opus_20240229 = "claude-3-opus-20240229"
        case claude35Sonnet_latest = "claude-3-5-sonnet-latest"
        case claude35Sonnet_20241022 = "claude-3-5-sonnet-20241022"
        case claude35Sonnet_20240620 = "claude-3-5-sonnet-20240620"
        case claude3Sonnet_20240229 = "claude-3-sonnet-20240229"
        case claude35Haiku_latest = "claude-3-5-haiku-latest"
        case claude35Haiku_20241022 = "claude-3-5-haiku-20241022"
        case claude3Haiku_20240307 = "claude-3-haiku-20240307"
    }
}

// MARK: - Testing
extension Anthropic {
    internal func configure(testURLSessionConfiguration: URLSessionConfiguration) -> Self {
        configuration.session = URLSession(configuration: testURLSessionConfiguration, delegate: session.delegate, delegateQueue: session.delegateQueue)
        return self
    }
}
