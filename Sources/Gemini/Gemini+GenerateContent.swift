//
//  Gemini+GenerateContent.swift
//  LangTools
//
//  Gemini's native API (`models/{model}:generateContent`), served beside the
//  OpenAI-compatible endpoint. It adds Google Search grounding, thinking
//  configuration and thought signatures, safety settings, and media parts.
//

import Foundation
import LangTools
import OpenAI

extension Gemini {
    /// A `generateContent` request. The model travels in the URL, so `modelID`
    /// can name any model; `model` is the matching case, or `.gemini3Flash`.
    public struct GenerateContentRequest: Codable, LangToolsChatRequest, LangToolsStreamableRequest, LangToolsToolCallingRequest, LangToolsStructuredOutputRequest {
        public typealias Response = GenerateContentResponse
        public typealias LangTool = Gemini
        public static var endpoint: String { "generateContent" }

        public let model: GeminiModel
        public let modelID: String
        public var messages: [Message]
        /// Selects `streamGenerateContent`; not part of the body.
        public var stream: Bool?
        public var tools: [OpenAI.Tool]?
        /// Grounds answers in Google Search; sources arrive in `groundingMetadata`.
        public var googleSearch = false
        public var functionCallingMode: FunctionCallingMode?
        public var generationConfig: GenerationConfig?
        public var safetySettings: [SafetySetting]?
        /// A cached-content resource name, such as `cachedContents/abc`.
        public var cachedContent: String?
        @CodableIgnored public var toolEventHandler: ((LangToolsToolEvent) -> Void)?

        public var responseSchema: JSONSchema? {
            get { generationConfig?.responseJsonSchema }
            set {
                if generationConfig == nil { generationConfig = GenerationConfig() }
                generationConfig?.responseJsonSchema = newValue
                generationConfig?.responseMimeType = newValue == nil ? nil : "application/json"
            }
        }

        public init(model: GeminiModel, messages: [any LangToolsMessage]) {
            self.init(modelID: model.rawValue, messages: messages.map { Message($0) })
        }

        public init(model: GeminiModel, messages: [Message], stream: Bool? = nil, tools: [OpenAI.Tool]? = nil, googleSearch: Bool = false, functionCallingMode: FunctionCallingMode? = nil, generationConfig: GenerationConfig? = nil, safetySettings: [SafetySetting]? = nil, cachedContent: String? = nil, toolEventHandler: ((LangToolsToolEvent) -> Void)? = nil) {
            self.init(modelID: model.rawValue, messages: messages, stream: stream, tools: tools, googleSearch: googleSearch, functionCallingMode: functionCallingMode, generationConfig: generationConfig, safetySettings: safetySettings, cachedContent: cachedContent, toolEventHandler: toolEventHandler)
        }

        public init(modelID: String, messages: [Message], stream: Bool? = nil, tools: [OpenAI.Tool]? = nil, googleSearch: Bool = false, functionCallingMode: FunctionCallingMode? = nil, generationConfig: GenerationConfig? = nil, safetySettings: [SafetySetting]? = nil, cachedContent: String? = nil, toolEventHandler: ((LangToolsToolEvent) -> Void)? = nil) {
            (model, self.modelID, self.messages, self.stream, self.tools, self.googleSearch) = (GeminiModel(rawValue: modelID) ?? .gemini3Flash, modelID, messages, stream, tools, googleSearch)
            (self.functionCallingMode, self.generationConfig, self.safetySettings, self.cachedContent, self.toolEventHandler) = (functionCallingMode, generationConfig, safetySettings, cachedContent, toolEventHandler)
        }

        /// `models/<id>`, or the ID itself when it names a resource such as `tunedModels/<id>`.
        public var modelPath: String { modelID.contains("/") ? modelID : "models/\(modelID)" }

        public enum FunctionCallingMode: String, Codable {
            case auto = "AUTO", any = "ANY", none = "NONE", validated = "VALIDATED"

            /// The mode matching an OpenAI tool choice.
            public init(_ choice: OpenAI.ChatCompletionRequest.ToolChoice) {
                switch choice {
                case .none: self = .none
                case .auto: self = .auto
                case .required, .tool: self = .any
                }
            }
        }

