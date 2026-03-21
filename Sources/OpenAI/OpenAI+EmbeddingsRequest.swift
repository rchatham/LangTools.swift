//
//  OpenAI+Embeddings.swift
//  LangTools
//
//  Created by Reid Chatham on 1/8/25.
//

import Foundation
import LangTools

extension OpenAI {
    /// Creates an embedding vector representing the input text.
    public struct EmbeddingsRequest: LangToolsRequest {
        public typealias Response = EmbeddingsResponse
        public typealias LangTool = OpenAI
        public static var endpoint: String { "embeddings" }

        /// Input text to embed, encoded as a string or array of tokens
        public let input: Input
        /// ID of the model to use
        public let model: Model
        /// The format to return the embeddings in
        public let encoding_format: EncodingFormat?
        /// The number of dimensions the resulting output embeddings should have
        public let dimensions: Int?
        /// A unique identifier representing your end-user
        public let user: String?

        public init(input: Input, model: Model = .textEmbedding3Small, encoding_format: EncodingFormat? = nil, dimensions: Int? = nil, user: String? = nil) {
            self.input = input
            self.model = model
            self.encoding_format = encoding_format
            self.dimensions = dimensions
            self.user = user
        }

        public enum Input: Encodable {
            case string(String)
            case stringArray([String])
            case intArray([Int])
            case intArrayArray([[Int]])

            public func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .string(let str): try container.encode(str)
                case .stringArray(let arr): try container.encode(arr)
                case .intArray(let arr): try container.encode(arr)
                case .intArrayArray(let arr): try container.encode(arr)
                }
            }
        }

        public enum EncodingFormat: String, Codable {
            case float
            case base64
        }
    }

    /// Response from the embeddings endpoint containing embedding vectors
    public struct EmbeddingsResponse: Codable {
        public let object: String
        public let data: [Embedding]
        public let model: String
        public let usage: Usage

        public struct Embedding: Codable {
            public let index: Int
            public let embedding: [Float]
            public let object: String
        }

        public struct Usage: Codable {
            public let prompt_tokens: Int
            public let total_tokens: Int
        }
    }
}

