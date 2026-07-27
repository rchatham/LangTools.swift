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

    /// Creates a new OpenAI Realtime session using the default realtime model.
    /// - Parameter configuration: Session configuration, applied via
    ///   `session.update` once the socket is connected.
    /// - Returns: A connected realtime session
    public func createRealtimeSession(configuration: RealtimeSessionConfiguration) async throws -> OpenAIRealtimeSession {
        try await createRealtimeSession(model: .gpt4o_realtimePreview, configuration: configuration)
    }

    /// Creates a new OpenAI Realtime session for a specific realtime model.
    /// - Parameters:
    ///   - model: The realtime-capable model to connect to (e.g. `.gpt4o_realtimePreview`)
    ///   - configuration: Session configuration, applied via `session.update`
    ///     once the socket is connected.
    /// - Returns: A connected realtime session
    public func createRealtimeSession(model: Model, configuration: RealtimeSessionConfiguration = RealtimeSessionConfiguration()) async throws -> OpenAIRealtimeSession {
        let session = OpenAIRealtimeSession(
            apiKey: apiKey,
            model: model.rawValue,
            sessionConfiguration: configuration
        )
        try await session.connect()
        try await session.updateSession(configuration: configuration)
        return session
    }
}

// MARK: - OpenAI Realtime Session

/// OpenAI Realtime session implementation using WebSocket
public final class OpenAIRealtimeSession: LangToolsRealtimeSession, @unchecked Sendable {
    public typealias ClientEvent = OpenAIRealtimeClientEvent
    public typealias ServerEvent = OpenAIRealtimeServerEvent

    // MARK: - Properties

    private let apiKey: String
    private let model: String
    private var sessionConfiguration: RealtimeSessionConfiguration

    // Shared mutable state below is written from both caller-invoked methods
    // and the background receive loop, so all access goes through `lock`.
    private let lock = NSLock()
    private var _sessionId: String = ""
    private var _state: RealtimeSessionState = .disconnected
    private var _isGenerating: Bool = false
    private var webSocketTask: (any LangToolsWebSocketTask)?
    private var urlSession: URLSession?
    private var receiveTask: Task<Void, Never>?

    /// Factory for the underlying WebSocket transport. Overridable in tests
    /// to inject a scripted transport instead of a live connection.
    internal var webSocketTaskFactory: ((URLRequest) -> any LangToolsWebSocketTask)?

    /// Called when a server message fails to decode (e.g. an unrecognized
    /// event type). The stream keeps running — a single malformed message
    /// isn't fatal — but this makes the failure observable instead of only
    /// reaching stdout.
    public var onDecodeError: (@Sendable (Error) -> Void)?

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public var sessionId: String {
        lock.lock(); defer { lock.unlock() }
        return _sessionId
    }

    public var state: RealtimeSessionState {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    // MARK: - Events Stream

    /// Stream of server events. Created once at init so events received
    /// before the first consumer attaches are buffered, not dropped.
    public let events: AsyncThrowingStream<ServerEvent, Error>
    private let eventContinuation: AsyncThrowingStream<ServerEvent, Error>.Continuation

    // MARK: - Initialization

    public init(apiKey: String, model: String = "gpt-4o-realtime-preview", sessionConfiguration: RealtimeSessionConfiguration = RealtimeSessionConfiguration()) {
        self.apiKey = apiKey
        self.model = model
        self.sessionConfiguration = sessionConfiguration
        (self.events, self.eventContinuation) = AsyncThrowingStream.makeStream(of: ServerEvent.self)
    }

    deinit {
        lock.lock()
        let task = receiveTask
        let socket = webSocketTask
        let session = urlSession
        lock.unlock()

        task?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        eventContinuation.finish()
    }

    // MARK: - Connection

    /// Connect to the OpenAI Realtime API
    public func connect() async throws {
        lock.lock()
        guard _state == .disconnected else { lock.unlock(); return }
        _state = .connecting
        let factory = webSocketTaskFactory
        lock.unlock()

        let urlString = "wss://api.openai.com/v1/realtime?model=\(model)"
        guard let url = URL(string: urlString) else {
            setState(.error)
            throw OpenAIRealtimeError.invalidURL
        }

        var request = URLRequest(url: url)
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

        let task: any LangToolsWebSocketTask
        if let factory {
            task = factory(request)
        } else {
            let session = URLSession(configuration: .default)
            lock.lock(); urlSession = session; lock.unlock()
            task = session.webSocketTask(with: request)
        }

        lock.lock()
        webSocketTask = task
        lock.unlock()

        task.resume()

        // Start receiving messages
        startReceiving()

        setState(.connected)
    }

    /// Disconnect from the session
    public func disconnect() async {
        lock.lock()
        _state = .disconnected
        let task = receiveTask
        let socket = webSocketTask
        let session = urlSession
        receiveTask = nil
        webSocketTask = nil
        urlSession = nil
        lock.unlock()

        task?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        eventContinuation.finish()
    }

    // MARK: - Sending Events

    public func send(event: ClientEvent) async throws {
        lock.lock()
        guard _state == .connected, let socket = webSocketTask else {
            lock.unlock()
            throw OpenAIRealtimeError.notConnected
        }
        lock.unlock()

        let data = try encoder.encode(event)
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw OpenAIRealtimeError.encodingError
        }

        try await socket.send(.string(jsonString))
    }

    // MARK: - Session Update

    public func updateSession(configuration: RealtimeSessionConfiguration) async throws {
        lock.lock()
        self.sessionConfiguration = configuration
        lock.unlock()

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

    private func setState(_ newState: RealtimeSessionState) {
        lock.lock()
        _state = newState
        lock.unlock()
    }

    private func startReceiving() {
        let task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let socket: (any LangToolsWebSocketTask)?
                self.lock.lock()
                socket = self.webSocketTask
                self.lock.unlock()
                guard let socket else { return }

                do {
                    let message = try await socket.receive()

                    switch message {
                    case .string(let text):
                        if let data = text.data(using: .utf8) {
                            self.handleIncoming(data)
                        }

                    case .data(let data):
                        self.handleIncoming(data)

                    @unknown default:
                        break
                    }
                } catch {
                    if !Task.isCancelled {
                        self.eventContinuation.finish(throwing: error)
                    }
                    break
                }
            }
        }
        lock.lock()
        receiveTask = task
        lock.unlock()
    }

    private func handleIncoming(_ data: Data) {
        do {
            let event = try decoder.decode(OpenAIRealtimeServerEvent.self, from: data)
            handleServerEvent(event)
            eventContinuation.yield(event)
        } catch {
            // A single malformed or unrecognized event (e.g. a newly added
            // server event type) should not kill the stream — surface it for
            // observability and continue.
            onDecodeError?(error)
        }
    }

    private func handleServerEvent(_ event: OpenAIRealtimeServerEvent) {
        switch event {
        case .sessionCreated(let sessionEvent):
            lock.lock()
            _sessionId = sessionEvent.session.id
            lock.unlock()
        case .responseCreated:
            lock.lock()
            _isGenerating = true
            lock.unlock()
        case .responseDone:
            lock.lock()
            _isGenerating = false
            lock.unlock()
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
    /// Whether the model is currently generating a response, tracked from
    /// `response.created` / `response.done` server events.
    public var isGenerating: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isGenerating
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
