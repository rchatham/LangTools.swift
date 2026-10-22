//
//  Gemini+GenerateContent.swift
//  LangTools
//
//  Gemini's native API (`models/{model}:generateContent` and
//  `:streamGenerateContent`), served beside the OpenAI-compatible endpoint.
//  It adds what the OpenAI format cannot carry: grounding with Google Search,
//  thinking configuration and thought signatures, safety settings, and
//  inline media parts.
//

import Foundation
import LangTools
import OpenAI

extension Gemini {
    /// Builds a native request; `chatRequest` builds an OpenAI-compatible one.
    public static func generateContentRequest(modelID: String, messages: [any LangToolsMessage], tools: [any LangToolsTool]? = nil, responseSchema: JSONSchema? = nil, toolEventHandler: @escaping (LangToolsToolEvent) -> Void = { _ in }) -> GenerateContentRequest {
        var request = GenerateContentRequest(modelID: modelID, messages: messages.map { Message($0) }, tools: tools?.map { OpenAI.Tool($0) }, toolEventHandler: toolEventHandler)
        request.responseSchema = responseSchema
        return request
    }

    /// A `generateContent` request. The model travels in the URL, so a
    /// request can name any model by `modelID`; `model` is the matching
    /// `Gemini.Model` case, or `.gemini3Flash` for IDs outside the enum.
    public struct GenerateContentRequest: Codable, LangToolsChatRequest, LangToolsStreamableRequest, LangToolsToolCallingRequest, LangToolsStructuredOutputRequest {
        public typealias Response = GenerateContentResponse
        public typealias LangTool = Gemini
        /// The URL is built by `Gemini.prepare` from `modelID` and `stream`.
        public static var endpoint: String { "generateContent" }

        public let model: GeminiModel
        public let modelID: String
        public var messages: [Message]
        /// Selects `streamGenerateContent`; not part of the body.
        public var stream: Bool?
        public let tools: [OpenAI.Tool]?
        /// Grounds answers in Google Search results, reported in
        /// `groundingMetadata`.
        public let googleSearch: Bool
        public let functionCallingMode: FunctionCallingMode?
        public var generationConfig: GenerationConfig?
        public let safetySettings: [SafetySetting]?
        /// A cached-content resource name, such as `cachedContents/abc`.
        public let cachedContent: String?

        @CodableIgnored
        public var toolEventHandler: ((LangToolsToolEvent) -> Void)?

        public var responseSchema: JSONSchema? {
            get { generationConfig?.responseJsonSchema }
            set {
                var config = generationConfig ?? GenerationConfig()
                config.responseJsonSchema = newValue
                config.responseMimeType = newValue == nil ? nil : "application/json"
                generationConfig = config
            }
        }

        public init(model: GeminiModel, messages: [any LangToolsMessage]) {
            self.init(model: model, messages: messages.map { Message($0) })
        }

        public init(model: GeminiModel, messages: [Message], stream: Bool? = nil, tools: [OpenAI.Tool]? = nil, googleSearch: Bool = false, functionCallingMode: FunctionCallingMode? = nil, generationConfig: GenerationConfig? = nil, safetySettings: [SafetySetting]? = nil, cachedContent: String? = nil, toolEventHandler: ((LangToolsToolEvent) -> Void)? = nil) {
            self.init(modelID: model.rawValue, messages: messages, stream: stream, tools: tools, googleSearch: googleSearch, functionCallingMode: functionCallingMode, generationConfig: generationConfig, safetySettings: safetySettings, cachedContent: cachedContent, toolEventHandler: toolEventHandler)
        }

        public init(modelID: String, messages: [Message], stream: Bool? = nil, tools: [OpenAI.Tool]? = nil, googleSearch: Bool = false, functionCallingMode: FunctionCallingMode? = nil, generationConfig: GenerationConfig? = nil, safetySettings: [SafetySetting]? = nil, cachedContent: String? = nil, toolEventHandler: ((LangToolsToolEvent) -> Void)? = nil) {
            self.model = GeminiModel(rawValue: modelID) ?? .gemini3Flash
            self.modelID = modelID
            self.messages = messages
            self.stream = stream
            self.tools = tools
            self.googleSearch = googleSearch
            self.functionCallingMode = functionCallingMode
            self.generationConfig = generationConfig
            self.safetySettings = safetySettings
            self.cachedContent = cachedContent
            self.toolEventHandler = toolEventHandler
        }

