//
//  ElevenLabs+SpeechToText.swift
//  ElevenLabs
//
//  Created by Reid Chatham on 1/16/26.
//

import Foundation
import LangTools
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - WebSocket STT Session Factory

extension ElevenLabs {
    /// Create a WebSocket STT session for real-time speech-to-text using Scribe
    public func createSTTSession(
        modelId: String = ElevenLabsModel.scribeRealtimeV2.id,
        language: String? = nil,
        enablePartials: Bool = true
    ) -> ElevenLabsSTTSession {
        return ElevenLabsSTTSession(
            apiKey: apiKey,
            modelId: modelId,
            language: language,
            enablePartials: enablePartials
        )
    }
}

// MARK: - STT WebSocket Session

/// ElevenLabs WebSocket session for real-time speech-to-text (Scribe)
public final class ElevenLabsSTTSession: @unchecked Sendable {
    // MARK: - Properties

    private let apiKey: String
    private let modelId: String
    private let language: String?
    private let enablePartials: Bool

    // Written from both caller methods and the background receive loop —
    // guarded by `lock`.
    private let lock = NSLock()
    private var webSocketTask: (any LangToolsWebSocketTask)?
    private var urlSession: URLSession?
    private var receiveTask: Task<Void, Never>?
    private var _isConnected: Bool = false

    /// Factory for the underlying WebSocket transport. Overridable in tests.
    internal var webSocketTaskFactory: ((URLRequest) -> any LangToolsWebSocketTask)?

    /// Called when a server message fails to decode. The stream keeps
    /// running — a single malformed message isn't fatal.
    public var onDecodeError: (@Sendable (Error) -> Void)?

    public var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isConnected
    }

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - Transcription Stream

    /// Stream of transcription results. Created once at init so results
    /// received before the first consumer attaches are buffered, not dropped.
    public let transcriptions: AsyncThrowingStream<STTTranscription, Error>
    private let transcriptionContinuation: AsyncThrowingStream<STTTranscription, Error>.Continuation

    // MARK: - Initialization

    public init(
        apiKey: String,
        modelId: String = ElevenLabsModel.scribeRealtimeV2.id,
        language: String? = nil,
        enablePartials: Bool = true
    ) {
        self.apiKey = apiKey
        self.modelId = modelId
        self.language = language
        self.enablePartials = enablePartials
        (self.transcriptions, self.transcriptionContinuation) = AsyncThrowingStream.makeStream(of: STTTranscription.self)
    }

    deinit {
        disconnect()
    }

    // MARK: - Connection

    /// Connect to the ElevenLabs STT WebSocket API
    public func connect() async throws {
        lock.lock()
        guard !_isConnected else { lock.unlock(); return }
        let factory = webSocketTaskFactory
        lock.unlock()

        var urlComponents = URLComponents()
        urlComponents.scheme = "wss"
        urlComponents.host = "api.elevenlabs.io"
        urlComponents.path = "/v1/speech-to-text/realtime"
        urlComponents.queryItems = [
            URLQueryItem(name: "model_id", value: modelId)
        ]

        if let language = language {
            urlComponents.queryItems?.append(URLQueryItem(name: "language", value: language))
        }

        guard let url = urlComponents.url else {
            throw ElevenLabsSTTError.invalidURL
        }

        var request = URLRequest(url: url)
        request.addValue(apiKey, forHTTPHeaderField: "xi-api-key")

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

        // Send initial configuration
        let config = STTConfig(
            enablePartials: enablePartials,
            language: language
        )
        try await sendMessage(config)

        lock.lock()
        _isConnected = true
        lock.unlock()
        startReceiving()
    }

    /// Disconnect from the WebSocket
    public func disconnect() {
        lock.lock()
        _isConnected = false
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
        transcriptionContinuation.finish()
    }

    // MARK: - Sending Audio

    /// Send audio data for transcription
    public func send(audio: Data) async throws {
        guard isConnected else {
            throw ElevenLabsSTTError.notConnected
        }

        let message = AudioInputMessage(audio: audio.base64EncodedString())
        try await sendMessage(message)
    }

    /// Send end of audio signal
    public func endAudio() async throws {
        guard isConnected else {
            throw ElevenLabsSTTError.notConnected
        }

        let message = EndAudioMessage()
        try await sendMessage(message)
    }

    // MARK: - Private Methods

    private func sendMessage<T: Encodable>(_ message: T) async throws {
        lock.lock()
        let socket = webSocketTask
        lock.unlock()

        let data = try encoder.encode(message)
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw ElevenLabsSTTError.encodingError
        }

        try await socket?.send(.string(jsonString))
    }

    private func startReceiving() {
        let task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isConnected else { return }
                self.lock.lock()
                let socket = self.webSocketTask
                self.lock.unlock()
                guard let socket else { return }

                do {
                    let message = try await socket.receive()

                    switch message {
                    case .string(let text):
                        if let data = text.data(using: .utf8) {
                            self.handleResponse(data)
                        }

                    case .data(let data):
                        self.handleResponse(data)

                    @unknown default:
                        break
                    }
                } catch {
                    // A genuine transport-level error (socket closed, etc.) —
                    // this is fatal, unlike a single malformed message below.
                    if !Task.isCancelled {
                        self.transcriptionContinuation.finish(throwing: error)
                    }
                    break
                }
            }
        }
        lock.lock()
        receiveTask = task
        lock.unlock()
    }

    private func handleResponse(_ data: Data) {
        let response: STTResponse
        do {
            response = try decoder.decode(STTResponse.self, from: data)
        } catch {
            // A single malformed/unrecognized message should not kill the
            // whole session — surface it for observability and keep going.
            onDecodeError?(error)
            return
        }

        switch response.type {
        case "transcript":
            if let transcript = response.transcript {
                let result = STTTranscription(
                    text: transcript.text,
                    isFinal: transcript.isFinal,
                    confidence: transcript.confidence,
                    words: transcript.words?.map { word in
                        STTTranscription.Word(
                            word: word.word,
                            start: word.start,
                            end: word.end,
                            confidence: word.confidence
                        )
                    },
                    language: transcript.language
                )
                transcriptionContinuation.yield(result)
            }

        case "error":
            if let error = response.error {
                transcriptionContinuation.finish(throwing: ElevenLabsSTTError.serverError(error.message))
            }

        case "done":
            transcriptionContinuation.finish()

        default:
            break
        }
    }
}

