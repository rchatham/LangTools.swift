//
//  RealtimeSessionViewModel.swift
//  LangTools_Example
//
//  Drives the realtime voice interface: owns the OpenAI Realtime session,
//  streams mic audio up, plays response audio back, shows live transcripts,
//  and handles barge-in interruption via server VAD events.
//

import Foundation
import SwiftUI
import OpenAI
import LangTools

@MainActor
public final class RealtimeSessionViewModel: ObservableObject {

    // MARK: - UI State

    public enum ConnectionState: String {
        case disconnected = "Disconnected"
        case connecting = "Connecting…"
        case connected = "Connected"
        case error = "Error"
    }

    public struct TranscriptEntry: Identifiable, Equatable {
        public enum Role { case user, assistant }
        public let id: String
        public let role: Role
        public var text: String
        public var isFinal: Bool
    }

    @Published public private(set) var connectionState: ConnectionState = .disconnected
    @Published public private(set) var transcript: [TranscriptEntry] = []
    @Published public private(set) var isModelSpeaking = false
    @Published public private(set) var isUserSpeaking = false
    @Published public private(set) var lastError: String?
    @Published public var textInput: String = ""

    public let mic = RealtimeMicStreamer()
    public let player = RealtimePCMPlayer()

    // MARK: - Session

    private let apiKeyProvider: () -> String?
    private var session: OpenAIRealtimeSession?
    private var eventTask: Task<Void, Never>?

    /// Chain of pending audio-chunk sends, so each `append(audio:)` call
    /// waits for the previous one to finish before starting. Without this,
    /// each ~100ms mic chunk spawns its own unstructured Task, and nothing
    /// stops two of them from calling into the WebSocket's `send` at once —
    /// `URLSessionWebSocketTask.send` isn't documented as safe to call
    /// concurrently, so overlapping sends could interleave or corrupt the
    /// audio stream the API receives.
    private var audioSendChain: Task<Void, Never> = Task {}

    /// Tracks the current assistant audio item for truncation on barge-in
    private var currentAssistantItemId: String?

    public init(apiKeyProvider: @escaping () -> String?) {
        self.apiKeyProvider = apiKeyProvider
    }

    // MARK: - Lifecycle

    public func connect() async {
        guard connectionState == .disconnected || connectionState == .error else { return }
        lastError = nil

        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
            lastError = "No OpenAI API key configured. Add one in Settings."
            connectionState = .error
            return
        }

        guard await mic.requestPermission() else {
            lastError = "Microphone permission denied."
            connectionState = .error
            return
        }

        connectionState = .connecting

        let session = OpenAIRealtimeSession(apiKey: apiKey)
        self.session = session

