//
//  AudioPlayer.swift
//  LangTools_Example
//
//  Audio playback utility for playing synthesized speech or recorded audio
//

import AVFoundation

/// A simple audio player for playing audio data (MP3, WAV, etc.)
///
/// Example usage:
/// ```swift
/// let player = AudioPlayer.shared
/// try player.play(data: audioData)
///
/// // Control playback
/// player.pause()
/// player.resume()
/// player.setVolume(0.8)
/// ```
public class AudioPlayer {

    public static let shared = AudioPlayer()

    private var audioPlayer: AVAudioPlayer?

    public enum AudioPlayerError: Error, LocalizedError {
        case invalidData
        case playerSetupFailed
        case playerNotReady
        case platformNotSupported

        public var errorDescription: String? {
            switch self {
            case .invalidData:
                return "Invalid audio data"
            case .playerSetupFailed:
                return "Failed to set up audio player"
            case .playerNotReady:
                return "Audio player not ready"
            case .platformNotSupported:
                return "Audio playback not supported on this platform"
            }
        }
    }

    public init() {}

    /// Initialize and play audio from Data object
    /// - Parameter data: Data object containing audio (MP3, WAV, etc.)
    /// - Throws: AudioPlayerError if initialization fails
    public func play(data: Data) throws {
        do {
            // Create audio player from data
            audioPlayer = try AVAudioPlayer(data: data)

            #if os(iOS)
            // Configure audio session for iOS
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            #endif

            guard let player = audioPlayer else {
                throw AudioPlayerError.playerNotReady
            }

            // Prepare and play
            player.prepareToPlay()
            player.play()

        } catch {
            throw AudioPlayerError.playerSetupFailed
        }
    }

    /// Pause playback
    public func pause() {
        audioPlayer?.pause()
    }

    /// Resume playback
    public func resume() {
        audioPlayer?.play()
    }

    /// Stop playback
    public func stop() {
        audioPlayer?.stop()
        audioPlayer = nil
    }

    /// Get current playback time in seconds
    public var currentTime: TimeInterval {
        return audioPlayer?.currentTime ?? 0
    }

    /// Get total duration in seconds
    public var duration: TimeInterval {
        return audioPlayer?.duration ?? 0
    }

    /// Check if audio is currently playing
    public var isPlaying: Bool {
        return audioPlayer?.isPlaying ?? false
    }

    /// Set playback volume (0.0 to 1.0)
    public func setVolume(_ volume: Float) {
        audioPlayer?.volume = max(0.0, min(1.0, volume))
    }

    /// Get current playback volume (0.0 to 1.0)
    public var volume: Float {
        return audioPlayer?.volume ?? 1.0
    }

    /// Seek to specific time in seconds
    public func seek(to time: TimeInterval) {
        audioPlayer?.currentTime = max(0, min(time, duration))
    }
}
