//
//  OpenAI+Realtime.swift
//  OpenAI
//
//  Created by Reid Chatham on 1/16/26.
//

import Foundation
import LangTools
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - OpenAI Realtime Extension

extension OpenAI: LangToolsRealtime {
    public typealias RealtimeSession = OpenAIRealtimeSession

    /// Creates a new OpenAI Realtime session
    /// - Parameter configuration: Session configuration
    /// - Returns: A connected realtime session
    public func createRealtimeSession(configuration: RealtimeSessionConfiguration) async throws -> OpenAIRealtimeSession {
        let session = OpenAIRealtimeSession(
            apiKey: configuration.apiKey,
            model: configuration.model ?? "gpt-4o-realtime-preview",
            sessionConfiguration: configuration
        )
        try await session.connect()
        return session
    }
}

// MARK: - Realtime Session Configuration Extension

extension RealtimeSessionConfiguration {
    var apiKey: String? {
        // This would be set externally
        nil
    }

    var model: String? {
        nil
    }
}

// MARK: - OpenAI Realtime Session

/// OpenAI Realtime session implementation using WebSocket
public final class OpenAIRealtimeSession: LangToolsRealtimeSession, @unchecked Sendable {
    public typealias ClientEvent = OpenAIRealtimeClientEvent
    public typealias ServerEvent = OpenAIRealtimeServerEvent

    // MARK: - Properties

    public private(set) var sessionId: String = ""
    public private(set) var state: RealtimeSessionState = .disconnected

    private let apiKey: String
    private let model: String
    private var sessionConfiguration: RealtimeSessionConfiguration

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?

    private var eventContinuation: AsyncThrowingStream<ServerEvent, Error>.Continuation?
    private var receiveTask: Task<Void, Never>?

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - Events Stream

    public var events: AsyncThrowingStream<ServerEvent, Error> {
        AsyncThrowingStream { continuation in
            self.eventContinuation = continuation
        }
    }

    // MARK: - Initialization

    public init(apiKey: String, model: String = "gpt-4o-realtime-preview", sessionConfiguration: RealtimeSessionConfiguration = RealtimeSessionConfiguration()) {
        self.apiKey = apiKey
        self.model = model
        self.sessionConfiguration = sessionConfiguration
    }

    deinit {
        receiveTask?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
    }

    // MARK: - Connection

    /// Connect to the OpenAI Realtime API
    public func connect() async throws {
        guard state == .disconnected else { return }

        state = .connecting

        let urlString = "wss://api.openai.com/v1/realtime?model=\(model)"
        guard let url = URL(string: urlString) else {
            throw OpenAIRealtimeError.invalidURL
        }

        var request = URLRequest(url: url)
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

        let configuration = URLSessionConfiguration.default
        urlSession = URLSession(configuration: configuration)
        webSocketTask = urlSession?.webSocketTask(with: request)

        webSocketTask?.resume()

        // Start receiving messages
        startReceiving()

        state = .connected
    }

    /// Disconnect from the session
    public func disconnect() async {
        state = .disconnected
        receiveTask?.cancel()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        eventContinuation?.finish()
    }

    // MARK: - Sending Events

    public func send(event: ClientEvent) async throws {
        guard state == .connected else {
            throw OpenAIRealtimeError.notConnected
        }

        let data = try encoder.encode(event)
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw OpenAIRealtimeError.encodingError
        }

