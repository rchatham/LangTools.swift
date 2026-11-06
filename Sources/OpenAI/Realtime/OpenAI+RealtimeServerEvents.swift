//
//  OpenAI+RealtimeServerEvents.swift
//  OpenAI
//
//  Created by Reid Chatham on 1/16/26.
//

import Foundation
import LangTools

// MARK: - Server Events Enum

/// All server events received from the OpenAI Realtime API
public enum OpenAIRealtimeServerEvent: LangToolsRealtimeServerEvent, Decodable {
    // Session events
    case sessionCreated(SessionCreatedEvent)
    case sessionUpdated(SessionUpdatedEvent)

    // Conversation events
    case conversationCreated(ConversationCreatedEvent)
    case conversationItemCreated(ConversationItemCreatedEvent)
    case conversationItemInputAudioTranscriptionCompleted(InputAudioTranscriptionCompletedEvent)
    case conversationItemInputAudioTranscriptionFailed(InputAudioTranscriptionFailedEvent)
    case conversationItemTruncated(ConversationItemTruncatedEvent)
    case conversationItemDeleted(ConversationItemDeletedEvent)

    // Input audio buffer events
    case inputAudioBufferCommitted(InputAudioBufferCommittedEvent)
    case inputAudioBufferCleared(InputAudioBufferClearedEvent)
    case inputAudioBufferSpeechStarted(InputAudioBufferSpeechStartedEvent)
    case inputAudioBufferSpeechStopped(InputAudioBufferSpeechStoppedEvent)

    // Response events
    case responseCreated(ResponseCreatedEvent)
    case responseDone(ResponseDoneEvent)
    case responseOutputItemAdded(ResponseOutputItemAddedEvent)
    case responseOutputItemDone(ResponseOutputItemDoneEvent)
    case responseContentPartAdded(ResponseContentPartAddedEvent)
    case responseContentPartDone(ResponseContentPartDoneEvent)
    case responseTextDelta(ResponseTextDeltaEvent)
    case responseTextDone(ResponseTextDoneEvent)
    case responseAudioTranscriptDelta(ResponseAudioTranscriptDeltaEvent)
    case responseAudioTranscriptDone(ResponseAudioTranscriptDoneEvent)
    case responseAudioDelta(ResponseAudioDeltaEvent)
    case responseAudioDone(ResponseAudioDoneEvent)
    case responseFunctionCallArgumentsDelta(ResponseFunctionCallArgumentsDeltaEvent)
    case responseFunctionCallArgumentsDone(ResponseFunctionCallArgumentsDoneEvent)

    // Rate limit events
    case rateLimitsUpdated(RateLimitsUpdatedEvent)

    // Error event
    case error(ErrorEvent)

    public var eventId: String {
        switch self {
        case .sessionCreated(let e): return e.eventId
        case .sessionUpdated(let e): return e.eventId
        case .conversationCreated(let e): return e.eventId
        case .conversationItemCreated(let e): return e.eventId
        case .conversationItemInputAudioTranscriptionCompleted(let e): return e.eventId
        case .conversationItemInputAudioTranscriptionFailed(let e): return e.eventId
        case .conversationItemTruncated(let e): return e.eventId
        case .conversationItemDeleted(let e): return e.eventId
        case .inputAudioBufferCommitted(let e): return e.eventId
        case .inputAudioBufferCleared(let e): return e.eventId
        case .inputAudioBufferSpeechStarted(let e): return e.eventId
        case .inputAudioBufferSpeechStopped(let e): return e.eventId
        case .responseCreated(let e): return e.eventId
        case .responseDone(let e): return e.eventId
        case .responseOutputItemAdded(let e): return e.eventId
        case .responseOutputItemDone(let e): return e.eventId
        case .responseContentPartAdded(let e): return e.eventId
        case .responseContentPartDone(let e): return e.eventId
        case .responseTextDelta(let e): return e.eventId
        case .responseTextDone(let e): return e.eventId
        case .responseAudioTranscriptDelta(let e): return e.eventId
        case .responseAudioTranscriptDone(let e): return e.eventId
        case .responseAudioDelta(let e): return e.eventId
        case .responseAudioDone(let e): return e.eventId
        case .responseFunctionCallArgumentsDelta(let e): return e.eventId
        case .responseFunctionCallArgumentsDone(let e): return e.eventId
        case .rateLimitsUpdated(let e): return e.eventId
        case .error(let e): return e.eventId
        }
    }

