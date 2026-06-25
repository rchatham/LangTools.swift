//
//  OpenAI+Response.swift
//  OpenAI
//
//  Responses API response object and streaming events.
//

import Foundation
import LangTools


public extension OpenAI {
    /// The object returned by the Responses API (`POST /v1/responses`).
    ///
    /// The model's output is delivered as an array of ``OutputItem`` values (assistant
    /// messages, function calls, reasoning, etc.) rather than chat-style `choices`. This
    /// type bridges that shape onto the LangTools chat/tool-calling/streaming protocols so
    /// the shared engine (tool-call loop, streaming accumulation, structured output) works.
    struct ResponseResponse: Codable, LangToolsStreamableChatResponse, LangToolsToolCallingResponse, LangToolsStructuredOutputResponse {
        public typealias Message = OpenAI.Item
        public typealias Delta = OpenAI.Message.Delta
        public typealias ToolSelection = OpenAI.Message.ToolCall

        public let id: String?
        public let object: String?
        public let created_at: Int?
        public let model: String?
        /// `completed`, `in_progress`, `failed`, `incomplete`, etc.
        public let status: String?
        public var output: [OutputItem]
        public let usage: Usage?
        public let error: ResponseError?
        public let incomplete_details: IncompleteDetails?

        /// The per-chunk delta, populated only while streaming. Excluded from Codable.
        public var streamingDelta: Delta?

        public init(id: String? = nil, object: String? = nil, created_at: Int? = nil, model: String? = nil, status: String? = nil, output: [OutputItem] = [], usage: Usage? = nil, error: ResponseError? = nil, incomplete_details: IncompleteDetails? = nil, delta: Delta? = nil) {
            self.id = id
            self.object = object
            self.created_at = created_at
            self.model = model
            self.status = status
            self.output = output
            self.usage = usage
            self.error = error
            self.incomplete_details = incomplete_details
            self.streamingDelta = delta
        }

        // MARK: - Codable

        // A custom implementation (rather than synthesised) is required so that `output`
        // tolerates being absent: terminal events such as `response.failed` / `response.incomplete`
        // can omit it, and a synthesised decoder would throw `keyNotFound` (default property
        // values are not applied by synthesised `Decodable`), masking the real error/status.
        enum CodingKeys: String, CodingKey {
            case id, object, created_at, model, status, output, usage, error, incomplete_details
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id)
            object = try container.decodeIfPresent(String.self, forKey: .object)
            created_at = try container.decodeIfPresent(Int.self, forKey: .created_at)
            model = try container.decodeIfPresent(String.self, forKey: .model)
            status = try container.decodeIfPresent(String.self, forKey: .status)
            output = try container.decodeIfPresent([OutputItem].self, forKey: .output) ?? []
            usage = try container.decodeIfPresent(Usage.self, forKey: .usage)
            error = try container.decodeIfPresent(ResponseError.self, forKey: .error)
            incomplete_details = try container.decodeIfPresent(IncompleteDetails.self, forKey: .incomplete_details)
            streamingDelta = nil
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(id, forKey: .id)
            try container.encodeIfPresent(object, forKey: .object)
            try container.encodeIfPresent(created_at, forKey: .created_at)
            try container.encodeIfPresent(model, forKey: .model)
            try container.encodeIfPresent(status, forKey: .status)
            try container.encode(output, forKey: .output)
            try container.encodeIfPresent(usage, forKey: .usage)
            try container.encodeIfPresent(error, forKey: .error)
            try container.encodeIfPresent(incomplete_details, forKey: .incomplete_details)
        }


        // MARK: - LangToolsStreamableResponse

        public var delta: Delta? { streamingDelta }

        public static var empty: ResponseResponse { ResponseResponse() }

        public func combining(with next: ResponseResponse) -> ResponseResponse {
            ResponseResponse(
                id: next.id ?? id,
                object: next.object ?? object,
                created_at: next.created_at ?? created_at,
                model: next.model ?? model,
                status: next.status ?? status,
                output: ResponseResponse.merge(output, with: next.output),
                usage: next.usage ?? usage,
                error: next.error ?? error,
                incomplete_details: next.incomplete_details ?? incomplete_details,
                delta: next.streamingDelta
            )
        }

        static func merge(_ items: [OutputItem], with next: [OutputItem]) -> [OutputItem] {
            var result = items
            for item in next {
                if let id = item.id, let index = result.firstIndex(where: { $0.id == id }) {
                    result[index] = result[index].combining(with: item)
                } else {
                    result.append(item)
                }
            }
            return result
        }

        // MARK: - LangToolsChatResponse

        /// The assistant message synthesised from the output items (concatenated text and
        /// any function calls), mirroring the role `ChatCompletionResponse.choice.message` plays.
        public var message: Item? {
            var text = ""
            var calls: [ToolSelection] = []
            for item in output {
                switch item.type {
                case "message":
                    text += item.outputText
                case "function_call":
                    calls.append(ToolSelection(
                        index: calls.count,
                        id: item.call_id ?? item.id ?? "",
                        type: .function,
                        function: .init(name: item.name ?? "", arguments: item.arguments ?? "")))
                default:
                    break
                }
            }
            if text.isEmpty && calls.isEmpty { return nil }
            let content: Content = text.isEmpty ? .null : .string(text)
            return Item(role: .assistant, content: content, tool_calls: calls.isEmpty ? nil : calls)
        }

        typealias Content = OpenAI.Message.Content

        // MARK: - LangToolsStructuredOutputResponse

        /// The full assistant text output, convenient for reading the final result.
        public var outputText: String {
            output.filter { $0.type == "message" }.map { $0.outputText }.joined()
        }

        public var jsonContent: String? {
            let text = outputText
            return text.isEmpty ? nil : text
        }