        /// The model's resource path: `models/<id>`, or the ID itself when it
        /// already names a resource such as `tunedModels/<id>`.
        public var modelPath: String { modelID.contains("/") ? modelID : "models/\(modelID)" }

        public enum FunctionCallingMode: String, Codable {
            case auto = "AUTO", any = "ANY", none = "NONE", validated = "VALIDATED"
        }

        public struct GenerationConfig: Codable {
            public var temperature: Double?
            public var topP: Double?
            public var topK: Int?
            public var maxOutputTokens: Int?
            public var stopSequences: [String]?
            public var seed: Int?
            public var presencePenalty: Double?
            public var frequencyPenalty: Double?
            public var responseMimeType: String?
            public var responseJsonSchema: JSONSchema?
            public var thinkingConfig: ThinkingConfig?

            public init(temperature: Double? = nil, topP: Double? = nil, topK: Int? = nil, maxOutputTokens: Int? = nil, stopSequences: [String]? = nil, seed: Int? = nil, presencePenalty: Double? = nil, frequencyPenalty: Double? = nil, responseMimeType: String? = nil, responseJsonSchema: JSONSchema? = nil, thinkingConfig: ThinkingConfig? = nil) {
                self.temperature = temperature
                self.topP = topP
                self.topK = topK
                self.maxOutputTokens = maxOutputTokens
                self.stopSequences = stopSequences
                self.seed = seed
                self.presencePenalty = presencePenalty
                self.frequencyPenalty = frequencyPenalty
                self.responseMimeType = responseMimeType
                self.responseJsonSchema = responseJsonSchema
                self.thinkingConfig = thinkingConfig
            }
        }

        public struct ThinkingConfig: Codable {
            /// Gemini 3: `"minimal"`, `"low"`, `"medium"`, or `"high"`.
            public var thinkingLevel: String?
            /// Gemini 2.5: a token budget; `-1` lets the model decide.
            public var thinkingBudget: Int?
            /// Returns thought summaries as `thought` parts.
            public var includeThoughts: Bool?

            public init(thinkingLevel: String? = nil, thinkingBudget: Int? = nil, includeThoughts: Bool? = nil) {
                self.thinkingLevel = thinkingLevel
                self.thinkingBudget = thinkingBudget
                self.includeThoughts = includeThoughts
            }
        }

        public struct SafetySetting: Codable {
            /// Such as `"HARM_CATEGORY_HARASSMENT"`.
            public let category: String
            /// Such as `"BLOCK_ONLY_HIGH"` or `"BLOCK_NONE"`.
            public let threshold: String

            public init(category: String, threshold: String) {
                self.category = category
                self.threshold = threshold
            }
        }

        private enum CodingKeys: String, CodingKey {
            case modelID, contents, systemInstruction, tools, toolConfig, generationConfig, safetySettings, cachedContent
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            let system = messages.filter { $0.role == .system }.map(\.content.text).filter { !$0.isEmpty }
            if !system.isEmpty {
                try container.encode(Content(role: nil, parts: [Part(text: system.joined(separator: "\n\n"))]), forKey: .systemInstruction)
            }
            try container.encode(wireContents, forKey: .contents)
            var toolEntries: [JSON] = []
            if let tools, !tools.isEmpty {
                toolEntries.append(.object(["functionDeclarations": .array(try tools.map(Self.functionDeclaration))]))
            }
            if googleSearch { toolEntries.append(.object(["googleSearch": .object([:])])) }
            if !toolEntries.isEmpty { try container.encode(toolEntries, forKey: .tools) }
            if let functionCallingMode {
                try container.encode(JSON.object(["functionCallingConfig": .object(["mode": .string(functionCallingMode.rawValue)])]), forKey: .toolConfig)
            }
            if var generationConfig {
                generationConfig.responseJsonSchema = nil
                var config = try Self.json(generationConfig)
                if let schema = responseSchema, case .object(var object) = config {
                    object["responseJsonSchema"] = Self.replacingConst(try Self.json(schema))
                    config = .object(object)
                }
                try container.encode(config, forKey: .generationConfig)
            }
            try container.encodeIfPresent(safetySettings, forKey: .safetySettings)
            try container.encodeIfPresent(cachedContent, forKey: .cachedContent)
        }

