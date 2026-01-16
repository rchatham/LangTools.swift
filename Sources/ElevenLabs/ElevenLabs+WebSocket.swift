//
//  ElevenLabs+WebSocket.swift
//  ElevenLabs
//
//  Created by Reid Chatham on 1/16/26.
//

import Foundation
import LangTools
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - WebSocket TTS Session

extension ElevenLabs {
    /// Create a WebSocket TTS session for real-time text-to-speech
    public func createWebSocketSession(
        voiceId: String,
        modelId: String = ElevenLabsModel.elevenFlashV2_5.id,
        outputFormat: ElevenLabsOutputFormat = .pcm_24000,
        voiceSettings: VoiceSettings? = nil
    ) -> ElevenLabsWebSocketSession {
        return ElevenLabsWebSocketSession(
            apiKey: configuration.apiKey,
            voiceId: voiceId,
            modelId: modelId,
            outputFormat: outputFormat,
            voiceSettings: voiceSettings
        )
    }
}

// MARK: - WebSocket Session

/// ElevenLabs WebSocket session for real-time TTS
public final class ElevenLabsWebSocketSession: @unchecked Sendable {
    // MARK: - Properties

    private let apiKey: String
    private let voiceId: String
    private let modelId: String
    private let outputFormat: ElevenLabsOutputFormat
    private let voiceSettings: VoiceSettings?

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var receiveTask: Task<Void, Never>?

    private var audioContinuation: AsyncThrowingStream<AudioChunk, Error>.Continuation?

    public private(set) var isConnected: Bool = false

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - Audio Stream

    /// Stream of audio chunks from TTS
    public var audioStream: AsyncThrowingStream<AudioChunk, Error> {
        AsyncThrowingStream { continuation in
            self.audioContinuation = continuation
        }
    }

    // MARK: - Initialization

    public init(
        apiKey: String,
        voiceId: String,
        modelId: String = ElevenLabsModel.elevenFlashV2_5.id,
        outputFormat: ElevenLabsOutputFormat = .pcm_24000,
        voiceSettings: VoiceSettings? = nil
    ) {
        self.apiKey = apiKey
        self.voiceId = voiceId
        self.modelId = modelId
        self.outputFormat = outputFormat
        self.voiceSettings = voiceSettings
    }

    deinit {
        disconnect()
    }

    // MARK: - Connection

    /// Connect to the ElevenLabs WebSocket API
    public func connect() async throws {
        guard !isConnected else { return }

        var urlComponents = URLComponents()
        urlComponents.scheme = "wss"
        urlComponents.host = "api.elevenlabs.io"
        urlComponents.path = "/v1/text-to-speech/\(voiceId)/stream-input"
        urlComponents.queryItems = [
            URLQueryItem(name: "model_id", value: modelId),
            URLQueryItem(name: "output_format", value: outputFormat.rawValue)
        ]

        guard let url = urlComponents.url else {
            throw ElevenLabsWebSocketError.invalidURL
        }

        var request = URLRequest(url: url)
        request.addValue(apiKey, forHTTPHeaderField: "xi-api-key")

        let configuration = URLSessionConfiguration.default
        urlSession = URLSession(configuration: configuration)
        webSocketTask = urlSession?.webSocketTask(with: request)

        webSocketTask?.resume()

        // Send initial message with voice settings
        let initialMessage = InitialMessage(
            text: " ", // Required initial space
            voiceSettings: voiceSettings,
            generationConfig: GenerationConfig(chunkLengthSchedule: [120, 160, 250, 290])
        )
        try await sendMessage(initialMessage)

        isConnected = true
        startReceiving()
    }

    /// Disconnect from the WebSocket
    public func disconnect() {
        isConnected = false
        receiveTask?.cancel()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        audioContinuation?.finish()
    }

    // MARK: - Sending Text

    /// Send text to be synthesized
    public func send(text: String, flush: Bool = false) async throws {
        guard isConnected else {
            throw ElevenLabsWebSocketError.notConnected
        }

        let message = TextMessage(text: text, flush: flush)
        try await sendMessage(message)
    }

    /// Flush the buffer and generate remaining audio
    public func flush() async throws {
        try await send(text: "", flush: true)
    }

    /// Send end of stream signal
    public func endStream() async throws {
        guard isConnected else {
            throw ElevenLabsWebSocketError.notConnected
        }

        let message = EndOfStreamMessage()
        try await sendMessage(message)
    }

    // MARK: - Private Methods

