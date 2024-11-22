import AVFoundation

class AudioPlayer {

    static let shared = AudioPlayer()

    private var audioPlayer: AVAudioPlayer?

    enum AudioPlayerError: Error {
        case invalidData
        case playerSetupFailed
        case playerNotReady
    }

    /// Initialize and play audio from Data object
    /// - Parameter data: Data object containing MP3 audio
    /// - Throws: AudioPlayerError if initialization fails
    func play(data: Data) throws {
        do {
            // Create audio player from data
            audioPlayer = try AVAudioPlayer(data: data)

            // Configure audio session
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)

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
    func pause() {
        audioPlayer?.pause()
    }

    /// Resume playback
    func resume() {
        audioPlayer?.play()
    }

    /// Stop playback
    func stop() {
        audioPlayer?.stop()
        audioPlayer = nil
    }

    /// Get current playback time in seconds
    var currentTime: TimeInterval {
        return audioPlayer?.currentTime ?? 0
    }

    /// Get total duration in seconds
    var duration: TimeInterval {
        return audioPlayer?.duration ?? 0
    }

    /// Check if audio is currently playing
    var isPlaying: Bool {
        return audioPlayer?.isPlaying ?? false
    }

    /// Set playback volume (0.0 to 1.0)
    func setVolume(_ volume: Float) {
        audioPlayer?.volume = max(0.0, min(1.0, volume))
    }

    /// Seek to specific time in seconds
    func seek(to time: TimeInterval) {
        audioPlayer?.currentTime = max(0, min(time, duration))
    }
}