    public var type: String {
        switch self {
        case .sessionCreated: return "session.created"
        case .sessionUpdated: return "session.updated"
        case .conversationCreated: return "conversation.created"
        case .conversationItemCreated: return "conversation.item.created"
        case .conversationItemInputAudioTranscriptionCompleted: return "conversation.item.input_audio_transcription.completed"
        case .conversationItemInputAudioTranscriptionFailed: return "conversation.item.input_audio_transcription.failed"
        case .conversationItemTruncated: return "conversation.item.truncated"
        case .conversationItemDeleted: return "conversation.item.deleted"
        case .inputAudioBufferCommitted: return "input_audio_buffer.committed"
        case .inputAudioBufferCleared: return "input_audio_buffer.cleared"
        case .inputAudioBufferSpeechStarted: return "input_audio_buffer.speech_started"
        case .inputAudioBufferSpeechStopped: return "input_audio_buffer.speech_stopped"
        case .responseCreated: return "response.created"
        case .responseDone: return "response.done"
        case .responseOutputItemAdded: return "response.output_item.added"
        case .responseOutputItemDone: return "response.output_item.done"
        case .responseContentPartAdded: return "response.content_part.added"
        case .responseContentPartDone: return "response.content_part.done"
        case .responseTextDelta: return "response.text.delta"
        case .responseTextDone: return "response.text.done"
        case .responseAudioTranscriptDelta: return "response.audio_transcript.delta"
        case .responseAudioTranscriptDone: return "response.audio_transcript.done"
        case .responseAudioDelta: return "response.audio.delta"
        case .responseAudioDone: return "response.audio.done"
        case .responseFunctionCallArgumentsDelta: return "response.function_call_arguments.delta"
        case .responseFunctionCallArgumentsDone: return "response.function_call_arguments.done"
        case .rateLimitsUpdated: return "rate_limits.updated"
        case .error: return "error"
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: TypeCodingKey.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "session.created":
            self = .sessionCreated(try SessionCreatedEvent(from: decoder))
        case "session.updated":
            self = .sessionUpdated(try SessionUpdatedEvent(from: decoder))
        case "conversation.created":
            self = .conversationCreated(try ConversationCreatedEvent(from: decoder))
        case "conversation.item.created":
            self = .conversationItemCreated(try ConversationItemCreatedEvent(from: decoder))
        case "conversation.item.input_audio_transcription.completed":
            self = .conversationItemInputAudioTranscriptionCompleted(try InputAudioTranscriptionCompletedEvent(from: decoder))
        case "conversation.item.input_audio_transcription.failed":
            self = .conversationItemInputAudioTranscriptionFailed(try InputAudioTranscriptionFailedEvent(from: decoder))
        case "conversation.item.truncated":
            self = .conversationItemTruncated(try ConversationItemTruncatedEvent(from: decoder))
        case "conversation.item.deleted":
            self = .conversationItemDeleted(try ConversationItemDeletedEvent(from: decoder))
        case "input_audio_buffer.committed":
            self = .inputAudioBufferCommitted(try InputAudioBufferCommittedEvent(from: decoder))
        case "input_audio_buffer.cleared":
            self = .inputAudioBufferCleared(try InputAudioBufferClearedEvent(from: decoder))
        case "input_audio_buffer.speech_started":
            self = .inputAudioBufferSpeechStarted(try InputAudioBufferSpeechStartedEvent(from: decoder))
        case "input_audio_buffer.speech_stopped":
            self = .inputAudioBufferSpeechStopped(try InputAudioBufferSpeechStoppedEvent(from: decoder))
        case "response.created":
            self = .responseCreated(try ResponseCreatedEvent(from: decoder))
        case "response.done":
            self = .responseDone(try ResponseDoneEvent(from: decoder))
        case "response.output_item.added":
            self = .responseOutputItemAdded(try ResponseOutputItemAddedEvent(from: decoder))
        case "response.output_item.done":
            self = .responseOutputItemDone(try ResponseOutputItemDoneEvent(from: decoder))
        case "response.content_part.added":
            self = .responseContentPartAdded(try ResponseContentPartAddedEvent(from: decoder))
        case "response.content_part.done":
            self = .responseContentPartDone(try ResponseContentPartDoneEvent(from: decoder))
        case "response.text.delta":
            self = .responseTextDelta(try ResponseTextDeltaEvent(from: decoder))
        case "response.text.done":
            self = .responseTextDone(try ResponseTextDoneEvent(from: decoder))
        case "response.audio_transcript.delta":
            self = .responseAudioTranscriptDelta(try ResponseAudioTranscriptDeltaEvent(from: decoder))
        case "response.audio_transcript.done":
            self = .responseAudioTranscriptDone(try ResponseAudioTranscriptDoneEvent(from: decoder))
        case "response.audio.delta":
            self = .responseAudioDelta(try ResponseAudioDeltaEvent(from: decoder))
        case "response.audio.done":
            self = .responseAudioDone(try ResponseAudioDoneEvent(from: decoder))
        case "response.function_call_arguments.delta":
            self = .responseFunctionCallArgumentsDelta(try ResponseFunctionCallArgumentsDeltaEvent(from: decoder))
        case "response.function_call_arguments.done":
            self = .responseFunctionCallArgumentsDone(try ResponseFunctionCallArgumentsDoneEvent(from: decoder))
        case "rate_limits.updated":
            self = .rateLimitsUpdated(try RateLimitsUpdatedEvent(from: decoder))
        case "error":
            self = .error(try ErrorEvent(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown event type: \(type)")
        }
    }

    private enum TypeCodingKey: String, CodingKey {
        case type
    }
}

// MARK: - Session Events

public struct SessionCreatedEvent: Codable, Sendable {
    public let type: String
    public let eventId: String
    public let session: Session

    public struct Session: Codable, Sendable {
        public let id: String
        public let object: String
        public let model: String
        public let expiresAt: Int?
        public let modalities: [String]?
        public let instructions: String?
        public let voice: String?
        public let inputAudioFormat: String?
        public let outputAudioFormat: String?
        public let inputAudioTranscription: InputAudioTranscription?
        public let turnDetection: TurnDetection?
        public let tools: [Tool]?
        public let toolChoice: String?
        public let temperature: Double?
        public let maxResponseOutputTokens: MaxTokensValue?

        public struct InputAudioTranscription: Codable, Sendable {
            public let model: String?
        }

        public struct TurnDetection: Codable, Sendable {
            public let type: String?
            public let threshold: Double?
            public let prefixPaddingMs: Int?
            public let silenceDurationMs: Int?
            public let createResponse: Bool?
            public let interruptResponse: Bool?

            enum CodingKeys: String, CodingKey {
                case type, threshold
                case prefixPaddingMs = "prefix_padding_ms"
                case silenceDurationMs = "silence_duration_ms"
                case createResponse = "create_response"
                case interruptResponse = "interrupt_response"
            }
        }

        public struct Tool: Codable, Sendable {
            public let type: String
            public let name: String
            public let description: String?
            public let parameters: JSON?
        }

        public enum MaxTokensValue: Codable, Sendable {
            case int(Int)
            case string(String)

            public init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let intValue = try? container.decode(Int.self) {
                    self = .int(intValue)
                } else if let strValue = try? container.decode(String.self) {
                    self = .string(strValue)
                } else {
                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected Int or String")
                }
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .int(let value): try container.encode(value)
                case .string(let value): try container.encode(value)
                }
            }
        }

        enum CodingKeys: String, CodingKey {
            case id, object, model, modalities, instructions, voice, tools, temperature
            case expiresAt = "expires_at"
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

public struct SessionUpdatedEvent: Codable, Sendable {
    public let type: String
    public let eventId: String
    public let session: SessionCreatedEvent.Session

    enum CodingKeys: String, CodingKey {
        case type, session
        case eventId = "event_id"
    }
}

// MARK: - Conversation Events

public struct ConversationCreatedEvent: Codable, Sendable {
    public let type: String
    public let eventId: String
    public let conversation: Conversation

    public struct Conversation: Codable, Sendable {
        public let id: String
        public let object: String
    }

    enum CodingKeys: String, CodingKey {
        case type, conversation
        case eventId = "event_id"
    }
}

public struct ConversationItemCreatedEvent: Codable, Sendable {
    public let type: String
    public let eventId: String
    public let previousItemId: String?
    public let item: Item

    public struct Item: Codable, Sendable {
        public let id: String
        public let object: String
        public let type: String
        public let status: String?
        public let role: String?
        public let content: [Content]?

        public struct Content: Codable, Sendable {
            public let type: String
            public let text: String?
            public let audio: String?
            public let transcript: String?
        }
    }

    enum CodingKeys: String, CodingKey {
        case type, item
        case eventId = "event_id"
        case previousItemId = "previous_item_id"
    }
}

public struct InputAudioTranscriptionCompletedEvent: Codable, Sendable {
    public let type: String
    public let eventId: String
    public let itemId: String
    public let contentIndex: Int
    public let transcript: String

    enum CodingKeys: String, CodingKey {
        case type, transcript
        case eventId = "event_id"
        case itemId = "item_id"
        case contentIndex = "content_index"
    }
}

public struct InputAudioTranscriptionFailedEvent: Codable, Sendable {
    public let type: String
    public let eventId: String
    public let itemId: String
    public let contentIndex: Int
    public let error: ErrorDetail

    public struct ErrorDetail: Codable, Sendable {
        public let type: String
        public let code: String?
        public let message: String
        public let param: String?
    }

    enum CodingKeys: String, CodingKey {
        case type, error
        case eventId = "event_id"
        case itemId = "item_id"
        case contentIndex = "content_index"
    }
}

public struct ConversationItemTruncatedEvent: Codable, Sendable {
    public let type: String
    public let eventId: String
    public let itemId: String
    public let contentIndex: Int
    public let audioEndMs: Int

    enum CodingKeys: String, CodingKey {
        case type
        case eventId = "event_id"
        case itemId = "item_id"
        case contentIndex = "content_index"
        case audioEndMs = "audio_end_ms"
    }
}

public struct ConversationItemDeletedEvent: Codable, Sendable {
    public let type: String
    public let eventId: String
    public let itemId: String

    enum CodingKeys: String, CodingKey {
        case type
        case eventId = "event_id"
        case itemId = "item_id"
    }
}

// MARK: - Input Audio Buffer Events

public struct InputAudioBufferCommittedEvent: Codable, Sendable {
    public let type: String
    public let eventId: String
    public let previousItemId: String?
    public let itemId: String

    enum CodingKeys: String, CodingKey {
        case type
        case eventId = "event_id"
        case previousItemId = "previous_item_id"
        case itemId = "item_id"
    }
}

public struct InputAudioBufferClearedEvent: Codable, Sendable {
    public let type: String
    public let eventId: String

    enum CodingKeys: String, CodingKey {
        case type
        case eventId = "event_id"
    }
}

public struct InputAudioBufferSpeechStartedEvent: Codable, Sendable {
    public let type: String
    public let eventId: String
    public let audioStartMs: Int
    public let itemId: String

    enum CodingKeys: String, CodingKey {
        case type
        case eventId = "event_id"
        case audioStartMs = "audio_start_ms"
        case itemId = "item_id"
    }
}

public struct InputAudioBufferSpeechStoppedEvent: Codable, Sendable {
    public let type: String
    public let eventId: String
    public let audioEndMs: Int
    public let itemId: String

    enum CodingKeys: String, CodingKey {
        case type
        case eventId = "event_id"
        case audioEndMs = "audio_end_ms"
        case itemId = "item_id"
    }
}

// MARK: - Response Events

public struct ResponseCreatedEvent: Codable, Sendable {
    public let type: String
    public let eventId: String
    public let response: Response

    public struct Response: Codable, Sendable {
        public let id: String
        public let object: String
        public let status: String
        public let statusDetails: JSON?
        public let output: [JSON]?
        public let usage: JSON?

        enum CodingKeys: String, CodingKey {
            case id, object, status, output, usage
            case statusDetails = "status_details"
        }
    }

    enum CodingKeys: String, CodingKey {
        case type, response
        case eventId = "event_id"
    }
}

public struct ResponseDoneEvent: Codable, Sendable {
    public let type: String
    public let eventId: String
    public let response: ResponseCreatedEvent.Response

    enum CodingKeys: String, CodingKey {
        case type, response
        case eventId = "event_id"
    }
}

public struct ResponseOutputItemAddedEvent: Codable, Sendable {
    public let type: String
    public let eventId: String
    public let responseId: String
    public let outputIndex: Int
    public let item: ConversationItemCreatedEvent.Item

    enum CodingKeys: String, CodingKey {
        case type, item
        case eventId = "event_id"
        case responseId = "response_id"
        case outputIndex = "output_index"
    }
}

public struct ResponseOutputItemDoneEvent: Codable, Sendable {
    public let type: String
    public let eventId: String
    public let responseId: String
    public let outputIndex: Int
    public let item: ConversationItemCreatedEvent.Item

    enum CodingKeys: String, CodingKey {
        case type, item
        case eventId = "event_id"
        case responseId = "response_id"
        case outputIndex = "output_index"
    }
}

public struct ResponseContentPartAddedEvent: Codable, Sendable {
    public let type: String
    public let eventId: String
    public let responseId: String
    public let itemId: String
    public let outputIndex: Int
    public let contentIndex: Int
    public let part: ContentPart

    public struct ContentPart: Codable, Sendable {
        public let type: String
        public let text: String?
        public let audio: String?
        public let transcript: String?
    }

    enum CodingKeys: String, CodingKey {
        case type, part
        case eventId = "event_id"
        case responseId = "response_id"
        case itemId = "item_id"
        case outputIndex = "output_index"
        case contentIndex = "content_index"
    }
}

public struct ResponseContentPartDoneEvent: Codable, Sendable {
    public let type: String
    public let eventId: String
    public let responseId: String
    public let itemId: String
    public let outputIndex: Int
    public let contentIndex: Int
    public let part: ResponseContentPartAddedEvent.ContentPart

    enum CodingKeys: String, CodingKey {
        case type, part
        case eventId = "event_id"
        case responseId = "response_id"
        case itemId = "item_id"
        case outputIndex = "output_index"
        case contentIndex = "content_index"
    }
}

public struct ResponseTextDeltaEvent: Codable, Sendable {
    public let type: String
    public let eventId: String
    public let responseId: String
    public let itemId: String
    public let outputIndex: Int
    public let contentIndex: Int
    public let delta: String

    enum CodingKeys: String, CodingKey {
        case type, delta
        case eventId = "event_id"
        case responseId = "response_id"
        case itemId = "item_id"
        case outputIndex = "output_index"
        case contentIndex = "content_index"
    }
}

public struct ResponseTextDoneEvent: Codable, Sendable {
    public let type: String
    public let eventId: String
    public let responseId: String
    public let itemId: String
    public let outputIndex: Int
    public let contentIndex: Int
    public let text: String

    enum CodingKeys: String, CodingKey {
        case type, text
        case eventId = "event_id"
        case responseId = "response_id"
        case itemId = "item_id"
        case outputIndex = "output_index"
        case contentIndex = "content_index"
    }
}

public struct ResponseAudioTranscriptDeltaEvent: Codable, Sendable {
    public let type: String
    public let eventId: String
    public let responseId: String
    public let itemId: String
    public let outputIndex: Int
    public let contentIndex: Int
    public let delta: String

    enum CodingKeys: String, CodingKey {
        case type, delta
        case eventId = "event_id"
        case responseId = "response_id"
        case itemId = "item_id"
        case outputIndex = "output_index"
        case contentIndex = "content_index"
    }
}

public struct ResponseAudioTranscriptDoneEvent: Codable, Sendable {
    public let type: String
    public let eventId: String
    public let responseId: String
    public let itemId: String
    public let outputIndex: Int
    public let contentIndex: Int
    public let transcript: String

    enum CodingKeys: String, CodingKey {
        case type, transcript
        case eventId = "event_id"
        case responseId = "response_id"
        case itemId = "item_id"
        case outputIndex = "output_index"
        case contentIndex = "content_index"
    }
}

public struct ResponseAudioDeltaEvent: Codable, Sendable {
    public let type: String
    public let eventId: String
    public let responseId: String
    public let itemId: String
    public let outputIndex: Int
    public let contentIndex: Int
    public let delta: String // Base64-encoded audio

    enum CodingKeys: String, CodingKey {
        case type, delta
        case eventId = "event_id"
        case responseId = "response_id"
        case itemId = "item_id"
        case outputIndex = "output_index"
        case contentIndex = "content_index"
    }

    /// Decode the base64 audio delta to Data
    public var audioData: Data? {
        Data(base64Encoded: delta)
    }
}

public struct ResponseAudioDoneEvent: Codable, Sendable {
    public let type: String
    public let eventId: String
    public let responseId: String
    public let itemId: String
    public let outputIndex: Int
    public let contentIndex: Int

    enum CodingKeys: String, CodingKey {
        case type
        case eventId = "event_id"
        case responseId = "response_id"
        case itemId = "item_id"
        case outputIndex = "output_index"
        case contentIndex = "content_index"
    }
}

public struct ResponseFunctionCallArgumentsDeltaEvent: Codable, Sendable {
    public let type: String
    public let eventId: String
    public let responseId: String
    public let itemId: String
    public let outputIndex: Int
    public let callId: String
    public let delta: String

    enum CodingKeys: String, CodingKey {
        case type, delta
        case eventId = "event_id"
        case responseId = "response_id"
        case itemId = "item_id"
        case outputIndex = "output_index"
        case callId = "call_id"
    }
}

public struct ResponseFunctionCallArgumentsDoneEvent: Codable, Sendable {
    public let type: String
    public let eventId: String
    public let responseId: String
    public let itemId: String
    public let outputIndex: Int
    public let callId: String
    public let name: String
    public let arguments: String

    enum CodingKeys: String, CodingKey {
        case type, name, arguments
        case eventId = "event_id"
        case responseId = "response_id"
        case itemId = "item_id"
        case outputIndex = "output_index"
        case callId = "call_id"
    }
}

// MARK: - Rate Limit Events

public struct RateLimitsUpdatedEvent: Codable, Sendable {
    public let type: String
    public let eventId: String
    public let rateLimits: [RateLimit]

    public struct RateLimit: Codable, Sendable {
        public let name: String
        public let limit: Int
        public let remaining: Int
        public let resetSeconds: Double

        enum CodingKeys: String, CodingKey {
            case name, limit, remaining
            case resetSeconds = "reset_seconds"
        }
    }

    enum CodingKeys: String, CodingKey {
        case type
        case eventId = "event_id"
        case rateLimits = "rate_limits"
    }
}

// MARK: - Error Event

public struct ErrorEvent: Codable, Sendable {
    public let type: String
    public let eventId: String
    public let error: ErrorDetail

    public struct ErrorDetail: Codable, Sendable {
        public let type: String
        public let code: String?
        public let message: String
        public let param: String?
        public let eventId: String?

        enum CodingKeys: String, CodingKey {
            case type, code, message, param
            case eventId = "event_id"
        }
    }

    enum CodingKeys: String, CodingKey {
        case type, error
        case eventId = "event_id"
    }
}
