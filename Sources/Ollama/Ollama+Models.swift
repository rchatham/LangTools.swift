//
//  Ollama+Requests.swift
//  LangTools
//
//  Created by Claude on 1/18/25.
//

import Foundation
import LangTools

extension Ollama {
    public struct ListModelsRequest: LangToolsRequest {
        public typealias Response = ListModelsResponse
        public typealias LangTool = Ollama

        public static var endpoint: String { "api/tags" }
        public static var httpMethod: HTTPMethod { .get }
    }

    public struct ListModelsResponse: Codable {
        public let models: [ModelInfo]

        public struct ModelInfo: Codable {
            public let name: String
            public let modifiedAt: String
            public let size: Int64
            public let digest: String
            public let details: OllamaModel.Details

            enum CodingKeys: String, CodingKey {
                case name
                case modifiedAt = "modified_at"
                case size
                case digest
                case details
            }
        }
    }
}

// Convenience extension
public extension Ollama {
    /// Lists models that are available locally.
    /// - Returns: A `ListModelsResponse` containing information about available models.
    /// - Throws: An error if the request fails or the response cannot be decoded.
    func listModels() async throws -> ListModelsResponse {
        return try await perform(request: ListModelsRequest())
    }
}

extension Ollama {
    public struct ListRunningModelsRequest: LangToolsRequest {
        public typealias Response = ListRunningModelsResponse
        public typealias LangTool = Ollama

        public static var endpoint: String { "api/ps" }
        public static var httpMethod: HTTPMethod { .get }
    }

    public struct ListRunningModelsResponse: Codable {
        public let models: [RunningModelInfo]

        public struct RunningModelInfo: Codable {
            public let name: String
            public let model: String
            public let size: Int64
            public let digest: String
            public let details: OllamaModel.Details
            public let expiresAt: String
            public let sizeVRAM: Int64

            enum CodingKeys: String, CodingKey {
                case name, model, size, digest, details
                case expiresAt = "expires_at"
                case sizeVRAM = "size_vram"
            }
        }
    }
}

// Convenience extension
public extension Ollama {
    /// Lists models that are currently loaded in memory.
    /// - Returns: A `ListRunningModelsResponse` containing information about running models.
    /// - Throws: An error if the request fails or the response cannot be decoded.
    func listRunningModels() async throws -> ListRunningModelsResponse {
        return try await perform(request: ListRunningModelsRequest())
    }
}

extension Ollama {
    public struct ShowModelRequest: LangToolsRequest {
        public typealias Response = ShowModelResponse
        public typealias LangTool = Ollama

        public static var endpoint: String { "api/show" }

        public let model: String
        public let verbose: Bool?

        public init(model: String, verbose: Bool? = nil) {
            self.model = model
            self.verbose = verbose
        }
    }

    public struct ShowModelResponse: Codable {
        public let modelfile: String
        public let parameters: String
        public let template: String
        public let details: OllamaModel.Details
        public let modelInfo: [String: JSON]

        enum CodingKeys: String, CodingKey {
            case modelfile, parameters, template, details
            case modelInfo = "model_info"
        }
    }
}

// Convenience extension
public extension Ollama {
    /// Shows information about a model.
    /// - Parameters:
    ///   - model: The name of the model to show information for.
    ///   - verbose: If true, returns full data for verbose response fields.
    /// - Returns: A `ShowModelResponse` containing details about the model.
    /// - Throws: An error if the request fails or the response cannot be decoded.
    func showModel(_ model: String, verbose: Bool? = nil) async throws -> ShowModelResponse {
        return try await perform(request: ShowModelRequest(model: model, verbose: verbose))
    }
}

extension Ollama {
    public struct DeleteModelRequest: LangToolsRequest {
        public typealias Response = DeleteModelResponse
        public typealias LangTool = Ollama

        public static var endpoint: String { "api/delete" }
        public static var httpMethod: HTTPMethod { .delete }

        public let model: String

        public init(model: String) {
            self.model = model
        }
    }

    public struct DeleteModelResponse: Codable {
        public let status: String
    }
}

// Convenience extension
public extension Ollama {
    /// Deletes a model and its data.
    /// - Parameter model: The name of the model to delete.
    /// - Returns: A response indicating success or failure.
    /// - Throws: An error if the operation fails.
    func deleteModel(_ model: String) async throws -> DeleteModelResponse {
        return try await perform(request: DeleteModelRequest(model: model))
    }
}

extension Ollama {
    public struct CopyModelRequest: LangToolsRequest {
        public typealias Response = CopyModelResponse
        public typealias LangTool = Ollama

        public static var endpoint: String { "api/copy" }

        public let source: String
        public let destination: String

        public init(source: String, destination: String) {
            self.source = source
            self.destination = destination
        }
    }

    public struct CopyModelResponse: Codable {
        public let status: String
    }
}

// Convenience extension
public extension Ollama {
    /// Copies a model from one name to another.
    /// - Parameters:
    ///   - source: The name of the source model.
    ///   - destination: The name to copy the model to.
    /// - Returns: A response indicating success or failure.
    /// - Throws: An error if the operation fails.
    func copyModel(source: String, destination: String) async throws -> CopyModelResponse {
        return try await perform(request: CopyModelRequest(source: source, destination: destination))
    }
}