        public init(from decoder: Decoder) throws {
            // Decoding is for inspecting an encoded request; it recovers the
            // configuration but not the conversation.
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(modelID: try container.decodeIfPresent(String.self, forKey: .modelID) ?? GeminiModel.gemini3Flash.rawValue, messages: [], generationConfig: try container.decodeIfPresent(GenerationConfig.self, forKey: .generationConfig), safetySettings: try container.decodeIfPresent([SafetySetting].self, forKey: .safetySettings), cachedContent: try container.decodeIfPresent(String.self, forKey: .cachedContent))
        }

        /// The conversation as Gemini `contents`: system messages move to
        /// `systemInstruction`, function responses carry the name of the call
        /// they answer, and Gemini 3 function calls replayed without a thought
        /// signature get Google's documented placeholder.
        var wireContents: [Content] {
            var callNames: [String: String] = [:]
            for message in messages { for call in message.tool_calls { if let id = call.id { callNames[id] = call.name } } }
            let needsSignatures = modelID.hasPrefix("gemini-3")
            return messages.filter { $0.role != .system }.map { message in
                var parts = message.parts.map { part -> Part in
                    guard var response = part.functionResponse, response.name == nil, let id = response.id else { return part }
                    response.name = callNames[id]
                    var resolved = part
                    resolved.functionResponse = response
                    return resolved
                }
                if needsSignatures, message.role == .model,
                   !parts.contains(where: { $0.thoughtSignature != nil }),
                   let first = parts.firstIndex(where: { $0.functionCall != nil }) {
                    parts[first].thoughtSignature = Part.skipThoughtSignatureValidator
                }
                return Content(role: message.role.wireValue, parts: parts)
            }
        }

        private static func functionDeclaration(_ tool: OpenAI.Tool) throws -> JSON {
            var declaration: [String: JSON] = ["name": .string(tool.name), "parametersJsonSchema": try json(tool.tool_schema)]
            if let description = tool.description { declaration["description"] = .string(description) }
            return .object(declaration)
        }

        private static func json<T: Encodable>(_ value: T) throws -> JSON {
            try JSONDecoder().decode(JSON.self, from: JSONEncoder().encode(value))
        }

        /// `responseJsonSchema` does not accept `const`; a one-value `enum`
        /// says the same.
        static func replacingConst(_ schema: JSON) -> JSON {
            switch schema {
            case .object(var object):
                if let value = object.removeValue(forKey: "const") { object["enum"] = .array([value]) }
                return .object(object.mapValues(replacingConst))
            case .array(let items):
                return .array(items.map(replacingConst))
            default:
                return schema
            }
        }
    }

    public struct GenerateContentResponse: Decodable, LangToolsStreamableChatResponse, LangToolsToolCallingResponse, LangToolsStructuredOutputResponse {
        public typealias Delta = ChatDelta
        public typealias Message = Gemini.Message
        public typealias ToolSelection = ToolCall

        public var responseId: String?
        public var modelVersion: String?
        public var candidates: [Candidate]
        public var usageMetadata: UsageMetadata?
        public var promptFeedback: PromptFeedback?
        /// An error sent in place of a chunk after the stream started.
        public var error: NativeError?

        public var message: Message? { candidates.first?.content }
        public var finishReason: String? { candidates.first?.finishReason }

        /// The answer text in this chunk, without thought summaries.
        public var delta: ChatDelta? {
            let text = message?.content.text ?? ""
            return text.isEmpty ? nil : ChatDelta(role: .model, content: text)
        }

        public var jsonContent: String? { message?.content.text }

        public static var empty: GenerateContentResponse { GenerateContentResponse(candidates: []) }

        public init(responseId: String? = nil, modelVersion: String? = nil, candidates: [Candidate], usageMetadata: UsageMetadata? = nil, promptFeedback: PromptFeedback? = nil, error: NativeError? = nil) {
            self.responseId = responseId
            self.modelVersion = modelVersion
            self.candidates = candidates
            self.usageMetadata = usageMetadata
            self.promptFeedback = promptFeedback
            self.error = error
        }

