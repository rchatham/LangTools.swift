import LangTools

// MARK: - List Models

extension Ollama {
    public struct ListModelsResponse: Decodable {
        public struct Model: Decodable {
            public let name: String
            public let modifiedAt: String
            public let size: Int64
            public let digest: String
            public let details: OllamaModel.Details

            private enum CodingKeys: String, CodingKey {
                case name
                case modifiedAt = "modified_at"
                case size
                case digest
                case details
            }
        }

        public let models: [Model]
    }

    /// Lists models that are available locally.
    ///
    /// - Returns: A `ListModelsResponse` containing information about available models.
    /// - Throws: An error if the request fails or the response cannot be decoded.
    public func listModels() async throws -> ListModelsResponse {
        return try await fetch(.get, "/api/tags")
    }
}

// MARK: - List Running Models

extension Ollama {
    public struct ListRunningModelsResponse: Decodable {
        public struct Model: Decodable {
            public let name: String
            public let model: String
            public let size: Int64
            public let digest: String
            public let details: Ollama.Model.Details
            public let expiresAt: String
            public let sizeVRAM: Int64

            private enum CodingKeys: String, CodingKey {
                case name
                case model
                case size
                case digest
                case details
                case expiresAt = "expires_at"
                case sizeVRAM = "size_vram"
            }
        }

        public let models: [Model]
    }

    /// Lists models that are currently loaded into memory.
    ///
    /// - Returns: A `ListRunningModelsResponse` containing information about running models.
    /// - Throws: An error if the request fails or the response cannot be decoded.
    public func listRunningModels() async throws -> ListRunningModelsResponse {
        return try await fetch(.get, "/api/ps")
    }
}

// MARK: - Create Model

extension Ollama {
    /// Creates a model from a Modelfile.
    ///
    /// - Parameters:
    ///   - name: The name of the model to create.
    ///   - modelfile: The contents of the Modelfile.
    ///   - path: The path to the Modelfile.
    /// - Returns: `true` if the model was successfully created, otherwise `false`.
    /// - Throws: An error if the request fails.
    public func createModel(name: Model.ID, modelfile: String? = nil, path: String? = nil)
        async throws -> Bool
    {
        var params: [String: Value] = ["name": .string(name.rawValue)]
        if let modelfile = modelfile {
            params["modelfile"] = .string(modelfile)
        }
        if let path = path {
            params["path"] = .string(path)
        }
        return try await fetch(.post, "/api/create", params: params)
    }
}

// MARK: - Copy Model

extension Ollama {
    /// Copies a model.
    ///
    /// - Parameters:
    ///   - source: The name of the source model.
    ///   - destination: The name of the destination model.
    /// - Returns: `true` if the model was successfully copied, otherwise `false`.
    /// - Throws: An error if the request fails.
    public func copyModel(source: String, destination: String) async throws -> Bool {
        let params: [String: Value] = [
            "source": .string(source),
            "destination": .string(destination),
        ]
        return try await fetch(.post, "/api/copy", params: params)
    }
}

// MARK: - Delete Model

extension Ollama {
    /// Deletes a model and its data.
    ///
    /// - Parameter id: The name of the model to delete.
    /// - Returns: `true` if the model was successfully deleted, otherwise `false`.
    /// - Throws: An error if the operation fails.
    public func deleteModel(_ id: Model.ID) async throws -> Bool {
        return try await fetch(.delete, "/api/delete", params: ["name": .string(id.rawValue)])
    }
}

// MARK: - Pull Model

extension Ollama {
    /// Downloads a model from the Ollama library.
    ///
    /// - Parameters:
    ///   - id: The name of the model to pull.
    ///   - insecure: If true, allows insecure connections to the library. Only use this if you are pulling from your own library during development.
    /// - Returns: `true` if the model was successfully pulled, otherwise `false`.
    /// - Throws: An error if the operation fails.
    ///
    /// - Note: Cancelled pulls are resumed from where they left off, and multiple calls will share the same download progress.
    public func pullModel(
        _ id: Model.ID,
        insecure: Bool = false
    ) async throws -> Bool {
        let params: [String: Value] = [
            "name": .string(id.rawValue),
            "insecure": .bool(insecure),
            "stream": false,
        ]
        return try await fetch(.post, "/api/pull", params: params)
    }
}

// MARK: - Push Model

extension Ollama {
    /// Uploads a model to a model library.
    ///
    /// - Parameters:
    ///   - id: The name of the model to push in the form of "namespace/model:tag".
    ///   - insecure: If true, allows insecure connections to the library. Only use this if you are pushing to your library during development.
    /// - Returns: `true` if the model was successfully pushed, otherwise `false`.
    /// - Throws: An error if the operation fails.
    ///
    /// - Note: Requires registering for ollama.ai and adding a public key first.
    public func pushModel(
        _ id: Model.ID,
        insecure: Bool = false
    ) async throws -> Bool {
        let params: [String: Value] = [
            "name": .string(id.rawValue),
            "insecure": .bool(insecure),
            "stream": false,
        ]
        return try await fetch(.post, "/api/push", params: params)
    }
}

// MARK: - Show Model

extension Ollama {
    /// A response containing information about a model.
    public struct ShowModelResponse: Decodable {
        /// The contents of the Modelfile for the model.
        let modelfile: String

        /// The model parameters.
        let parameters: String

        /// The prompt template used by the model.
        let template: String

        /// Detailed information about the model.
        let details: Model.Details

        /// Additional model information.
        let info: [String: Value]

        private enum CodingKeys: String, CodingKey {
            case modelfile
            case parameters
            case template
            case details
            case info = "model_info"
        }
    }

    /// Shows information about a model.
    ///
    /// - Parameter id: The identifier of the model to show information for.
    /// - Returns: A `ShowModelResponse` containing details about the model.
    /// - Throws: An error if the request fails or the response cannot be decoded.
    public func showModel(_ id: Model.ID) async throws -> ShowModelResponse {
        let params: [String: Value] = [
            "name": .string(id.rawValue)
        ]

        return try await fetch(.post, "/api/show", params: params)
    }
}