    private func sendMessage<T: Encodable>(_ message: T) async throws {
        let data = try encoder.encode(message)
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw ElevenLabsWebSocketError.encodingError
        }

        let wsMessage = URLSessionWebSocketTask.Message.string(jsonString)
        try await webSocketTask?.send(wsMessage)
    }

    private func startReceiving() {
        receiveTask = Task { [weak self] in
            guard let self = self else { return }

            while !Task.isCancelled && self.isConnected {
                do {
                    guard let message = try await self.webSocketTask?.receive() else {
                        continue
                    }

                    switch message {
                    case .string(let text):
                        if let data = text.data(using: .utf8) {
                            try self.handleResponse(data)
                        }

                    case .data(let data):
                        try self.handleResponse(data)

                    @unknown default:
                        break
                    }
                } catch {
                    if !Task.isCancelled {
                        self.audioContinuation?.finish(throwing: error)
                    }
                    break
                }
            }
        }
    }

    private func handleResponse(_ data: Data) throws {
        let response = try decoder.decode(WebSocketResponse.self, from: data)

        if let audio = response.audio, let audioData = Data(base64Encoded: audio) {
            let chunk = AudioChunk(
                audio: audioData,
                isFinal: response.isFinal ?? false,
                normalizedAlignment: response.normalizedAlignment,
                alignment: response.alignment
            )
            audioContinuation?.yield(chunk)
        }

        if response.isFinal == true {
            audioContinuation?.finish()
        }
    }
}

// MARK: - WebSocket Messages

private struct InitialMessage: Encodable {
    let text: String
    let voiceSettings: VoiceSettings?
    let generationConfig: GenerationConfig?

    enum CodingKeys: String, CodingKey {
        case text
        case voiceSettings = "voice_settings"
        case generationConfig = "generation_config"
    }
}

private struct GenerationConfig: Encodable {
    let chunkLengthSchedule: [Int]

    enum CodingKeys: String, CodingKey {
        case chunkLengthSchedule = "chunk_length_schedule"
    }
}

private struct TextMessage: Encodable {
    let text: String
    let flush: Bool?

    init(text: String, flush: Bool = false) {
        self.text = text
        self.flush = flush ? true : nil
    }
}

private struct EndOfStreamMessage: Encodable {
    let text: String = ""
}

// MARK: - WebSocket Response

private struct WebSocketResponse: Decodable {
    let audio: String?
    let isFinal: Bool?
    let normalizedAlignment: Alignment?
    let alignment: Alignment?

    struct Alignment: Decodable {
        let charStartTimesMs: [Int]?
        let charDurationsMs: [Int]?
        let chars: [String]?

        enum CodingKeys: String, CodingKey {
            case charStartTimesMs = "char_start_times_ms"
            case charDurationsMs = "char_durations_ms"
            case chars
        }
    }

    enum CodingKeys: String, CodingKey {
        case audio
        case isFinal = "isFinal"
        case normalizedAlignment = "normalizedAlignment"
        case alignment
    }
}

// MARK: - Audio Chunk

/// A chunk of audio from the WebSocket TTS stream
public struct AudioChunk: Sendable {
    /// Raw audio data
    public let audio: Data

    /// Whether this is the final chunk
    public let isFinal: Bool

    /// Normalized alignment data
    public let normalizedAlignment: AudioAlignment?

    /// Raw alignment data
    public let alignment: AudioAlignment?
}

/// Audio alignment information for synchronization
public struct AudioAlignment: Sendable {
    public let charStartTimesMs: [Int]?
    public let charDurationsMs: [Int]?
    public let chars: [String]?

    init(from response: WebSocketResponse.Alignment?) {
        self.charStartTimesMs = response?.charStartTimesMs
        self.charDurationsMs = response?.charDurationsMs
        self.chars = response?.chars
    }
}

extension AudioChunk {
    init(audio: Data, isFinal: Bool, normalizedAlignment: WebSocketResponse.Alignment?, alignment: WebSocketResponse.Alignment?) {
        self.audio = audio
        self.isFinal = isFinal
        self.normalizedAlignment = normalizedAlignment.map { AudioAlignment(from: $0) }
        self.alignment = alignment.map { AudioAlignment(from: $0) }
    }
}

// MARK: - Errors

public enum ElevenLabsWebSocketError: Error, LocalizedError {
    case invalidURL
    case notConnected
    case encodingError
    case decodingError
    case connectionFailed(Error)

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
        }
    }
}