        public struct GenerationConfig: Codable {
            public var temperature: Double?, topP: Double?, topK: Int?, maxOutputTokens: Int?, stopSequences: [String]?, seed: Int?
            public var presencePenalty: Double?, frequencyPenalty: Double?, responseMimeType: String?, responseJsonSchema: JSONSchema?
            /// Such as `["thinkingLevel": "low"]` (Gemini 3), `["thinkingBudget": 1024]` (2.5),
            /// and `["includeThoughts": true]` for thought summaries.
            public var thinkingConfig: [String: JSON]?

            public init(temperature: Double? = nil, topP: Double? = nil, topK: Int? = nil, maxOutputTokens: Int? = nil, stopSequences: [String]? = nil, seed: Int? = nil, presencePenalty: Double? = nil, frequencyPenalty: Double? = nil, thinkingConfig: [String: JSON]? = nil) {
                (self.temperature, self.topP, self.topK, self.maxOutputTokens, self.stopSequences) = (temperature, topP, topK, maxOutputTokens, stopSequences)
                (self.seed, self.presencePenalty, self.frequencyPenalty, self.thinkingConfig) = (seed, presencePenalty, frequencyPenalty, thinkingConfig)
            }
        }

        public struct SafetySetting: Codable {
            /// Such as `HARM_CATEGORY_HARASSMENT` and `BLOCK_ONLY_HIGH`.
            public let category: String, threshold: String
            public init(category: String, threshold: String) { (self.category, self.threshold) = (category, threshold) }
        }

        private enum CodingKeys: String, CodingKey { case modelID, contents, systemInstruction, tools, toolConfig, generationConfig, safetySettings, cachedContent }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            let system = messages.filter { $0.role == .system }.map(\.content.text).joined(separator: "\n\n")
            if !system.isEmpty { try container.encode(Message(role: .system, content: system), forKey: .systemInstruction) }
            try container.encode(wireContents, forKey: .contents)
            var toolEntries: [JSON] = try tools.map { [.object(["functionDeclarations": .array(try $0.map(Self.functionDeclaration))])] } ?? []
            if googleSearch { toolEntries.append(.object(["googleSearch": .object([:])])) }
            if !toolEntries.isEmpty { try container.encode(toolEntries, forKey: .tools) }
            if let functionCallingMode {
                try container.encode(JSON.object(["functionCallingConfig": .object(["mode": .string(functionCallingMode.rawValue)])]), forKey: .toolConfig)
            }
            if let generationConfig, case .object(var config) = try Self.json(generationConfig) {
                // `responseJsonSchema` does not accept `const`; a one-value `enum` says the same.
                config["responseJsonSchema"] = config["responseJsonSchema"].map(Self.replacingConst)
                try container.encode(config, forKey: .generationConfig)
            }
            try container.encodeIfPresent(safetySettings, forKey: .safetySettings)
            try container.encodeIfPresent(cachedContent, forKey: .cachedContent)
        }

