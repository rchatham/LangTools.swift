//
//  OpenAI+RealtimeClientEvents.swift
//  OpenAI
//
//  Created by Reid Chatham on 1/16/26.
//

import Foundation
import LangTools

// MARK: - Client Events Enum

/// All client events that can be sent to the OpenAI Realtime API
public enum OpenAIRealtimeClientEvent: LangToolsRealtimeClientEvent, Encodable {
    case sessionUpdate(SessionUpdateEvent)
    case inputAudioBufferAppend(InputAudioBufferAppendEvent)
    case inputAudioBufferCommit(InputAudioBufferCommitEvent)
    case inputAudioBufferClear(InputAudioBufferClearEvent)
    case conversationItemCreate(ConversationItemCreateEvent)
    case conversationItemTruncate(ConversationItemTruncateEvent)
    case conversationItemDelete(ConversationItemDeleteEvent)
    case responseCreate(ResponseCreateEvent)
    case responseCancel(ResponseCancelEvent)

    public var eventId: String? {
        switch self {
        case .sessionUpdate(let e): return e.eventId
        case .inputAudioBufferAppend(let e): return e.eventId
        case .inputAudioBufferCommit(let e): return e.eventId
        case .inputAudioBufferClear(let e): return e.eventId
        case .conversationItemCreate(let e): return e.eventId
        case .conversationItemTruncate(let e): return e.eventId
        case .conversationItemDelete(let e): return e.eventId
        case .responseCreate(let e): return e.eventId
        case .responseCancel(let e): return e.eventId
        }
    }

    public var type: String {
        switch self {
        case .sessionUpdate: return "session.update"
        case .inputAudioBufferAppend: return "input_audio_buffer.append"
        case .inputAudioBufferCommit: return "input_audio_buffer.commit"
        case .inputAudioBufferClear: return "input_audio_buffer.clear"
        case .conversationItemCreate: return "conversation.item.create"
        case .conversationItemTruncate: return "conversation.item.truncate"
        case .conversationItemDelete: return "conversation.item.delete"
        case .responseCreate: return "response.create"
        case .responseCancel: return "response.cancel"
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .sessionUpdate(let e): try container.encode(e)
        case .inputAudioBufferAppend(let e): try container.encode(e)
        case .inputAudioBufferCommit(let e): try container.encode(e)
        case .inputAudioBufferClear(let e): try container.encode(e)
        case .conversationItemCreate(let e): try container.encode(e)
        case .conversationItemTruncate(let e): try container.encode(e)
        case .conversationItemDelete(let e): try container.encode(e)
        case .responseCreate(let e): try container.encode(e)
        case .responseCancel(let e): try container.encode(e)
        }
    }
}

// MARK: - Session Update Event

/// Update the session configuration
public struct SessionUpdateEvent: Codable, Sendable {
    public let type: String = "session.update"
    public var eventId: String?
    public var session: Session

    public init(eventId: String? = nil, session: Session) {
        self.eventId = eventId
        self.session = session
    }

    public struct Session: Codable, Sendable {
        public var modalities: [String]?
        public var instructions: String?
        public var voice: String?
        public var inputAudioFormat: String?
        public var outputAudioFormat: String?
        public var inputAudioTranscription: InputAudioTranscription?
        public var turnDetection: TurnDetection?
        public var tools: [Tool]?
        public var toolChoice: String?
        public var temperature: Double?
        public var maxResponseOutputTokens: MaxTokens?

        public init(
            modalities: [String]? = nil,
            instructions: String? = nil,
            voice: String? = nil,
            inputAudioFormat: String? = nil,
            outputAudioFormat: String? = nil,
            inputAudioTranscription: InputAudioTranscription? = nil,
            turnDetection: TurnDetection? = nil,
            tools: [Tool]? = nil,
            toolChoice: String? = nil,
            temperature: Double? = nil,
            maxResponseOutputTokens: MaxTokens? = nil
        ) {
            self.modalities = modalities
            self.instructions = instructions
            self.voice = voice
            self.inputAudioFormat = inputAudioFormat
            self.outputAudioFormat = outputAudioFormat
            self.inputAudioTranscription = inputAudioTranscription
            self.turnDetection = turnDetection
            self.tools = tools
            self.toolChoice = toolChoice
            self.temperature = temperature
            self.maxResponseOutputTokens = maxResponseOutputTokens
        }

