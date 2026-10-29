//
//  SpeechService.swift
//  LangToolsCLI
//
//  Reads assistant replies aloud for /voice.
//

import Foundation
import OpenAI

/// Speaks text using OpenAI text-to-speech when an OpenAI API key is set,
/// falling back to the macOS `say` command otherwise.
///
/// Only one reply plays at a time: starting a new one, or calling `stop()`,
/// cancels whatever is still playing.
actor SpeechService {
    static let shared = SpeechService()

    /// OpenAI's speech endpoint rejects inputs longer than this.
    static let maxInputLength = 4096

    enum SpeechError: LocalizedError {
        case playbackFailed(String)

        var errorDescription: String? {
            switch self {
            case .playbackFailed(let detail): return "Audio playback failed: \(detail)"
            }
        }
    }

    private var playback: Task<Void, Never>?

    /// Start speaking `text` without waiting for it to finish.
    nonisolated func speakInBackground(_ text: String, onError: (@Sendable (Error) -> Void)? = nil) {
        Task { await self.start(text, onError: onError) }
    }

    func stop() {
        playback?.cancel()
        playback = nil
    }

    private func start(_ text: String, onError: (@Sendable (Error) -> Void)?) {
        playback?.cancel()
        let spoken = Self.speakableText(from: text)
        guard !spoken.isEmpty else { return }
        playback = Task {
            do {
                try await Self.speak(spoken)
            } catch is CancellationError {
                // Interrupted by a newer reply or /voice off.
            } catch {
                onError?(error)
            }
        }
    }

    private static func speak(_ text: String) async throws {
        if UserDefaults.getApiKey(for: .openAI) != nil {
            try await speakWithOpenAI(text)
        } else {
            try await run("/usr/bin/say", arguments: [text])
        }
    }

    private static func speakWithOpenAI(_ text: String) async throws {
        let request = OpenAI.AudioSpeechRequest(model: .tts_1, input: text, voice: .alloy, responseFormat: .mp3, speed: 1.0)
        let audio = try await langToolchain.perform(request: request)
        try Task.checkCancellation()

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("langtools-voice-\(UUID().uuidString).mp3")
        try audio.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try await run("/usr/bin/afplay", arguments: [file.path])
    }

    private static func run(_ executable: String, arguments: [String]) async throws {
        let result = try await ProcessService.execute(executable: executable, arguments: arguments, timeout: 600)
        try Task.checkCancellation()
        if result.exitCode != 0 {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SpeechError.playbackFailed(detail.isEmpty ? "\(executable) exited with \(result.exitCode)" : detail)
        }
    }

    /// Drop fenced code blocks and trim to the TTS input limit.
    static func speakableText(from text: String) -> String {
        var kept: [Substring] = []
        var inCodeBlock = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inCodeBlock.toggle()
                continue
            }
            if !inCodeBlock { kept.append(line) }
        }
        let joined = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return String(joined.prefix(maxInputLength))
    }
}

/// Shared `/voice [on|off|status]` handling for the line-mode CLI and the TUI.
enum VoiceCommand {
    /// Apply the argument and return the message to show the user.
    static func apply(argument: String) -> String {
        switch argument.trimmingCharacters(in: .whitespaces).lowercased() {
        case "":
            return set(!UserDefaults.voiceEnabled)
        case "on":
            return set(true)
        case "off":
            return set(false)
        case "status":
            return statusText
        default:
            return "Usage: /voice [on|off|status]"
        }
    }

    static var statusText: String {
        guard UserDefaults.voiceEnabled else { return "Voice output is off." }
        let engine = UserDefaults.getApiKey(for: .openAI) != nil ? "OpenAI text-to-speech" : "macOS say"
        return "Voice output is on (\(engine))."
    }

    private static func set(_ enabled: Bool) -> String {
        UserDefaults.voiceEnabled = enabled
        if !enabled {
            Task { await SpeechService.shared.stop() }
        }
        return statusText
    }
}