        /// Recovers the configuration of an encoded request, not its conversation.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(modelID: try container.decodeIfPresent(String.self, forKey: .modelID) ?? GeminiModel.gemini3Flash.rawValue, messages: [], generationConfig: try container.decodeIfPresent(GenerationConfig.self, forKey: .generationConfig), safetySettings: try container.decodeIfPresent([SafetySetting].self, forKey: .safetySettings), cachedContent: try container.decodeIfPresent(String.self, forKey: .cachedContent))
        }

        /// The conversation as `contents`: system messages move to `systemInstruction`,
        /// consecutive function responses share a turn and carry their call's name, and
        /// Gemini 3 calls replayed without a thought signature get Google's placeholder.
        var wireContents: [Message] {
            var names: [String: String] = [:]
            for call in messages.flatMap(\.tool_calls) { names[call.id ?? ""] = call.name }
            var contents: [Message] = []
            for message in messages where message.role != .system {
                var parts = message.parts.map { part in
                    var part = part
                    let id = part.functionResponse?.id ?? ""
                    if part.functionResponse?.name == nil { part.functionResponse?.name = names[id] }
                    return part
                }
                if modelID.hasPrefix("gemini-3"), message.role == .model, !parts.contains(where: { $0.functionCall != nil && $0.thoughtSignature != nil }),
                   let first = parts.firstIndex(where: { $0.functionCall != nil }) {
                    parts[first].thoughtSignature = Part.skipThoughtSignatureValidator
                }
                if message.role == .tool, contents.last?.role == .tool { contents[contents.count - 1].parts += parts }
                else { contents.append(Message(role: message.role, parts: parts)) }
            }
            return contents
        }

        private static func functionDeclaration(_ tool: OpenAI.Tool) throws -> JSON {
            .object(["name": .string(tool.name), "description": tool.description.map(JSON.string) ?? .null, "parametersJsonSchema": try json(tool.tool_schema)].filter { $0.value != .null })
        }

        private static func json<T: Encodable>(_ value: T) throws -> JSON { try JSONDecoder().decode(JSON.self, from: JSONEncoder().encode(value)) }

        static func replacingConst(_ schema: JSON) -> JSON {
            switch schema {
            case .object(var object):
                if let value = object.removeValue(forKey: "const") { object["enum"] = .array([value]) }
                return .object(object.mapValues(replacingConst))
            case .array(let items): return .array(items.map(replacingConst))
            default: return schema
            }
        }
    }

    public struct GenerateContentResponse: Codable, LangToolsStreamableChatResponse, LangToolsToolCallingResponse, LangToolsStructuredOutputResponse {
        public typealias Delta = ChatDelta
        public typealias ToolSelection = ToolCall

        public var responseId: String?, modelVersion: String?
        public var candidates: [Candidate]?
        public var usageMetadata: UsageMetadata?
        public var promptFeedback: PromptFeedback?
        /// An error sent in place of a chunk after the stream started.
        public var error: NativeError?

        public var message: Message? { candidates?.first?.content }
        public var finishReason: String? { candidates?.first?.finishReason }
        /// The answer text in this chunk, without thought summaries.
        public var delta: ChatDelta? { message.map(\.content.text).flatMap { $0.isEmpty ? nil : ChatDelta(role: .model, content: $0) } }
        public var jsonContent: String? { message?.content.text }
        public static var empty: GenerateContentResponse { GenerateContentResponse() }

        /// Finish reasons that mean the answer was withheld or unusable.
        public static let failureFinishReasons: Set<String> = ["SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII", "IMAGE_SAFETY", "MALFORMED_FUNCTION_CALL"]

        /// Fails on an in-stream error, a blocked prompt, or a failure finish reason.
        public func validateStreamChunk() throws {
            if let error { throw LangToolsError.apiError(error) }
            if let reason = promptFeedback?.blockReason { throw LangToolsError.apiError(NativeError(message: "The prompt was blocked (\(reason))", status: reason)) }
            if let reason = finishReason, Self.failureFinishReasons.contains(reason) {
                throw LangToolsError.apiError(NativeError(message: candidates?.first?.finishMessage ?? "The response stopped (\(reason))", status: reason))
            }
        }

        /// A stream is complete once a candidate reports its finish reason.
        public func validateStreamCompletion() throws {
            guard finishReason != nil else { throw LangToolsError.incompleteStream }
        }

        /// Text continues the previous text part; other parts are added whole.
        public func combining(with next: GenerateContentResponse) -> GenerateContentResponse {
            var combined = GenerateContentResponse(responseId: next.responseId ?? responseId, modelVersion: next.modelVersion ?? modelVersion, candidates: candidates, usageMetadata: next.usageMetadata ?? usageMetadata, promptFeedback: next.promptFeedback ?? promptFeedback, error: next.error ?? error)
            guard let incoming = next.candidates?.first else { return combined }
            var candidate = candidates?.first ?? Candidate()
            var parts = candidate.content?.parts ?? []
            for part in incoming.content?.parts ?? [] {
                if let text = part.text, let last = parts.indices.last, let previous = parts[last].text, parts[last].thought == part.thought {
                    parts[last].text = previous + text
                    parts[last].thoughtSignature = part.thoughtSignature ?? parts[last].thoughtSignature
                } else {
                    parts.append(part)
                }
            }
            candidate.content = Message(role: .model, parts: parts)
            candidate.finishReason = incoming.finishReason ?? candidate.finishReason
            candidate.finishMessage = incoming.finishMessage ?? candidate.finishMessage
            candidate.groundingMetadata = incoming.groundingMetadata ?? candidate.groundingMetadata
            candidate.safetyRatings = incoming.safetyRatings ?? candidate.safetyRatings
            combined.candidates = [candidate]
            return combined
        }

        public struct Candidate: Codable {
            public var content: Message?
            public var finishReason: String?, finishMessage: String?
            /// Search queries, sources, and the answer spans they support.
            public var groundingMetadata: JSON?
            public var safetyRatings: [JSON]?
        }

        public struct UsageMetadata: Codable {
            public let promptTokenCount: Int?, candidatesTokenCount: Int?, thoughtsTokenCount: Int?, cachedContentTokenCount: Int?, totalTokenCount: Int?
        }

        public struct PromptFeedback: Codable {
            public let blockReason: String?
            public let safetyRatings: [JSON]?
        }
    }

    /// A native API error: `{"code": 400, "message": ..., "status": "INVALID_ARGUMENT"}`.
    public struct NativeError: Error, Codable, LocalizedError, Equatable {
        public var code: Int?
        public var message: String
        public var status: String?
        public var errorDescription: String? { message }
    }

    public struct ChatDelta: Codable, LangToolsMessageDelta {
        public let role: Role?
        public let content: String?
    }

    /// A turn in Gemini's `{role, parts}` shape. Parts keep thought signatures,
    /// which Gemini 3 requires when a function call is replayed.
    public struct Message: Codable, LangToolsMessage, LangToolsToolMessage {
        public let role: Role
        public var parts: [Part]

        /// The answer text, without thought summaries.
        public var content: LangToolsTextContent { LangToolsTextContent(text: parts.filter { $0.thought != true }.compactMap(\.text).joined()) }

        /// Function calls; calls without an ID get one from their name and position,
        /// which Gemini accepts on the matching response.
        public var tool_calls: [ToolCall] {
            parts.enumerated().compactMap { index, part in
                part.functionCall.map { ToolCall(id: $0.id ?? "call_\(index)_\($0.name)", name: $0.name, args: $0.args, thoughtSignature: part.thoughtSignature) }
            }
        }

        public var tool_selection: [ToolCall]? { tool_calls.isEmpty ? nil : tool_calls }

        public init(role: Role, parts: [Part]) { (self.role, self.parts) = (role, parts) }
        public init(role: Role, content: LangToolsTextContent) { self.init(role: role, content: content.text) }
        public init(role: Role, content: String) { self.init(role: role, parts: [Part(text: content)]) }
        public init(tool_selection: [ToolCall]) { self.init(role: .model, parts: tool_selection.map(\.part)) }

        /// Converts another provider's message, keeping its tool calls and results.
        public init(_ message: any LangToolsMessage) {
            if let native = message as? Self { self = native; return }
            let results = message.content.array?.compactMap(\.toolResultContentType) ?? []
            let calls: [any LangToolsToolSelection] = (message as? any LangToolsToolMessage)?.tool_selection ?? []
            var parts = results.map { Part(functionResponse: FunctionResponse(id: $0.tool_selection_id, response: .object([$0.is_error ? "error" : "output": .string($0.result)]))) }
            parts += calls.map { Part(functionCall: FunctionCall(id: $0.id, name: $0.name ?? "", args: try? JSON(string: $0.arguments.isEmpty ? "{}" : $0.arguments))) }
            if parts.isEmpty || !message.content.text.isEmpty && results.isEmpty { parts.insert(Part(text: message.content.text), at: 0) }
            self.init(role: results.isEmpty ? Role(message.role) : .tool, parts: parts)
        }

        /// One turn holding every function response, as Gemini expects for parallel calls.
        public static func messages(for tool_results: [ToolCallResult]) -> [Message] {
            tool_results.isEmpty ? [] : [Message(role: .tool, parts: tool_results.map {
                Part(functionResponse: FunctionResponse(id: $0.tool_selection_id, response: .object([$0.is_error ? "error" : "output": .string($0.result)])))
            })]
        }

        private enum CodingKeys: String, CodingKey { case role, parts }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let parts = try container.decodeIfPresent([Part].self, forKey: .parts) ?? []
            let role = try container.decodeIfPresent(Role.self, forKey: .role) ?? .model
            self.init(role: role == .user && !parts.isEmpty && parts.allSatisfy { $0.functionResponse != nil } ? .tool : role, parts: parts)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            // Function responses are sent as `user` turns; the system instruction has no role.
            if role != .system { try container.encode(role == .tool ? Role.user : role, forKey: .role) }
            try container.encode(parts, forKey: .parts)
        }
    }

    /// One part of a turn; one of the content fields is set.
    public struct Part: Codable {
        /// Google's placeholder for replaying a Gemini 3 call whose signature was not kept.
        public static let skipThoughtSignatureValidator = "skip_thought_signature_validator"

        public var text: String?
        /// True for a thought summary rather than answer text.
        public var thought: Bool?
        public var thoughtSignature: String?
        /// Base64 media: `["mimeType": "image/png", "data": ...]`.
        public var inlineData: [String: String]?
        /// Uploaded media: `["mimeType": ..., "fileUri": ...]`.
        public var fileData: [String: String]?
        public var functionCall: FunctionCall?
        public var functionResponse: FunctionResponse?
        /// Code run by the code-execution tool, and its result.
        public var executableCode: JSON?, codeExecutionResult: JSON?

        public init(text: String? = nil, thoughtSignature: String? = nil, inlineData: [String: String]? = nil, fileData: [String: String]? = nil, functionCall: FunctionCall? = nil, functionResponse: FunctionResponse? = nil) {
            (self.text, self.thoughtSignature, self.inlineData, self.fileData, self.functionCall, self.functionResponse) = (text, thoughtSignature, inlineData, fileData, functionCall, functionResponse)
        }
    }

    public struct FunctionCall: Codable {
        public var id: String?, name: String, args: JSON?
        public init(id: String?, name: String, args: JSON?) { (self.id, self.name, self.args) = (id, name, args) }
    }

    public struct FunctionResponse: Codable {
        /// `name` is filled from the matching call when the request is encoded.
        public var id: String?, name: String?, response: JSON
        public init(id: String?, name: String? = nil, response: JSON) { (self.id, self.name, self.response) = (id, name, response) }
    }

    /// A function call, with the thought signature that must accompany it when replayed.
    public struct ToolCall: Codable, LangToolsToolSelection {
        public let id: String?, name: String?, args: JSON?, thoughtSignature: String?
        public var arguments: String { args.flatMap { $0 == .null ? nil : $0.jsonString(formatting: []) } ?? "" }

        public init(id: String, name: String, args: JSON?, thoughtSignature: String? = nil) {
            (self.id, self.name, self.args, self.thoughtSignature) = (id, name, args, thoughtSignature)
        }

        var part: Part { Part(thoughtSignature: thoughtSignature, functionCall: FunctionCall(id: id, name: name ?? "", args: args ?? .object([:]))) }
    }

    public struct ToolCallResult: Codable, LangToolsToolSelectionResult {
        public let tool_selection_id: String, result: String
        public var is_error: Bool
        public init(tool_selection_id: String, result: String, is_error: Bool) { (self.tool_selection_id, self.result, self.is_error) = (tool_selection_id, result, is_error) }
    }

    public enum Role: String, Codable, LangToolsRole {
        case system, user, model, tool

        public init(_ role: any LangToolsRole) {
            self = role.isUser ? .user : role.isSystem ? .system : role.isTool ? .tool : .model
        }

        public var isAssistant: Bool { self == .model }
        public var isUser: Bool { self == .user }
        public var isSystem: Bool { self == .system }
        public var isTool: Bool { self == .tool }
    }
}