        public struct InputAudioTranscription: Codable, Sendable {
            public var model: String?

            public init(model: String? = nil) {
                self.model = model
            }
        }

        public struct TurnDetection: Codable, Sendable {
            public var type: String
            public var threshold: Double?
            public var prefixPaddingMs: Int?
            public var silenceDurationMs: Int?
            public var createResponse: Bool?
            public var interruptResponse: Bool?

            public init(
                type: String = "server_vad",
                threshold: Double? = nil,
                prefixPaddingMs: Int? = nil,
                silenceDurationMs: Int? = nil,
                createResponse: Bool? = nil,
                interruptResponse: Bool? = nil
            ) {
                self.type = type
                self.threshold = threshold
                self.prefixPaddingMs = prefixPaddingMs
                self.silenceDurationMs = silenceDurationMs
                self.createResponse = createResponse
                self.interruptResponse = interruptResponse
            }

            enum CodingKeys: String, CodingKey {
                case type, threshold
                case prefixPaddingMs = "prefix_padding_ms"
                case silenceDurationMs = "silence_duration_ms"
                case createResponse = "create_response"
                case interruptResponse = "interrupt_response"
            }
        }

        public struct Tool: Codable, Sendable {
            public var type: String
            public var name: String
            public var description: String?
            public var parameters: JSON?

            public init(type: String = "function", name: String, description: String? = nil, parameters: JSON? = nil) {
                self.type = type
                self.name = name
                self.description = description
                self.parameters = parameters
            }
        }

        public enum MaxTokens: Codable, Sendable {
            case count(Int)
            case infinite

            public init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let str = try? container.decode(String.self), str == "inf" {
                    self = .infinite
                } else if let count = try? container.decode(Int.self) {
                    self = .count(count)
                } else {
                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid max tokens")
                }
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .infinite: try container.encode("inf")
                case .count(let n): try container.encode(n)
                }
            }
        }

        enum CodingKeys: String, CodingKey {
            case modalities, instructions, voice, tools, temperature
            case inputAudioFormat = "input_audio_format"
            case outputAudioFormat = "output_audio_format"
            case inputAudioTranscription = "input_audio_transcription"
            case turnDetection = "turn_detection"
            case toolChoice = "tool_choice"
            case maxResponseOutputTokens = "max_response_output_tokens"
        }
    }

    enum CodingKeys: String, CodingKey {
        case type, session
        case eventId = "event_id"
    }
}

// MARK: - Input Audio Buffer Events

/// Append audio data to the input buffer
public struct InputAudioBufferAppendEvent: Codable, Sendable {
    public let type: String = "input_audio_buffer.append"
    public var eventId: String?
    public var audio: String // Base64-encoded audio

    public init(eventId: String? = nil, audio: String) {
        self.eventId = eventId
        self.audio = audio
    }

    enum CodingKeys: String, CodingKey {
        case type, audio
        case eventId = "event_id"
    }
}

/// Commit the input audio buffer
public struct InputAudioBufferCommitEvent: Codable, Sendable {
    public let type: String = "input_audio_buffer.commit"
    public var eventId: String?

    public init(eventId: String? = nil) {
        self.eventId = eventId
    }

    enum CodingKeys: String, CodingKey {
        case type
        case eventId = "event_id"
    }
}

/// Clear the input audio buffer
public struct InputAudioBufferClearEvent: Codable, Sendable {
    public let type: String = "input_audio_buffer.clear"
    public var eventId: String?

    public init(eventId: String? = nil) {
        self.eventId = eventId
    }

    enum CodingKeys: String, CodingKey {
        case type
        case eventId = "event_id"
    }
}

// MARK: - Conversation Item Events

/// Create a new conversation item
public struct ConversationItemCreateEvent: Codable, Sendable {
    public let type: String = "conversation.item.create"
    public var eventId: String?
    public var previousItemId: String?
    public var item: Item

    public init(eventId: String? = nil, previousItemId: String? = nil, item: Item) {
        self.eventId = eventId
        self.previousItemId = previousItemId
        self.item = item
    }

    public struct Item: Codable, Sendable {
        public var id: String?
        public var type: String // "message", "function_call", "function_call_output"
        public var status: String?
        public var role: String? // "user", "assistant", "system"
        public var content: [Content]?
        public var callId: String? // For function calls
        public var name: String? // Function name
        public var arguments: String? // Function arguments
        public var output: String? // Function output

