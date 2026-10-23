import Foundation
import JSON
import LangTools

extension Ollama {
    public struct GenerateRequest: Codable, LangToolsRequest, LangToolsStreamableRequest {
        public typealias Response = GenerateResponse
        public typealias LangTool = Ollama
        
        public static var endpoint: String { "api/generate" }
        
        public let model: String
        public let prompt: String
        public let suffix: String?
        public let images: [String]?
        public let format: GenerateFormat?
        public let options: GenerateOptions?
        public let system: String?
        public let template: String?
        public var stream: Bool?
        public let raw: Bool?
        public let keep_alive: String?
        
        public init(
            model: String,
            prompt: String,
            suffix: String? = nil,
            images: [String]? = nil,
            format: GenerateFormat? = nil,
            options: GenerateOptions? = nil,
            system: String? = nil,
            template: String? = nil,
            stream: Bool? = nil,
            raw: Bool? = nil,
            keep_alive: String? = nil
        ) {
            self.model = model
            self.prompt = prompt
            self.suffix = suffix
            self.images = images
            self.format = format
            self.options = options
            self.system = system
            self.template = template
            self.stream = stream
            self.raw = raw
            self.keep_alive = keep_alive
        }
    }
    
    public struct GenerateResponse: Codable, LangToolsStreamableResponse {
        public typealias Delta = GenerateDelta
        
        public let model: String
        public let created_at: String
        public let response: String
        public let done: Bool
        public let done_reason: String?
        public let context: [Int]?
        public let total_duration: Int64?
        public let load_duration: Int64?
        public let prompt_eval_count: Int?
        public let prompt_eval_duration: Int64?
        public let eval_count: Int?
        public let eval_duration: Int64?
        
        public var delta: GenerateDelta? { nil }

        /// Ollama generate streams must end with a decoded `done: true` response.
        public func validateStreamCompletion() throws {
            guard done else { throw LangToolsError.incompleteStream }
        }
        
        public static var empty: GenerateResponse {
            return GenerateResponse(
                model: "",
                created_at: "",
                response: "",
                done: false,
                done_reason: nil,
                context: nil,
                total_duration: nil,
                load_duration: nil,
                prompt_eval_count: nil,
                prompt_eval_duration: nil,
                eval_count: nil,
                eval_duration: nil
            )
        }
        
        public func combining(with next: GenerateResponse) -> GenerateResponse {
            return GenerateResponse(
                model: next.model,
                created_at: next.created_at,
                response: response + next.response,
                done: next.done,
                done_reason: next.done_reason,
                context: next.context,
                total_duration: next.total_duration,
                load_duration: next.load_duration,
                prompt_eval_count: next.prompt_eval_count,
                prompt_eval_duration: next.prompt_eval_duration,
                eval_count: next.eval_count,
                eval_duration: next.eval_duration
            )
        }
    }
    
    public struct GenerateDelta: Codable {
        public let model: String?
        public let created_at: String?
        public let response: String?
        public let done: Bool?
        public let done_reason: String?
        public let context: [Int]?
    }
    
    public enum GenerateFormat: Codable, Equatable {
        case json
        case schema(SchemaFormat)
        case jsonSchema(JSONSchema)
        
        public struct SchemaFormat: Codable, Equatable {
            public let type: String
            public let properties: [String: PropertyFormat]
            public let required: [String]?

            public init(type: String, properties: [String: PropertyFormat], required: [String]?) {
                self.type = type
                self.properties = properties
                self.required = required
            }

            public struct PropertyFormat: Codable, Equatable {
                public let type: String
                public let description: String

                public init(type: String, description: String) {
                    self.type = type
                    self.description = description
                }

                enum CodingKeys: String, CodingKey {
                    case type, description
                }
            }
        }
        
        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .json:
                try container.encode("json")
            case .schema(let schema):
                try container.encode(schema)
            case .jsonSchema(let schema):
                try container.encode(schema)
            }
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()

            // Plain json string
            if let stringValue = try? container.decode(String.self),
               stringValue == "json" {
                self = .json
                return
            }

            // Decode as generic JSON tree so we can compare structural equality
            let rawJSON = try container.decode(JSON.self)
            let rawData = try JSONEncoder().encode(rawJSON)

