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
    public var logger: LangToolsLogger? { configuration.logger }

    public struct AnthropicConfiguration {
        public var baseURL: URL
        public let apiKey: String
        public var session: URLSession
        public var logger: LangToolsLogger?

        public init(baseURL: URL = URL(string: "https://api.anthropic.com/v1/")!, apiKey: String, session: URLSession = URLSession(configuration: .default, delegate: nil, delegateQueue: nil), logger: LangToolsLogger? = nil) {
            self.baseURL = baseURL
            self.apiKey = apiKey
            self.session = session
            self.logger = logger
        }
    }

    public static var requestValidators: [(any LangToolsRequest) -> Bool] {
        return [
            { ($0 as? MessageRequest).map { $0.providerID == nil } ?? false }  // Routed requests belong to their provider.
        ]
    }

    public init(baseURL: URL = URL(string: "https://api.anthropic.com/v1/")!, apiKey: String, session: URLSession = URLSession(configuration: .default, delegate: nil, delegateQueue: nil), logger: LangToolsLogger? = nil) {
        configuration = AnthropicConfiguration(baseURL: baseURL, apiKey: apiKey, session: session, logger: logger)
    }

    public init(configuration: AnthropicConfiguration) {
        self.configuration = configuration
    }

    public func prepare(request: some LangToolsRequest) throws -> URLRequest {
        logger?.debug("Anthropic.prepare() called")
        logger?.debug("Base URL: \(configuration.baseURL)")
        logger?.debug("Endpoint: \(request.endpoint)")
        logger?.debug("API Key: \(apiKey.isEmpty ? "EMPTY" : "Set (length: \(apiKey.count))")")

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
        logger?.debug("Full URL: \(fullURL)")

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
                logger?.debug("Request body:\n\(bodyString)")
            }
            logger?.debug("Request body encoded successfully")
        } catch {
            logger?.error("Failed to encode request: \(error)")
            throw LangToolsError.invalidData
        }

        logger?.debug("URLRequest prepared successfully")
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
    /// Anthropic model identifiers. `init(customModelID:)` accepts any model ID,
    /// including future or provider-specific models not enumerated here, so the
    /// SDK does not require a release to route a new model. `init?(rawValue:)`
    /// resolves only the known models enumerated here and returns nil otherwise.
    struct Model: Codable, CaseIterable, Hashable, Identifiable, RawRepresentable, Sendable {
        public let id: String
        public var rawValue: String { id }

        /// Resolves a known model ID; returns nil for unknown/future IDs. Use
        /// `init(customModelID:)` to represent an arbitrary model ID.
        public init?(rawValue: String) {
            guard ModelID(rawValue: rawValue) != nil else { return nil }
            id = rawValue
        }

        /// Represents any model ID, including future or provider-specific models
        /// not yet enumerated in this SDK.
        public init(customModelID: String) {
            id = customModelID
        }

        /// Represents a known, enumerated model.
        public init(modelID: ModelID) {
            id = modelID.rawValue
        }

        // MARK: - Codable (single string; accepts unknown IDs for forward compatibility)

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            id = try container.decode(String.self)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }

        // MARK: - Claude 4.6 Models (February 2026) - Active
        public static let claude46Opus = Model(modelID: .claude46Opus)
        public static let claude46Opus_20260205 = Model(modelID: .claude46Opus_20260205)
        public static let claude46Sonnet = Model(modelID: .claude46Sonnet)
        public static let claude46Sonnet_20260217 = Model(modelID: .claude46Sonnet_20260217)

        // MARK: - Claude 4.5 Models
        public static let claude45Opus_20251101 = Model(modelID: .claude45Opus_20251101)
        @available(*, deprecated, renamed: "claude55Sonnet", message: "Deprecated Sep 2026; retirement Nov 30, 2026. Use claude55Sonnet instead.")
        public static let claude45Sonnet_latest = Model(modelID: .claude45Sonnet_latest)
        @available(*, deprecated, renamed: "claude55Sonnet", message: "Deprecated Sep 2026; retirement Nov 30, 2026. Use claude55Sonnet instead.")
        public static let claude45Sonnet_20250929 = Model(modelID: .claude45Sonnet_20250929)
        public static let claude45Haiku_latest = Model(modelID: .claude45Haiku_latest)
        public static let claude45Haiku_20251001 = Model(modelID: .claude45Haiku_20251001)

        // MARK: - Claude Opus 4.7 / 4.8 (2026) - Active
        public static let claude47Opus = Model(modelID: .claude47Opus)
        public static let claude48Opus = Model(modelID: .claude48Opus)

        // MARK: - Claude 5 Generation (2026) - Active
        public static let claude5Opus = Model(modelID: .claude5Opus)
        public static let claude5Sonnet = Model(modelID: .claude5Sonnet)
        public static let claude5Fable = Model(modelID: .claude5Fable)
        public static let claude5Mythos = Model(modelID: .claude5Mythos)

        // MARK: - Claude 5.1 / 5.5 Generation (2026) - Active
        public static let claude51Fable = Model(modelID: .claude51Fable)
        public static let claude51Mythos = Model(modelID: .claude51Mythos)
        public static let claude55Opus = Model(modelID: .claude55Opus)
        public static let claude55Sonnet = Model(modelID: .claude55Sonnet)
        public static let claude55Haiku = Model(modelID: .claude55Haiku)

        // MARK: - Retired Models (kept for Codable round-trip compatibility only — will return API errors)
        // Note: Swift has no @available(*, retired) for members. @available(*, deprecated) is used
        // here as the strongest compile-time signal available; single-string Codable decoding is
        // unaffected by availability. Use `isRetired` for runtime checks.
        @available(*, deprecated, renamed: "claude5Opus", message: "[RETIRED Aug 2026] Will return API errors. Use claude5Opus instead.")
        public static let claude41Opus_latest = Model(modelID: .claude41Opus_latest)
        @available(*, deprecated, renamed: "claude5Opus", message: "[RETIRED Aug 2026] Will return API errors. Use claude5Opus instead.")
        public static let claude41Opus_20250805 = Model(modelID: .claude41Opus_20250805)
        @available(*, deprecated, renamed: "claude48Opus", message: "[RETIRED Jun 2026] Will return API errors. Use claude48Opus instead.")
        public static let claude4Opus_20250514 = Model(modelID: .claude4Opus_20250514)
        @available(*, deprecated, renamed: "claude46Sonnet", message: "[RETIRED Jun 2026] Will return API errors. Use claude46Sonnet instead.")
        public static let claude4Sonnet_20250514 = Model(modelID: .claude4Sonnet_20250514)
        @available(*, deprecated, renamed: "claude45Haiku_latest", message: "[RETIRED Apr 2026] Will return API errors. Use claude45Haiku_latest instead.")
        public static let claude3Haiku_20240307 = Model(modelID: .claude3Haiku_20240307)
        @available(*, deprecated, renamed: "claude46Sonnet", message: "[RETIRED Feb 2026] Will return API errors. Use claude46Sonnet instead.")
        public static let claude37Sonnet_20250219 = Model(modelID: .claude37Sonnet_20250219)
        @available(*, deprecated, renamed: "claude45Haiku_latest", message: "[RETIRED Feb 2026] Will return API errors. Use claude45Haiku_latest instead.")
        public static let claude35Haiku_20241022 = Model(modelID: .claude35Haiku_20241022)
        @available(*, deprecated, renamed: "claude46Sonnet", message: "[RETIRED Oct 2025] Will return API errors. Use claude46Sonnet instead.")
        public static let claude35Sonnet_latest = Model(modelID: .claude35Sonnet_latest)
        @available(*, deprecated, renamed: "claude46Sonnet", message: "[RETIRED Oct 2025] Will return API errors. Use claude46Sonnet instead.")
        public static let claude35Sonnet_20241022 = Model(modelID: .claude35Sonnet_20241022)
        @available(*, deprecated, renamed: "claude46Sonnet", message: "[RETIRED Oct 2025] Will return API errors. Use claude46Sonnet instead.")
        public static let claude35Sonnet_20240620 = Model(modelID: .claude35Sonnet_20240620)
        @available(*, deprecated, renamed: "claude46Opus", message: "[RETIRED Jan 2026] Will return API errors. Use claude46Opus instead.")
        public static let claude3Opus_latest = Model(modelID: .claude3Opus_latest)
        @available(*, deprecated, renamed: "claude46Opus", message: "[RETIRED Jan 2026] Will return API errors. Use claude46Opus instead.")
        public static let claude3Opus_20240229 = Model(modelID: .claude3Opus_20240229)
        @available(*, deprecated, renamed: "claude46Opus", message: "[RETIRED Jul 2025] Will return API errors. Use claude46Opus instead.")
        public static let claude3Sonnet_20240229 = Model(modelID: .claude3Sonnet_20240229)

        /// Canonical enumeration of every known Claude model ID; `CaseIterable`
        /// synthesis provides the single source of truth for `allCases`.
        public enum ModelID: String, Codable, CaseIterable {
            case claude46Opus = "claude-opus-4-6"
            case claude46Opus_20260205 = "claude-opus-4-6-20260205"
            case claude46Sonnet = "claude-sonnet-4-6"
            case claude46Sonnet_20260217 = "claude-sonnet-4-6-20260217"
            case claude45Opus_20251101 = "claude-opus-4-5-20251101"
            case claude45Sonnet_latest = "claude-sonnet-4-5-latest"
            case claude45Sonnet_20250929 = "claude-sonnet-4-5-20250929"
            case claude45Haiku_latest = "claude-haiku-4-5-latest"
            case claude45Haiku_20251001 = "claude-haiku-4-5-20251001"
            case claude47Opus = "claude-opus-4-7"
            case claude48Opus = "claude-opus-4-8"
            case claude5Opus = "claude-opus-5"
            case claude5Sonnet = "claude-sonnet-5"
            case claude5Fable = "claude-fable-5"
            case claude5Mythos = "claude-mythos-5"
            case claude51Fable = "claude-fable-5-1"
            case claude51Mythos = "claude-mythos-5-1"
            case claude55Opus = "claude-opus-5-5"
            case claude55Sonnet = "claude-sonnet-5-5"
            case claude55Haiku = "claude-haiku-5-5"
            case claude41Opus_latest = "claude-opus-4-1-latest"
            case claude41Opus_20250805 = "claude-opus-4-1-20250805"
            case claude4Opus_20250514 = "claude-opus-4-20250514"
            case claude4Sonnet_20250514 = "claude-sonnet-4-20250514"
            case claude3Haiku_20240307 = "claude-3-haiku-20240307"
            case claude37Sonnet_20250219 = "claude-3-7-sonnet-20250219"
            case claude35Haiku_20241022 = "claude-3-5-haiku-20241022"
            case claude35Sonnet_latest = "claude-3-5-sonnet-latest"
            case claude35Sonnet_20241022 = "claude-3-5-sonnet-20241022"
            case claude35Sonnet_20240620 = "claude-3-5-sonnet-20240620"
            case claude3Opus_latest = "claude-3-opus-latest"
            case claude3Opus_20240229 = "claude-3-opus-20240229"
            case claude3Sonnet_20240229 = "claude-3-sonnet-20240229"
        }
    }
}

