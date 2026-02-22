//
//  Anthropic.swift
//
//
//  Created by Reid Chatham on 7/20/24.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
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
        print("🔧 Anthropic.prepare() called")
        print("   Base URL: \(configuration.baseURL)")
        print("   Endpoint: \(request.endpoint)")
        print("   API Key: \(apiKey.isEmpty ? "EMPTY" : "Set (length: \(apiKey.count))")")

        let fullURL = configuration.baseURL.appending(path: request.endpoint)
        print("   Full URL: \(fullURL)")

        var urlRequest = URLRequest(url: fullURL)
        urlRequest.httpMethod = "POST"
        urlRequest.addValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.addValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.addValue(apiKey, forHTTPHeaderField: "x-api-key")

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            urlRequest.httpBody = try encoder.encode(request)
            if let bodyString = String(data: urlRequest.httpBody!, encoding: .utf8) {
                print("   📝 Request body:\n\(bodyString)")
            }
            print("   ✅ Request body encoded successfully")
        } catch {
            print("   ❌ Failed to encode request: \(error)")
            throw LangToolsError.invalidData
        }

        print("   ✅ URLRequest prepared successfully")
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
        // MARK: - Claude 4.6 Models (February 2026)
        case claude46Opus_latest = "claude-opus-4-6-latest"
        case claude46Opus_20260205 = "claude-opus-4-6-20260205"
        case claude46Sonnet_latest = "claude-sonnet-4-6-latest"
        case claude46Sonnet_20260217 = "claude-sonnet-4-6-20260217"

        // MARK: - Claude 4.5 Models
        case claude45Opus_latest = "claude-opus-4-5-latest"
        case claude45Opus_20251101 = "claude-opus-4-5-20251101"
        case claude45Sonnet_latest = "claude-4-5-sonnet-latest"
        case claude45Sonnet_20250929 = "claude-4-5-sonnet-20250929"
        case claude45Haiku_latest = "claude-4-5-haiku-latest"
        case claude45Haiku_20251001 = "claude-4-5-haiku-20251001"

        // MARK: - Claude 4.1 Models
        case claude41Opus_latest = "claude-4-1-opus-latest"
        case claude41Opus_20250805 = "claude-4-1-opus-20250805"

        // MARK: - Claude 3.7 Models
        case claude37Sonnet_latest = "claude-3-7-sonnet-latest"
        case claude37Sonnet_20250219 = "claude-3-7-sonnet-20250219"

        // MARK: - Claude 3.5 Models
        case claude35Sonnet_latest = "claude-3-5-sonnet-latest"
        case claude35Sonnet_20241022 = "claude-3-5-sonnet-20241022"
        /// Deprecated: This model version has been retired. Use claude35Sonnet_20241022 or newer.
        case claude35Sonnet_20240620 = "claude-3-5-sonnet-20240620"
        case claude35Haiku_latest = "claude-3-5-haiku-latest"
        case claude35Haiku_20241022 = "claude-3-5-haiku-20241022"

        // MARK: - Claude 3 Models (Legacy - Deprecated)
        /// Deprecated: Use Claude 4.x models for better performance.
        case claude3Opus_latest = "claude-3-opus-latest"
        /// Deprecated: Use Claude 4.x models for better performance.
        case claude3Opus_20240229 = "claude-3-opus-20240229"
        /// Deprecated: Use Claude 4.x models for better performance.
        case claude3Sonnet_20240229 = "claude-3-sonnet-20240229"
        /// Deprecated: Use Claude 4.x models for better performance.
        case claude3Haiku_20240307 = "claude-3-haiku-20240307"

        /// Returns true if this model is deprecated and should be migrated away from.
        public var isDeprecated: Bool {
            switch self {
            case .claude35Sonnet_20240620,
                 .claude3Opus_latest, .claude3Opus_20240229,
                 .claude3Sonnet_20240229, .claude3Haiku_20240307:
                return true
            default:
                return false
            }
        }
    }
}

// MARK: - Testing
extension Anthropic {
    internal func configure(testURLSessionConfiguration: URLSessionConfiguration) -> Self {
        configuration.session = URLSession(configuration: testURLSessionConfiguration, delegate: session.delegate, delegateQueue: session.delegateQueue)
        return self
    }
}