        /// Finish reasons that mean the answer was withheld or unusable.
        public static let failureFinishReasons: Set<String> = ["SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII", "IMAGE_SAFETY", "MALFORMED_FUNCTION_CALL"]

        /// Fails on an in-stream error, a blocked prompt, or a candidate that
        /// stopped for safety, recitation, or a malformed function call.
        public func validateStreamChunk() throws {
            if let error { throw LangToolsError.apiError(error) }
            if let reason = promptFeedback?.blockReason {
                throw LangToolsError.apiError(NativeError(message: "The prompt was blocked (\(reason))", status: reason))
            }
            if let candidate = candidates.first, let reason = candidate.finishReason, Self.failureFinishReasons.contains(reason) {
                throw LangToolsError.apiError(NativeError(message: candidate.finishMessage ?? "The response stopped (\(reason))", status: reason))
            }
        }

        /// A stream is complete once a candidate reports its finish reason.
        public func validateStreamCompletion() throws {
            guard finishReason != nil else { throw LangToolsError.incompleteStream }
        }

        /// Appends a chunk: text continues the previous text part, other parts
        /// (function calls, media) are added whole; metadata comes from the
        /// latest chunk that has it.
        public func combining(with next: GenerateContentResponse) -> GenerateContentResponse {
            var combined = GenerateContentResponse(
                responseId: next.responseId ?? responseId,
                modelVersion: next.modelVersion ?? modelVersion,
                candidates: candidates,
                usageMetadata: next.usageMetadata ?? usageMetadata,
                promptFeedback: next.promptFeedback ?? promptFeedback,
                error: next.error ?? error
            )
            guard let incoming = next.candidates.first else { return combined }
            var candidate = combined.candidates.first ?? Candidate(content: Message(role: .model, parts: []))
            var parts = candidate.content?.parts ?? []
            for part in incoming.content?.parts ?? [] {
                if let text = part.text, part.functionCall == nil, let last = parts.indices.last,
                   let previous = parts[last].text, parts[last].functionCall == nil, parts[last].thought == part.thought {
                    parts[last].text = previous + text
                    if let signature = part.thoughtSignature { parts[last].thoughtSignature = signature }
                } else {
                    parts.append(part)
                }
            }
            candidate.content = Message(role: .model, parts: parts)
            candidate.finishReason = incoming.finishReason ?? candidate.finishReason
            candidate.finishMessage = incoming.finishMessage ?? candidate.finishMessage
            candidate.groundingMetadata = incoming.groundingMetadata ?? candidate.groundingMetadata
            candidate.safetyRatings = incoming.safetyRatings ?? candidate.safetyRatings
            candidate.citationMetadata = incoming.citationMetadata ?? candidate.citationMetadata
            combined.candidates = [candidate]
            return combined
        }

        public struct Candidate: Codable {
            public var content: Message?
            public var finishReason: String?
            public var finishMessage: String?
            /// Search queries, sources, and the answer spans they support.
            public var groundingMetadata: JSON?
            public var safetyRatings: [JSON]?
            public var citationMetadata: JSON?

            public init(content: Message?, finishReason: String? = nil, finishMessage: String? = nil, groundingMetadata: JSON? = nil, safetyRatings: [JSON]? = nil, citationMetadata: JSON? = nil) {
                self.content = content
                self.finishReason = finishReason
                self.finishMessage = finishMessage
                self.groundingMetadata = groundingMetadata
                self.safetyRatings = safetyRatings
                self.citationMetadata = citationMetadata
            }

            private enum CodingKeys: String, CodingKey { case content, finishReason, finishMessage, groundingMetadata, safetyRatings, citationMetadata }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                // A candidate stopped before producing output has `content: {}`.
                content = (try? container.decodeIfPresent(Message.self, forKey: .content)) ?? nil
                finishReason = try container.decodeIfPresent(String.self, forKey: .finishReason)
                finishMessage = try container.decodeIfPresent(String.self, forKey: .finishMessage)
                groundingMetadata = try container.decodeIfPresent(JSON.self, forKey: .groundingMetadata)
                safetyRatings = try container.decodeIfPresent([JSON].self, forKey: .safetyRatings)
                citationMetadata = try container.decodeIfPresent(JSON.self, forKey: .citationMetadata)
            }
        }

