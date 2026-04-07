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

        // Validate structured output model support before sending to the API.
        if let msgRequest = request as? MessageRequest, msgRequest.usesStructuredOutput {
            guard msgRequest.model.supportsStructuredOutput else {
                let supported = Anthropic.Model.structuredOutputModels.map { $0.rawValue }.sorted()
                throw StructuredOutputError.modelDoesNotSupportStructuredOutput(
                    model: msgRequest.model.rawValue,
                    supportedModels: supported
                )
            }
        }

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
    // CaseIterable is declared in the extension below rather than here to allow
    // @available(*, deprecated) on individual cases without breaking synthesis.
    enum Model: String, Codable {
        // MARK: - Claude 4.6 Models (February 2026) - Active
        case claude46Opus = "claude-opus-4-6"
        case claude46Opus_20260205 = "claude-opus-4-6-20260205"
        case claude46Sonnet = "claude-sonnet-4-6"
        case claude46Sonnet_20260217 = "claude-sonnet-4-6-20260217"

        // MARK: - Claude 4.5 Models - Active
        case claude45Opus_20251101 = "claude-opus-4-5-20251101"
        case claude45Sonnet_latest = "claude-sonnet-4-5-latest"
        case claude45Sonnet_20250929 = "claude-sonnet-4-5-20250929"
        case claude45Haiku_latest = "claude-haiku-4-5-latest"
        case claude45Haiku_20251001 = "claude-haiku-4-5-20251001"

        // MARK: - Claude 4.1 Models - Active
        case claude41Opus_latest = "claude-opus-4-1-latest"
        case claude41Opus_20250805 = "claude-opus-4-1-20250805"

        // MARK: - Claude 4 Models - Active
        case claude4Opus_20250514 = "claude-opus-4-20250514"
        case claude4Sonnet_20250514 = "claude-sonnet-4-20250514"

        // MARK: - Claude 3 Haiku (Deprecated - Retiring April 20, 2026)
        // Still functional; retire warning only.
        @available(*, deprecated, message: "Retiring April 20, 2026. Use claude45Haiku_latest instead.")
        case claude3Haiku_20240307 = "claude-3-haiku-20240307"

        // MARK: - Retired Models (kept for Codable round-trip compatibility only — will return API errors)
        // Note: Swift has no @available(*, retired) for enum cases. @available(*, deprecated) is used
        // here as the strongest compile-time signal available that still preserves rawValue-based
        // decoding (which @available(*, unavailable) would break). Use `isRetired` for runtime checks.
        @available(*, deprecated, renamed: "claude46Sonnet", message: "[RETIRED Feb 2026] Will return API errors. Use claude46Sonnet instead.")
        case claude37Sonnet_20250219 = "claude-3-7-sonnet-20250219"
        @available(*, deprecated, renamed: "claude45Haiku_latest", message: "[RETIRED Feb 2026] Will return API errors. Use claude45Haiku_latest instead.")
        case claude35Haiku_20241022 = "claude-3-5-haiku-20241022"
        @available(*, deprecated, renamed: "claude46Sonnet", message: "[RETIRED Oct 2025] Will return API errors. Use claude46Sonnet instead.")
        case claude35Sonnet_latest = "claude-3-5-sonnet-latest"
        @available(*, deprecated, renamed: "claude46Sonnet", message: "[RETIRED Oct 2025] Will return API errors. Use claude46Sonnet instead.")
        case claude35Sonnet_20241022 = "claude-3-5-sonnet-20241022"
        @available(*, deprecated, renamed: "claude46Sonnet", message: "[RETIRED Oct 2025] Will return API errors. Use claude46Sonnet instead.")
        case claude35Sonnet_20240620 = "claude-3-5-sonnet-20240620"
        @available(*, deprecated, renamed: "claude46Opus", message: "[RETIRED Jan 2026] Will return API errors. Use claude46Opus instead.")
        case claude3Opus_latest = "claude-3-opus-latest"
        @available(*, deprecated, renamed: "claude46Opus", message: "[RETIRED Jan 2026] Will return API errors. Use claude46Opus instead.")
        case claude3Opus_20240229 = "claude-3-opus-20240229"
        @available(*, deprecated, renamed: "claude46Opus", message: "[RETIRED Jul 2025] Will return API errors. Use claude46Opus instead.")
        case claude3Sonnet_20240229 = "claude-3-sonnet-20240229"
    }
}