        do {
            try await session.connect()
            try await session.updateSession(configuration: RealtimeSessionConfiguration(
                modalities: [.text, .audio],
                instructions: "You are a helpful, concise voice assistant.",
                voice: "alloy",
                inputAudioFormat: .pcm16,
                outputAudioFormat: .pcm16,
                inputAudioTranscription: .init(model: "whisper-1"),
                turnDetection: .init(
                    type: .serverVad,
                    threshold: 0.5,
                    prefixPaddingMs: 300,
                    silenceDurationMs: 500,
                    createResponse: true,
                    interruptResponse: true
                )
            ))

            consumeEvents(from: session)

            mic.onAudioChunk = { [weak self] data in
                // Fires on the audio engine's real-time thread — hop to the
                // main actor (where audioSendChain lives) before chaining.
                Task { @MainActor [weak self] in
                    self?.enqueueAudioSend(data)
                }
            }
            // Start the mic first: on iOS it sets the shared audio session to
            // .playAndRecord/.voiceChat, and changing the category under an
            // already-running playback engine can stall or re-route it.
            try mic.start()
            try player.start()

            connectionState = .connected
        } catch {
            lastError = error.localizedDescription
            connectionState = .error
            await teardown()
        }
    }

    public func disconnect() async {
        await teardown()
        connectionState = .disconnected
    }

    private func teardown() async {
        mic.stop()
        player.stop()
        eventTask?.cancel()
        eventTask = nil
        // Clear `session` before awaiting disconnect so audio chunks still
        // queued in audioSendChain see it's gone and drop out instead of
        // racing the disconnect.
        let closingSession = session
        session = nil
        await closingSession?.disconnect()
        isModelSpeaking = false
        isUserSpeaking = false
    }

    /// Append `data` to the current session's audio buffer after any
    /// already-queued chunk finishes sending, so chunks reach the socket in
    /// order and never overlap. Must run on the main actor (see
    /// `audioSendChain`'s doc comment).
    private func enqueueAudioSend(_ data: Data) {
        guard let session else { return }
        let previous = audioSendChain
        audioSendChain = Task { [weak self] in
            _ = await previous.value
            // Skip chunks for a session that was torn down while queued.
            guard self?.session === session else { return }
            try? await session.append(audio: data)
        }
    }

    // MARK: - Actions

    /// Send a typed text message into the conversation and request a response.
    public func sendTextMessage() async {
        let text = textInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let session else { return }
        textInput = ""

        transcript.append(TranscriptEntry(id: UUID().uuidString, role: .user, text: text, isFinal: true))
        do {
            try await session.sendMessage(text)
            try await session.createResponse()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Manually interrupt the assistant (the UI stop button; server VAD also
    /// interrupts automatically on speech).
    public func interrupt() async {
        guard let session else { return }
        let truncation = stopPlayback()
        do {
            try await session.cancelResponse()
        } catch {
            // Cancelling with no active response is fine — ignore
        }
        if let truncation {
            try? await session.truncateItem(itemId: truncation.itemId, contentIndex: 0, audioEndMs: truncation.audioEndMs)
        }
    }

    /// Stops local playback and returns where to truncate the assistant
    /// item: the audio the user actually heard, not everything received.
    /// Reads the position before flushing, since flush() resets it.
    private func stopPlayback() -> (itemId: String, audioEndMs: Int)? {
        let playedMs = player.playedMilliseconds
        player.flush()
        isModelSpeaking = false
        return currentAssistantItemId.map { ($0, playedMs) }
    }

    // MARK: - Event Handling

    private func consumeEvents(from session: OpenAIRealtimeSession) {
        // Task inherits @MainActor isolation from this class, so handle(_:)
        // and state mutations below run on the main actor.
        eventTask = Task { [weak self] in
            do {
                for try await event in session.events {
                    guard let self else { return }
                    self.handle(event)
                }
            } catch {
                guard let self, self.connectionState == .connected else { return }
                self.lastError = error.localizedDescription
                self.connectionState = .error
            }
        }
    }

    private func handle(_ event: OpenAIRealtimeServerEvent) {
        switch event {
        case .inputAudioBufferSpeechStarted:
            isUserSpeaking = true
            // Barge-in: the server detected user speech — stop local playback
            // immediately so the user isn't talking over stale audio. The
            // server cancels the response itself (interrupt_response), but
            // only the client knows how much was played, so truncate the
            // item there to keep the conversation in line with what was heard.
            if isModelSpeaking, let truncation = stopPlayback(), let session {
                Task {
                    try? await session.truncateItem(itemId: truncation.itemId, contentIndex: 0, audioEndMs: truncation.audioEndMs)
                }
            }

        case .inputAudioBufferSpeechStopped:
            isUserSpeaking = false

        case .conversationItemInputAudioTranscriptionCompleted(let e):
            upsertTranscript(id: e.itemId, role: .user, text: e.transcript, isFinal: true)

        case .responseOutputItemAdded(let e):
            currentAssistantItemId = e.item.id
            player.resetPlaybackPosition()

        case .responseAudioTranscriptDelta(let e):
            appendDelta(id: e.itemId, role: .assistant, delta: e.delta)

        case .responseAudioTranscriptDone(let e):
            upsertTranscript(id: e.itemId, role: .assistant, text: e.transcript, isFinal: true)

        case .responseTextDelta(let e):
            appendDelta(id: e.itemId, role: .assistant, delta: e.delta)

        case .responseTextDone(let e):
            upsertTranscript(id: e.itemId, role: .assistant, text: e.text, isFinal: true)

        case .responseAudioDelta(let e):
            if let audio = e.audioData {
                isModelSpeaking = true
                player.enqueue(pcm16: audio)
            }

        case .responseAudioDone:
            break

        case .responseDone:
            isModelSpeaking = false

        case .error(let e):
            lastError = e.error.message

        default:
            break
        }
    }

    private func appendDelta(id: String, role: TranscriptEntry.Role, delta: String) {
        if let index = transcript.firstIndex(where: { $0.id == id }) {
            transcript[index].text += delta
        } else {
            transcript.append(TranscriptEntry(id: id, role: role, text: delta, isFinal: false))
        }
    }

    private func upsertTranscript(id: String, role: TranscriptEntry.Role, text: String, isFinal: Bool) {
        if let index = transcript.firstIndex(where: { $0.id == id }) {
            transcript[index].text = text
            transcript[index].isFinal = isFinal
        } else {
            transcript.append(TranscriptEntry(id: id, role: role, text: text, isFinal: isFinal))
        }
    }
}