// MARK: - STT Messages

private struct STTConfig: Encodable {
    let type: String = "config"
    let enablePartials: Bool
    let language: String?

    enum CodingKeys: String, CodingKey {
        case type
        case enablePartials = "enable_partials"
        case language
    }
}

private struct AudioInputMessage: Encodable {
    let type: String = "input_audio_chunk"
    let audio: String // Base64 encoded
}

private struct EndAudioMessage: Encodable {
    let type: String = "end_of_audio"
}

// MARK: - STT Response

private struct STTResponse: Decodable {
    let type: String
    let transcript: Transcript?
    let error: ErrorDetail?

    struct Transcript: Decodable {
        let text: String
        let isFinal: Bool
        let confidence: Double?
        let words: [Word]?
        let language: String?

        struct Word: Decodable {
            let word: String
            let start: TimeInterval
            let end: TimeInterval
            let confidence: Double?
        }

        enum CodingKeys: String, CodingKey {
            case text, confidence, words, language
            case isFinal = "is_final"
        }
    }

    struct ErrorDetail: Decodable {
        let code: String?
        let message: String
    }
}

// MARK: - STT Transcription Result

/// A transcription result from the STT stream
public struct STTTranscription: Sendable {
    /// Transcribed text
    public let text: String

    /// Whether this is a final transcription
    public let isFinal: Bool

    /// Confidence score (0-1)
    public let confidence: Double?

    /// Word-level timing information
    public let words: [Word]?

    /// Detected language
    public let language: String?

    /// Word timing information
    public struct Word: Sendable {
        public let word: String
        public let start: TimeInterval
        public let end: TimeInterval
        public let confidence: Double?
    }
}

// MARK: - Errors

public enum ElevenLabsSTTError: Error, LocalizedError {
    case invalidURL
    case notConnected
    case encodingError
    case decodingError
    case connectionFailed(Error)
    case serverError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid WebSocket URL"
        case .notConnected:
            return "Not connected to the WebSocket"
        case .encodingError:
            return "Failed to encode message"
        case .decodingError:
            return "Failed to decode response"
        case .connectionFailed(let error):
            return "Connection failed: \(error.localizedDescription)"
        case .serverError(let message):
            return "Server error: \(message)"
        }
    }
}