// MARK: - CaseIterable
// Manual implementation (structs do not synthesize CaseIterable).
extension Anthropic.Model {
    /// All known models, including deprecated and retired ones (useful for Codable round-trips
    /// and exhaustive UI lists). For new requests, prefer `activeCases`.
    public static var allCases: [Anthropic.Model] {
        ModelID.allCases.map { Self(modelID: $0) }
    }

    /// Models that are fully supported and recommended for new requests.
    public static var activeCases: [Anthropic.Model] {
        [
            .claude46Opus, .claude46Opus_20260205,
            .claude46Sonnet, .claude46Sonnet_20260217,
            .claude45Opus_20251101,
            .claude45Haiku_latest, .claude45Haiku_20251001,
            .claude47Opus,
            .claude48Opus,
            .claude5Opus, .claude5Sonnet,
            .claude5Fable, .claude5Mythos,
            .claude51Fable, .claude51Mythos,
            .claude55Opus, .claude55Sonnet, .claude55Haiku,
        ]
    }

    /// Models that are deprecated (still functional, but retiring soon).
    /// Built via `customModelID` to avoid re-triggering deprecation warnings at call sites.
    public static var deprecatedCases: [Anthropic.Model] {
        [ModelID.claude45Sonnet_latest, ModelID.claude45Sonnet_20250929].map { Self(modelID: $0) }
    }

    /// Models that have been retired (will return API errors).
    /// Kept for Codable round-trip compatibility only.
    /// Built via `customModelID` to avoid triggering deprecation warnings at call sites.
    public static var retiredCases: [Anthropic.Model] {
        [
            ModelID.claude41Opus_latest, ModelID.claude41Opus_20250805,
            ModelID.claude4Opus_20250514, ModelID.claude4Sonnet_20250514,
            ModelID.claude3Haiku_20240307,
            ModelID.claude37Sonnet_20250219, ModelID.claude35Haiku_20241022,
            ModelID.claude35Sonnet_latest, ModelID.claude35Sonnet_20241022, ModelID.claude35Sonnet_20240620,
            ModelID.claude3Opus_latest, ModelID.claude3Opus_20240229, ModelID.claude3Sonnet_20240229,
        ].map { Self(modelID: $0) }
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
            .claude45Haiku_latest, .claude45Haiku_20251001,
            .claude47Opus,
            .claude48Opus,
            .claude5Opus, .claude5Sonnet,
            .claude5Fable, .claude5Mythos,
            .claude51Fable, .claude51Mythos,
            .claude55Opus, .claude55Sonnet, .claude55Haiku,
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