// MARK: - CaseIterable
// Manual implementation required: @available(*, deprecated/@unavailable) on enum cases
// breaks synthesized CaseIterable conformance in Swift.
extension Anthropic.Model: CaseIterable {
    /// All known models, including deprecated and retired ones (useful for Codable round-trips
    /// and exhaustive UI lists). For new requests, prefer `activeCases`.
    public static var allCases: [Anthropic.Model] {
        activeCases + deprecatedCases + retiredCases
    }

    /// Models that are fully supported and recommended for new requests.
    public static var activeCases: [Anthropic.Model] {
        [
            .claude46Opus, .claude46Opus_20260205,
            .claude46Sonnet, .claude46Sonnet_20260217,
            .claude45Opus_20251101,
            .claude45Sonnet_latest, .claude45Sonnet_20250929,
            .claude45Haiku_latest, .claude45Haiku_20251001,
            .claude41Opus_latest, .claude41Opus_20250805,
            .claude4Opus_20250514, .claude4Sonnet_20250514,
        ]
    }

    /// Models that are deprecated (still functional, but retiring soon).
    /// Use rawValue init to avoid re-triggering deprecation warnings at call sites.
    public static var deprecatedCases: [Anthropic.Model] {
        ["claude-3-haiku-20240307"]
            .compactMap(Anthropic.Model.init(rawValue:))
    }

    /// Models that have been retired (will return API errors).
    /// Kept for Codable round-trip compatibility only.
    /// Use rawValue init to avoid triggering unavailable errors at call sites.
    public static var retiredCases: [Anthropic.Model] {
        [
            "claude-3-7-sonnet-20250219",
            "claude-3-5-haiku-20241022",
            "claude-3-5-sonnet-latest",
            "claude-3-5-sonnet-20241022",
            "claude-3-5-sonnet-20240620",
            "claude-3-opus-latest",
            "claude-3-opus-20240229",
            "claude-3-sonnet-20240229",
        ].compactMap(Anthropic.Model.init(rawValue:))
    }
}

// MARK: - Model Aliases (latest pointers)
extension Anthropic.Model {
    /// Alias for the latest Claude 4.6 Sonnet model.
    public static var claude46Sonnet_latest: Anthropic.Model { .claude46Sonnet }
    /// Alias for the latest Claude 4.6 Opus model.
    public static var claude46Opus_latest: Anthropic.Model { .claude46Opus }
}

// MARK: - Structured Output Support
extension Anthropic.Model {
    /// The set of models that support the `output_config.format` / structured output feature.
    /// Claude 4.x and newer models support structured output.
    public static var structuredOutputModels: Set<Anthropic.Model> {
        [
            .claude46Opus, .claude46Opus_20260205,
            .claude46Sonnet, .claude46Sonnet_20260217,
            .claude45Opus_20251101,
            .claude45Sonnet_latest, .claude45Sonnet_20250929,
            .claude45Haiku_latest, .claude45Haiku_20251001,
            .claude41Opus_latest, .claude41Opus_20250805,
            .claude4Opus_20250514, .claude4Sonnet_20250514,
        ]
    }

    /// Returns `true` when this model supports the structured output (`output_config.format`) feature.
    public var supportsStructuredOutput: Bool {
        Anthropic.Model.structuredOutputModels.contains(self)
    }
}

// MARK: - Model Lifecycle
extension Anthropic.Model {
    /// Returns `true` if this model is deprecated (still functional but retiring soon).
    /// Derived from `deprecatedCases` to keep the source of truth in one place.
    public var isDeprecated: Bool {
        Anthropic.Model.deprecatedCases.contains(self)
    }

    /// Returns `true` if this model has been retired (will return API errors).
    /// Derived from `retiredCases` to keep the source of truth in one place.
    public var isRetired: Bool {
        Anthropic.Model.retiredCases.contains(self)
    }
}

// MARK: - Testing
extension Anthropic {
    internal func configure(testURLSessionConfiguration: URLSessionConfiguration) -> Self {
        configuration.session = URLSession(configuration: testURLSessionConfiguration, delegate: session.delegate, delegateQueue: session.delegateQueue)
        return self
    }
}