extension Ollama {
    public struct PullModelRequest: Codable, LangToolsRequest, LangToolsStreamableRequest {
        public typealias Response = PullModelResponse
        public typealias LangTool = Ollama

        public static var endpoint: String { "api/pull" }

        public let model: String
        public let insecure: Bool?
        public var stream: Bool?

        public init(model: String, insecure: Bool? = nil, stream: Bool? = nil) {
            self.model = model
            self.insecure = insecure
            self.stream = stream
        }
    }

    public struct PullModelResponse: Codable, LangToolsStreamableResponse {
        public typealias Delta = PullDelta

        public let status: String
        public let digest: String?
        public let total: Int64?
        public let completed: Int64?

        public var delta: PullDelta? { nil }

        public static var empty: PullModelResponse {
            return PullModelResponse(status: "", digest: nil, total: nil, completed: nil)
        }

        public func combining(with next: PullModelResponse) -> PullModelResponse {
            return next
        }
    }

    public struct PullDelta: Codable {
        public let status: String?
        public let digest: String?
        public let total: Int64?
        public let completed: Int64?
    }
}

// Convenience extension
public extension Ollama {
    /// Downloads a model from the Ollama library.
    /// - Parameters:
    ///   - model: The name of the model to pull.
    ///   - insecure: Allow insecure connections to the library.
    /// - Returns: A streaming response indicating download progress.
    /// - Throws: An error if the operation fails.
    func pullModel(_ model: String, insecure: Bool = false) async throws -> PullModelResponse {
        return try await perform(request: PullModelRequest(model: model, insecure: insecure))
    }

    func streamPullModel(_ model: String, insecure: Bool = false) -> AsyncThrowingStream<PullModelResponse, Error> {
        return stream(request: PullModelRequest(model: model, insecure: insecure, stream: true))
    }
}

extension Ollama {
    public struct PushModelRequest: Codable, LangToolsRequest, LangToolsStreamableRequest {
        public typealias Response = PushModelResponse
        public typealias LangTool = Ollama

        public static var endpoint: String { "api/push" }

        public let model: String
        public let insecure: Bool?
        public var stream: Bool?

        public init(model: String, insecure: Bool? = nil, stream: Bool? = nil) {
            self.model = model
            self.insecure = insecure
            self.stream = stream
        }
    }

    public struct PushModelResponse: Codable, LangToolsStreamableResponse {
        public typealias Delta = PushDelta

        public let status: String
        public let digest: String?
        public let total: Int64?

        public var delta: PushDelta? { nil }

        public static var empty: PushModelResponse {
            return PushModelResponse(status: "", digest: nil, total: nil)
        }

        public func combining(with next: PushModelResponse) -> PushModelResponse {
            return next
        }
    }

    public struct PushDelta: Codable {
        public let status: String?
        public let digest: String?
        public let total: Int64?
    }
}

// Convenience extension
public extension Ollama {
    /// Uploads a model to the Ollama library.
    /// - Parameters:
    ///   - model: The model name in the format namespace/model:tag.
    ///   - insecure: Allow insecure connections to the library.
    /// - Returns: A streaming response indicating upload progress.
    /// - Throws: An error if the operation fails.
    func pushModel(_ model: String, insecure: Bool = false) async throws -> PushModelResponse {
        return try await perform(request: PushModelRequest(model: model, insecure: insecure))
    }

    func streamPushModel(_ model: String, insecure: Bool = false) -> AsyncThrowingStream<PushModelResponse, Error> {
        return stream(request: PushModelRequest(model: model, insecure: insecure, stream: true))
    }
}

extension Ollama {
    public struct CreateModelRequest: LangToolsRequest {
        public typealias Response = CreateModelResponse
        public typealias LangTool = Ollama

        public static var endpoint: String { "api/create" }

        public let model: String
        public let modelfile: String?
        public let path: String?

        public init(model: String, modelfile: String? = nil, path: String? = nil) {
            self.model = model
            self.modelfile = modelfile
            self.path = path
        }
    }

    public struct CreateModelResponse: Codable {
        public let status: String
    }
}

// Convenience extension
public extension Ollama {
    /// Creates a model from a Modelfile.
    /// - Parameters:
    ///   - model: The name of the model to create.
    ///   - modelfile: The contents of the Modelfile.
    ///   - path: The path to the Modelfile.
    /// - Returns: A response indicating success or failure.
    /// - Throws: An error if the operation fails.
    func createModel(model: String, modelfile: String? = nil, path: String? = nil) async throws -> CreateModelResponse {
        return try await perform(request: CreateModelRequest(model: model, modelfile: modelfile, path: path))
    }
}

extension Ollama {
    public struct VersionRequest: LangToolsRequest {
        public typealias Response = VersionResponse
        public typealias LangTool = Ollama

        public static var endpoint: String { "api/version" }
        public static var httpMethod: HTTPMethod { .get }
    }

    public struct VersionResponse: Codable {
        public let version: String
    }
}

// Convenience extension
public extension Ollama {
    /// Retrieves the version of the Ollama server
    /// - Returns: A `VersionResponse` containing the version string
    /// - Throws: An error if the request fails or the response cannot be decoded
    func version() async throws -> VersionResponse {
        return try await perform(request: VersionRequest())
    }
}