        public init(
            id: String? = nil,
            type: String,
            status: String? = nil,
            role: String? = nil,
            content: [Content]? = nil,
            callId: String? = nil,
            name: String? = nil,
            arguments: String? = nil,
            output: String? = nil
        ) {
            self.id = id
            self.type = type
            self.status = status
            self.role = role
            self.content = content
            self.callId = callId
            self.name = name
            self.arguments = arguments
            self.output = output
        }

        public struct Content: Codable, Sendable {
            public var type: String // "input_text", "input_audio", "item_reference", "text", "audio"
            public var text: String?
            public var audio: String? // Base64-encoded
            public var transcript: String?
            public var id: String? // For item_reference

            public init(type: String, text: String? = nil, audio: String? = nil, transcript: String? = nil, id: String? = nil) {
                self.type = type
                self.text = text
                self.audio = audio
                self.transcript = transcript
                self.id = id
            }
        }

        enum CodingKeys: String, CodingKey {
            case id, type, status, role, content, name, arguments, output
            case callId = "call_id"
        }
    }

    enum CodingKeys: String, CodingKey {
        case type, item
        case eventId = "event_id"
        case previousItemId = "previous_item_id"
    }
}

/// Truncate a conversation item (for interruption)
public struct ConversationItemTruncateEvent: Codable, Sendable {
    public let type: String = "conversation.item.truncate"
    public var eventId: String?
    public var itemId: String
    public var contentIndex: Int
    public var audioEndMs: Int

    public init(eventId: String? = nil, itemId: String, contentIndex: Int, audioEndMs: Int) {
        self.eventId = eventId
        self.itemId = itemId
        self.contentIndex = contentIndex
        self.audioEndMs = audioEndMs
    }

    enum CodingKeys: String, CodingKey {
        case type
        case eventId = "event_id"
        case itemId = "item_id"
        case contentIndex = "content_index"
        case audioEndMs = "audio_end_ms"
    }
}

/// Delete a conversation item
public struct ConversationItemDeleteEvent: Codable, Sendable {
    public let type: String = "conversation.item.delete"
    public var eventId: String?
    public var itemId: String

    public init(eventId: String? = nil, itemId: String) {
        self.eventId = eventId
        self.itemId = itemId
    }

    enum CodingKeys: String, CodingKey {
        case type
        case eventId = "event_id"
        case itemId = "item_id"
    }
}

// MARK: - Response Events

/// Create a response
public struct ResponseCreateEvent: Codable, Sendable {
    public let type: String = "response.create"
    public var eventId: String?
    public var response: Response?

    public init(eventId: String? = nil, response: Response? = nil) {
        self.eventId = eventId
        self.response = response
    }

    public struct Response: Codable, Sendable {
        public var modalities: [String]?
        public var instructions: String?
        public var voice: String?
        public var outputAudioFormat: String?
        public var tools: [SessionUpdateEvent.Session.Tool]?
        public var toolChoice: String?
        public var temperature: Double?
        public var maxOutputTokens: SessionUpdateEvent.Session.MaxTokens?

        public init(
            modalities: [String]? = nil,
            instructions: String? = nil,
            voice: String? = nil,
            outputAudioFormat: String? = nil,
            tools: [SessionUpdateEvent.Session.Tool]? = nil,
            toolChoice: String? = nil,
            temperature: Double? = nil,
            maxOutputTokens: SessionUpdateEvent.Session.MaxTokens? = nil
        ) {
            self.modalities = modalities
            self.instructions = instructions
            self.voice = voice
            self.outputAudioFormat = outputAudioFormat
            self.tools = tools
            self.toolChoice = toolChoice
            self.temperature = temperature
            self.maxOutputTokens = maxOutputTokens
        }

        enum CodingKeys: String, CodingKey {
            case modalities, instructions, voice, tools, temperature
            case outputAudioFormat = "output_audio_format"
            case toolChoice = "tool_choice"
            case maxOutputTokens = "max_output_tokens"
        }
    }

    enum CodingKeys: String, CodingKey {
        case type, response
        case eventId = "event_id"
    }
}

/// Cancel a response
public struct ResponseCancelEvent: Codable, Sendable {
    public let type: String = "response.cancel"
    public var eventId: String?

    public init(eventId: String? = nil) {
        self.eventId = eventId
    }

    enum CodingKeys: String, CodingKey {
        case type
        case eventId = "event_id"
    }
}
