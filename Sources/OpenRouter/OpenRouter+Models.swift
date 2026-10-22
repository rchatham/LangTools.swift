//
//  OpenRouter+Models.swift
//  LangTools
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LangTools

extension OpenRouter {
    /// Lists the catalog with `GET /models`. With no paging parameters the
    /// endpoint returns the full list; by default it includes text models only.
    public func listModels(_ request: ListModelsRequest = ListModelsRequest()) async throws -> [ModelInfo] {
        try await perform(request: request).data
    }

    public struct ListModelsRequest: LangToolsRequest, Encodable {
        public typealias Response = ListModelsResponse
        public typealias LangTool = OpenRouter
        public static var endpoint: String { "models" }
        public static var httpMethod: HTTPMethod { .get }

        /// Only models supporting every listed parameter, such as `"tools"`.
        public var supportedParameters: [String]?
        /// Output modalities to include, such as `"text"` or `"image"`.
        public var outputModalities: [String]?
        /// A use-case category, such as `"programming"`.
        public var category: String?

        public init(supportedParameters: [String]? = nil, outputModalities: [String]? = nil, category: String? = nil) {
            self.supportedParameters = supportedParameters
            self.outputModalities = outputModalities
            self.category = category
        }

        /// GET requests carry no body.
        public func encode(to encoder: Encoder) throws {}

        var queryItems: [URLQueryItem] {
            var items: [URLQueryItem] = []
            if let supportedParameters, !supportedParameters.isEmpty {
                items.append(URLQueryItem(name: "supported_parameters", value: supportedParameters.joined(separator: ",")))
            }
            if let outputModalities, !outputModalities.isEmpty {
                items.append(URLQueryItem(name: "output_modalities", value: outputModalities.joined(separator: ",")))
            }
            if let category, !category.isEmpty {
                items.append(URLQueryItem(name: "category", value: category))
            }
            return items
        }

        func url(relativeTo baseURL: URL) -> URL {
            let url = baseURL.appending(path: Self.endpoint)
            return queryItems.isEmpty ? url : url.appending(queryItems: queryItems)
        }
    }

    public struct ListModelsResponse: Decodable {
        public let data: [ModelInfo]

        private enum CodingKeys: String, CodingKey { case data }

        /// Skips an entry that fails to decode, or whose id is not a usable slug,
        /// rather than failing the whole catalog, since OpenRouter adds fields and
        /// model types over time.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            var entries = try container.nestedUnkeyedContainer(forKey: .data)
            var models: [ModelInfo] = []
            while !entries.isAtEnd {
                if let model = try? entries.decode(ModelInfo.self) {
                    if OpenRouterModel(rawValue: model.id) != nil { models.append(model) }
                } else {
                    _ = try entries.decode(JSON.self)
                }
            }
            data = models
        }
    }

    /// One catalog entry. Only `id` is required; everything else is optional so
    /// that catalog changes do not break decoding.
    public struct ModelInfo: Codable, Identifiable {
        public let id: String
        public let name: String?
        public let canonicalSlug: String?
        public let created: Int?
        public let description: String?
        public let contextLength: Int?
        public let architecture: Architecture?
        /// Prices in US dollars per token (or per request or image), as decimal strings.
        public let pricing: Pricing?
        public let topProvider: TopProvider?
        /// Request parameters the model accepts, such as `"tools"` or `"structured_outputs"`.
        public let supportedParameters: [String]?

        public init(id: String, name: String? = nil, canonicalSlug: String? = nil, created: Int? = nil, description: String? = nil, contextLength: Int? = nil, architecture: Architecture? = nil, pricing: Pricing? = nil, topProvider: TopProvider? = nil, supportedParameters: [String]? = nil) {
            self.id = id
            self.name = name
            self.canonicalSlug = canonicalSlug
            self.created = created
            self.description = description
            self.contextLength = contextLength
            self.architecture = architecture
            self.pricing = pricing
            self.topProvider = topProvider
            self.supportedParameters = supportedParameters
        }

        private enum CodingKeys: String, CodingKey {
            case id, name, created, description, architecture, pricing
            case canonicalSlug = "canonical_slug"
            case contextLength = "context_length"
            case topProvider = "top_provider"
            case supportedParameters = "supported_parameters"
        }

        public var model: OpenRouterModel { OpenRouterModel(stringLiteral: id) }
        public var supportsTools: Bool { supportedParameters?.contains("tools") ?? false }
        public var supportsStructuredOutput: Bool { supportedParameters?.contains("structured_outputs") ?? false }

        public struct Architecture: Codable {
            public let modality: String?
            public let inputModalities: [String]?
            public let outputModalities: [String]?

            public init(modality: String? = nil, inputModalities: [String]? = nil, outputModalities: [String]? = nil) {
                self.modality = modality
                self.inputModalities = inputModalities
                self.outputModalities = outputModalities
            }

            private enum CodingKeys: String, CodingKey {
                case modality
                case inputModalities = "input_modalities"
                case outputModalities = "output_modalities"
            }
        }

        public struct Pricing: Codable {
            public let prompt: String?
            public let completion: String?
            public let request: String?
            public let image: String?
            public let inputCacheRead: String?
            public let inputCacheWrite: String?

            public init(prompt: String? = nil, completion: String? = nil, request: String? = nil, image: String? = nil, inputCacheRead: String? = nil, inputCacheWrite: String? = nil) {
                self.prompt = prompt
                self.completion = completion
                self.request = request
                self.image = image
                self.inputCacheRead = inputCacheRead
                self.inputCacheWrite = inputCacheWrite
            }

            private enum CodingKeys: String, CodingKey {
                case prompt, completion, request, image
                case inputCacheRead = "input_cache_read"
                case inputCacheWrite = "input_cache_write"
            }
        }

        public struct TopProvider: Codable {
            public let contextLength: Int?
            public let maxCompletionTokens: Int?
            public let isModerated: Bool?

            public init(contextLength: Int? = nil, maxCompletionTokens: Int? = nil, isModerated: Bool? = nil) {
                self.contextLength = contextLength
                self.maxCompletionTokens = maxCompletionTokens
                self.isModerated = isModerated
            }

            private enum CodingKeys: String, CodingKey {
                case contextLength = "context_length"
                case maxCompletionTokens = "max_completion_tokens"
                case isModerated = "is_moderated"
            }
        }
    }
}