        // MARK: - Nested types

        /// An item in the model's `output` array.
        public struct OutputItem: Codable {
            /// `message`, `function_call`, `reasoning`, `web_search_call`, etc.
            public var type: String
            public var id: String?
            public var status: String?
            // message
            public var role: String?
            public var content: [OutputContent]?
            // function_call
            public var call_id: String?
            public var name: String?
            public var arguments: String?

            public init(type: String, id: String? = nil, status: String? = nil, role: String? = nil, content: [OutputContent]? = nil, call_id: String? = nil, name: String? = nil, arguments: String? = nil) {
                self.type = type
                self.id = id
                self.status = status
                self.role = role
                self.content = content
                self.call_id = call_id
                self.name = name
                self.arguments = arguments
            }

            /// Concatenated `output_text` content of this (message) item.
            public var outputText: String {
                content?.filter { $0.type == "output_text" }.compactMap { $0.text }.joined() ?? ""
            }

            func combining(with next: OutputItem) -> OutputItem {
                let mergedArguments: String?
                if arguments == nil && next.arguments == nil { mergedArguments = nil }
                else { mergedArguments = (arguments ?? "") + (next.arguments ?? "") }
                let mergedContent: [OutputContent]?
                switch (content, next.content) {
                case (let a?, let b?): mergedContent = a + b
                case (let a?, nil): mergedContent = a
                case (nil, let b?): mergedContent = b
                case (nil, nil): mergedContent = nil
                }
                return OutputItem(
                    type: type,
                    id: id ?? next.id,
                    status: next.status ?? status,
                    role: role ?? next.role,
                    content: mergedContent,
                    call_id: call_id ?? next.call_id,
                    name: name ?? next.name,
                    arguments: mergedArguments)
            }
        }

        public struct OutputContent: Codable {
            /// `output_text` or `refusal`.
            public var type: String
            public var text: String?
            public var refusal: String?

            public init(type: String, text: String? = nil, refusal: String? = nil) {
                self.type = type
                self.text = text
                self.refusal = refusal
            }
        }

        public struct Usage: Codable {
            public let input_tokens: Int
            public let output_tokens: Int
            public let total_tokens: Int
            public let input_tokens_details: InputTokensDetails?
            public let output_tokens_details: OutputTokensDetails?

            public init(input_tokens: Int, output_tokens: Int, total_tokens: Int, input_tokens_details: InputTokensDetails? = nil, output_tokens_details: OutputTokensDetails? = nil) {
                self.input_tokens = input_tokens
                self.output_tokens = output_tokens
                self.total_tokens = total_tokens
                self.input_tokens_details = input_tokens_details
                self.output_tokens_details = output_tokens_details
            }

            public struct InputTokensDetails: Codable {
                public let cached_tokens: Int?
            }

            public struct OutputTokensDetails: Codable {
                public let reasoning_tokens: Int?
            }
        }

        public struct ResponseError: Codable {
            public let code: String?
            public let message: String?
        }

        public struct IncompleteDetails: Codable {
            public let reason: String?
        }
    }
}

// MARK: - Streaming events

extension OpenAI {
    /// A single semantic streaming event from the Responses API SSE stream.
    ///
    /// Events are mapped into partial ``ResponseResponse`` values by ``partialResponse`` so
    /// they can flow through the shared streaming engine (which accumulates them via
    /// ``ResponseResponse/combining(with:)``). Events that carry no incremental payload
    /// return `nil` and are skipped.
    struct ResponseStreamEvent: Decodable {
        let type: String
        let delta: String?
        let item_id: String?
        let item: ResponseResponse.OutputItem?
        let response: ResponseResponse?

        enum CodingKeys: String, CodingKey { case type, delta, item_id, item, response }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decode(String.self, forKey: .type)
            // `delta` is a string for text/argument deltas; ignore non-string deltas.
            delta = try? container.decode(String.self, forKey: .delta)
            item_id = try? container.decode(String.self, forKey: .item_id)
            item = try? container.decode(ResponseResponse.OutputItem.self, forKey: .item)
            // decodeIfPresent (not try?) so a malformed terminal `response` payload surfaces
            // as a stream error rather than silently dropping status/usage/id.
            response = try container.decodeIfPresent(ResponseResponse.self, forKey: .response)
        }

        /// Maps this event onto a partial response that can be combined into the running result.
        var partialResponse: ResponseResponse? {
            switch type {
            case "response.output_text.delta":
                guard let delta else { return nil }
                return ResponseResponse(
                    output: [.init(type: "message", id: item_id, role: "assistant", content: [.init(type: "output_text", text: delta)])],
                    delta: .init(role: .assistant, content: delta, tool_calls: nil, audio: nil, refusal: nil))
            case "response.output_item.added":
                // Surfaces the function-call skeleton (id/call_id/name). Arguments arrive
                // via `response.function_call_arguments.delta`; `output_item.done` is skipped
                // to avoid duplicating the accumulated arguments.
                guard let item, item.type == "function_call" else { return nil }
                return ResponseResponse(output: [item])
            case "response.function_call_arguments.delta":
                guard let delta else { return nil }
                return ResponseResponse(output: [.init(type: "function_call", id: item_id, arguments: delta)])
            case "response.completed", "response.incomplete", "response.failed":
                guard let response else { return nil }
                // The output has already been accumulated from deltas; surface only the
                // terminal metadata (status, usage, id) to avoid duplicating content.
                return ResponseResponse(
                    id: response.id,
                    object: response.object,
                    created_at: response.created_at,
                    model: response.model,
                    status: response.status,
                    output: [],
                    usage: response.usage,
                    error: response.error,
                    incomplete_details: response.incomplete_details)
            default:
                return nil
            }
        }
    }
}