        let message = URLSessionWebSocketTask.Message.string(jsonString)
        try await webSocketTask?.send(message)
    }

    // MARK: - Session Update

    public func updateSession(configuration: RealtimeSessionConfiguration) async throws {
        self.sessionConfiguration = configuration

        let event = SessionUpdateEvent(session: SessionUpdateEvent.Session(
            modalities: configuration.modalities?.map { $0.rawValue },
            instructions: configuration.instructions,
            voice: configuration.voice,
            inputAudioFormat: configuration.inputAudioFormat?.rawValue,
            outputAudioFormat: configuration.outputAudioFormat?.rawValue,
            inputAudioTranscription: configuration.inputAudioTranscription.map {
                SessionUpdateEvent.Session.InputAudioTranscription(model: $0.model)
            },
            turnDetection: configuration.turnDetection.map {
                SessionUpdateEvent.Session.TurnDetection(
                    type: $0.type.rawValue,
                    threshold: $0.threshold,
                    prefixPaddingMs: $0.prefixPaddingMs,
                    silenceDurationMs: $0.silenceDurationMs,
                    createResponse: $0.createResponse,
                    interruptResponse: $0.interruptResponse
                )
            },
            tools: configuration.tools?.map {
                SessionUpdateEvent.Session.Tool(
                    type: $0.type,
                    name: $0.name,
                    description: $0.description,
                    parameters: $0.parameters
                )
            },
            toolChoice: configuration.toolChoice.map { choice -> String in
                switch choice {
                case .auto: return "auto"
                case .none: return "none"
                case .required: return "required"
                case .function(let name): return name
                }
            },
            temperature: configuration.temperature,
            maxResponseOutputTokens: configuration.maxResponseOutputTokens.map { maxTokens -> SessionUpdateEvent.Session.MaxTokens in
                switch maxTokens {
                case .count(let n): return .count(n)
                case .infinite: return .infinite
                }
            }
        ))

        try await send(event: .sessionUpdate(event))
    }

    // MARK: - Receiving Events

    private func startReceiving() {
        receiveTask = Task { [weak self] in
            guard let self = self else { return }

            while !Task.isCancelled {
                do {
                    guard let message = try await self.webSocketTask?.receive() else {
                        continue
                    }

                    switch message {
                    case .string(let text):
                        if let data = text.data(using: .utf8) {
                            do {
                                let event = try self.decoder.decode(OpenAIRealtimeServerEvent.self, from: data)
                                self.handleServerEvent(event)
                                self.eventContinuation?.yield(event)
                            } catch {
                                print("Failed to decode event: \(error)")
                            }
                        }

                    case .data(let data):
                        do {
                            let event = try self.decoder.decode(OpenAIRealtimeServerEvent.self, from: data)
                            self.handleServerEvent(event)
                            self.eventContinuation?.yield(event)
                        } catch {
                            print("Failed to decode event: \(error)")
                        }

                    @unknown default:
                        break
                    }
                } catch {
                    if !Task.isCancelled {
                        self.eventContinuation?.finish(throwing: error)
                    }
                    break
                }
            }
        }
    }

    private func handleServerEvent(_ event: OpenAIRealtimeServerEvent) {
        switch event {
        case .sessionCreated(let sessionEvent):
            self.sessionId = sessionEvent.session.id
        case .error(let errorEvent):
            print("OpenAI Realtime Error: \(errorEvent.error.message)")
        default:
            break
        }
    }
}

// MARK: - Audio Buffer Extension

extension OpenAIRealtimeSession: LangToolsAudioBuffer {
    /// Append audio data to the input buffer
    public func append(audio: Data) async throws {
        let base64Audio = audio.base64EncodedString()
        let event = InputAudioBufferAppendEvent(audio: base64Audio)
        try await send(event: .inputAudioBufferAppend(event))
    }

    /// Commit the audio buffer
    public func commit() async throws {
        let event = InputAudioBufferCommitEvent()
        try await send(event: .inputAudioBufferCommit(event))
    }

    /// Clear the audio buffer
    public func clear() async throws {
        let event = InputAudioBufferClearEvent()
        try await send(event: .inputAudioBufferClear(event))
    }
}

// MARK: - Interruptible Extension

extension OpenAIRealtimeSession: LangToolsInterruptible {
    public var isGenerating: Bool {
        // Track this based on response.created/response.done events
        false
    }

    public func cancelResponse() async throws {
        let event = ResponseCancelEvent()
        try await send(event: .responseCancel(event))
    }
}

// MARK: - Convenience Methods

extension OpenAIRealtimeSession {
    /// Create a response
    public func createResponse(instructions: String? = nil) async throws {
        let event = ResponseCreateEvent(response: ResponseCreateEvent.Response(
            modalities: nil,
            instructions: instructions,
            voice: nil,
            outputAudioFormat: nil,
            tools: nil,
            toolChoice: nil,
            temperature: nil,
            maxOutputTokens: nil
        ))
        try await send(event: .responseCreate(event))
    }

    /// Send a text message to the conversation
    public func sendMessage(_ text: String, role: String = "user") async throws {
        let event = ConversationItemCreateEvent(item: ConversationItemCreateEvent.Item(
            type: "message",
            role: role,
            content: [
                ConversationItemCreateEvent.Item.Content(type: "input_text", text: text)
            ]
        ))
        try await send(event: .conversationItemCreate(event))
    }

    /// Truncate a conversation item (for interruption handling)
    public func truncateItem(itemId: String, contentIndex: Int, audioEndMs: Int) async throws {
        let event = ConversationItemTruncateEvent(
            itemId: itemId,
            contentIndex: contentIndex,
            audioEndMs: audioEndMs
        )
        try await send(event: .conversationItemTruncate(event))
    }
}

// MARK: - Errors

public enum OpenAIRealtimeError: Error, LocalizedError {
    case invalidURL
    case notConnected
    case encodingError
    case decodingError
    case connectionFailed(Error)
    case sessionError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid WebSocket URL"
        case .notConnected:
            return "Not connected to the realtime session"
        case .encodingError:
            return "Failed to encode event"
        case .decodingError:
            return "Failed to decode event"
        case .connectionFailed(let error):
            return "Connection failed: \(error.localizedDescription)"
        case .sessionError(let message):
            return "Session error: \(message)"
        }
    }
}