        public struct UsageMetadata: Codable {
            public let promptTokenCount: Int?
            public let candidatesTokenCount: Int?
            public let thoughtsTokenCount: Int?
            public let cachedContentTokenCount: Int?
            public let totalTokenCount: Int?
        }

        public struct PromptFeedback: Codable {
            public let blockReason: String?
            public let safetyRatings: [JSON]?
        }

        private enum CodingKeys: String, CodingKey { case responseId, modelVersion, candidates, usageMetadata, promptFeedback, error }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            responseId = try container.decodeIfPresent(String.self, forKey: .responseId)
            modelVersion = try container.decodeIfPresent(String.self, forKey: .modelVersion)
            candidates = try container.decodeIfPresent([Candidate].self, forKey: .candidates) ?? []
            usageMetadata = try container.decodeIfPresent(UsageMetadata.self, forKey: .usageMetadata)
            promptFeedback = try container.decodeIfPresent(PromptFeedback.self, forKey: .promptFeedback)
            error = try? container.decodeIfPresent(NativeError.self, forKey: .error)
        }
    }

    /// An error from the native API: `{"code": 400, "message": ..., "status": "INVALID_ARGUMENT"}`.
    public struct NativeError: Error, Codable, LocalizedError, Equatable {
        public let code: Int?
        public let message: String
        public let status: String?

        public init(code: Int? = nil, message: String, status: String? = nil) {
            self.code = code
            self.message = message
            self.status = status
        }

        public var errorDescription: String? { message }
    }

    public struct ChatDelta: Codable, LangToolsMessageDelta {
        public typealias Role = Gemini.Role
        public let role: Role?
        public let content: String?
    }

    /// A conversation turn in Gemini's `{role, parts}` shape. Parts keep
    /// thought signatures, which Gemini 3 requires when a function call is
    /// replayed.
    public struct Message: Codable, LangToolsMessage, LangToolsToolMessage {
        public typealias Content = LangToolsTextContent
        public typealias ToolSelection = ToolCall
        public typealias ToolResult = ToolCallResult

        public let role: Role
        public var parts: [Part]

        /// The answer text, without thought summaries.
        public var content: LangToolsTextContent {
            LangToolsTextContent(text: parts.filter { $0.thought != true }.compactMap(\.text).joined())
        }

        public var tool_calls: [ToolCall] {
            parts.enumerated().compactMap { index, part in
                part.functionCall.map { ToolCall($0, thoughtSignature: part.thoughtSignature, index: index) }
            }
        }

        public var tool_selection: [ToolCall]? {
            let calls = tool_calls
            return calls.isEmpty ? nil : calls
        }

        public init(role: Role, parts: [Part]) {
            self.role = role
            self.parts = parts
        }

        public init(role: Role, content: LangToolsTextContent) {
            self.init(role: role, parts: [Part(text: content.text)])
        }

        public init(role: Role, content: String) {
            self.init(role: role, parts: [Part(text: content)])
        }

        public init(tool_selection: [ToolCall]) {
            self.init(role: .model, parts: tool_selection.map(\.part))
        }

        /// One turn holding every function response, as Gemini expects for
        /// parallel calls.
        public static func messages(for tool_results: [ToolCallResult]) -> [Message] {
            guard !tool_results.isEmpty else { return [] }
            return [Message(role: .tool, parts: tool_results.map { result in
                let key = result.is_error ? "error" : "output"
                return Part(functionResponse: FunctionResponse(id: result.tool_selection_id, name: nil, response: .object([key: .string(result.result)])))
            })]
        }

        private enum CodingKeys: String, CodingKey { case role, parts }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let parts = try container.decodeIfPresent([Part].self, forKey: .parts) ?? []
            let wireRole = try container.decodeIfPresent(String.self, forKey: .role) ?? "model"
            let role: Role
            switch wireRole {
            case "model": role = .model
            case "system": role = .system
            case "tool": role = .tool
            default: role = !parts.isEmpty && parts.allSatisfy { $0.functionResponse != nil } ? .tool : .user
            }
            self.init(role: role, parts: parts)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(role.wireValue, forKey: .role)
            try container.encode(parts, forKey: .parts)
        }
    }

    /// A `contents` entry as sent: role and parts.
    struct Content: Encodable {
        let role: String?
        let parts: [Part]
    }

    /// One part of a turn. Exactly one of the content fields is set.
    public struct Part: Codable {
        /// Google's documented placeholder for replaying a Gemini 3 function
        /// call whose signature was not kept.
        public static let skipThoughtSignatureValidator = "skip_thought_signature_validator"

        public var text: String?
        /// True for a thought summary rather than answer text.
        public var thought: Bool?
        public var thoughtSignature: String?
        public var inlineData: Blob?
        public var fileData: FileData?
        public var functionCall: FunctionCall?
        public var functionResponse: FunctionResponse?
        /// Code the model ran with the code-execution tool, and its result.
        public var executableCode: JSON?
        public var codeExecutionResult: JSON?

        public init(text: String? = nil, thought: Bool? = nil, thoughtSignature: String? = nil, inlineData: Blob? = nil, fileData: FileData? = nil, functionCall: FunctionCall? = nil, functionResponse: FunctionResponse? = nil) {
            self.text = text
            self.thought = thought
            self.thoughtSignature = thoughtSignature
            self.inlineData = inlineData
            self.fileData = fileData
            self.functionCall = functionCall
            self.functionResponse = functionResponse
        }

        /// Base64-encoded media, such as an image.
        public struct Blob: Codable {
            public let mimeType: String
            public let data: String

            public init(mimeType: String, data: String) {
                self.mimeType = mimeType
                self.data = data
            }
        }

        public struct FileData: Codable {
            public let mimeType: String
            public let fileUri: String

            public init(mimeType: String, fileUri: String) {
                self.mimeType = mimeType
                self.fileUri = fileUri
            }
        }
    }

    public struct FunctionCall: Codable {
        public var id: String?
        public var name: String
        public var args: JSON?

        public init(id: String?, name: String, args: JSON?) {
            self.id = id
            self.name = name
            self.args = args
        }
    }

    public struct FunctionResponse: Codable {
        public var id: String?
        /// Filled from the matching call when the request is encoded.
        public var name: String?
        public var response: JSON

        public init(id: String?, name: String?, response: JSON) {
            self.id = id
            self.name = name
            self.response = response
        }
    }

    /// A function call, with the thought signature that must accompany it
    /// when replayed. Calls without an ID get one from their name and
    /// position, which Gemini accepts on the matching response.
    public struct ToolCall: Codable, LangToolsToolSelection {
        public let id: String?
        public let name: String?
        public let args: JSON?
        public let thoughtSignature: String?

        public var arguments: String {
            guard let args, args != .null else { return "" }
            return args.jsonString(formatting: []) ?? ""
        }

        public init(id: String, name: String, args: JSON?, thoughtSignature: String? = nil) {
            self.id = id
            self.name = name
            self.args = args
            self.thoughtSignature = thoughtSignature
        }

        init(_ call: FunctionCall, thoughtSignature: String?, index: Int) {
            self.init(id: call.id ?? "call_\(index)_\(call.name)", name: call.name, args: call.args, thoughtSignature: thoughtSignature)
        }

        var part: Part {
            Part(thoughtSignature: thoughtSignature, functionCall: FunctionCall(id: id, name: name ?? "", args: args ?? .object([:])))
        }
    }

    public struct ToolCallResult: Codable, LangToolsToolSelectionResult {
        public let tool_selection_id: String
        public let result: String
        public var is_error: Bool

        public init(tool_selection_id: String, result: String, is_error: Bool) {
            self.tool_selection_id = tool_selection_id
            self.result = result
            self.is_error = is_error
        }
    }

    public enum Role: String, Codable, LangToolsRole {
        case system, user, model, tool

        public init(_ role: any LangToolsRole) {
            if role.isUser { self = .user }
            else if role.isSystem { self = .system }
            else if role.isTool { self = .tool }
            else { self = .model }
        }

        /// Gemini's wire role: function responses are sent as `user` turns.
        var wireValue: String {
            switch self {
            case .model: return "model"
            case .system: return "system"
            case .user, .tool: return "user"
            }
        }

        public var isAssistant: Bool { self == .model }
        public var isUser: Bool { self == .user }
        public var isSystem: Bool { self == .system }
        public var isTool: Bool { self == .tool }
    }
}