            // Try legacy SchemaFormat first: only use it when the raw JSON
            // has no extra fields beyond what SchemaFormat encodes (type,
            // properties with type+description, required). If the schema
            // contains items, anyOf, additionalProperties, enum, min/max,
            // or any other JSONSchema field, those would be silently lost
            // by SchemaFormat, so we fall through to jsonSchema.
            if let schemaFormat = try? JSONDecoder().decode(SchemaFormat.self, from: rawData) {
                let schemaData = try JSONEncoder().encode(schemaFormat)
                let schemaJSON = try JSONDecoder().decode(JSON.self, from: schemaData)
                if schemaJSON == rawJSON {
                    self = .schema(schemaFormat)
                    return
                }
            }

            // Full JSONSchema (handles nested objects, arrays, anyOf, enums,
            // constraints, additionalProperties, and all other features).
            self = .jsonSchema(try JSONDecoder().decode(JSONSchema.self, from: rawData))
        }
    }
    
    public struct GenerateOptions: Codable {
        public let num_keep: Int?
        public let seed: Int?
        public let num_predict: Int?
        public let top_k: Int?
        public let top_p: Double?
        public let min_p: Double?
        public let typical_p: Double?
        public let repeat_last_n: Int?
        public let temperature: Double?
        public let repeat_penalty: Double?
        public let presence_penalty: Double?
        public let frequency_penalty: Double?
        public let mirostat: Int?
        public let mirostat_tau: Double?
        public let mirostat_eta: Double?
        public let penalize_newline: Bool?
        public let stop: [String]?
        public let numa: Bool?
        public let num_ctx: Int?
        public let num_batch: Int?
        public let num_gpu: Int?
        public let main_gpu: Int?
        public let low_vram: Bool?
        public let vocab_only: Bool?
        public let use_mmap: Bool?
        public let use_mlock: Bool?
        public let num_thread: Int?
        
        public init(
            num_keep: Int? = nil,
            seed: Int? = nil,
            num_predict: Int? = nil,
            top_k: Int? = nil,
            top_p: Double? = nil,
            min_p: Double? = nil,
            typical_p: Double? = nil,
            repeat_last_n: Int? = nil,
            temperature: Double? = nil,
            repeat_penalty: Double? = nil,
            presence_penalty: Double? = nil,
            frequency_penalty: Double? = nil,
            mirostat: Int? = nil,
            mirostat_tau: Double? = nil,
            mirostat_eta: Double? = nil,
            penalize_newline: Bool? = nil,
            stop: [String]? = nil,
            numa: Bool? = nil,
            num_ctx: Int? = nil,
            num_batch: Int? = nil,
            num_gpu: Int? = nil,
            main_gpu: Int? = nil,
            low_vram: Bool? = nil,
            vocab_only: Bool? = nil,
            use_mmap: Bool? = nil,
            use_mlock: Bool? = nil,
            num_thread: Int? = nil
        ) {
            self.num_keep = num_keep
            self.seed = seed
            self.num_predict = num_predict
            self.top_k = top_k
            self.top_p = top_p
            self.min_p = min_p
            self.typical_p = typical_p
            self.repeat_last_n = repeat_last_n
            self.temperature = temperature
            self.repeat_penalty = repeat_penalty
            self.presence_penalty = presence_penalty
            self.frequency_penalty = frequency_penalty
            self.mirostat = mirostat
            self.mirostat_tau = mirostat_tau
            self.mirostat_eta = mirostat_eta
            self.penalize_newline = penalize_newline
            self.stop = stop
            self.numa = numa
            self.num_ctx = num_ctx
            self.num_batch = num_batch
            self.num_gpu = num_gpu
            self.main_gpu = main_gpu
            self.low_vram = low_vram
            self.vocab_only = vocab_only
            self.use_mmap = use_mmap
            self.use_mlock = use_mlock
            self.num_thread = num_thread
        }
    }
}

// Convenience extension
public extension Ollama {
    /// Generate a completion for the given prompt.
    /// - Parameters:
    ///   - model: The model to use for completion
    ///   - prompt: The prompt to generate from
    ///   - options: Advanced model parameters
    ///   - stream: Whether to stream the response
    /// - Returns: A response containing the generated completion
    func generate(
        model: String,
        prompt: String,
        format: GenerateFormat? = nil,
        options: GenerateOptions? = nil
    ) async throws -> GenerateResponse {
        return try await perform(request: GenerateRequest(
            model: model,
            prompt: prompt,
            format: format,
            options: options
        ))
    }
    
    /// Stream a completion for the given prompt.
    func streamGenerate(
        model: String,
        prompt: String,
        options: GenerateOptions? = nil
    ) -> AsyncThrowingStream<GenerateResponse, Error> {
        return self.stream(request: GenerateRequest(
            model: model,
            prompt: prompt,
            options: options,
            stream: true
        ))
    }
}
