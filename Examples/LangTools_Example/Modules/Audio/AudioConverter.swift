//
//  AudioConverter.swift
//  LangTools_Example
//
//  Created by Reid Chatham on 12/3/24.
//

import AVFoundation

/// Utility for converting audio formats for speech recognition providers
///
/// This converter handles transforming audio between different formats,
/// particularly converting CAF (Core Audio Format) to WAV format which
/// is widely supported by speech recognition APIs.
///
/// Example usage:
/// ```swift
/// let cafData = audioRecorder.stopRecording()
/// let wavData = try AudioConverter.convertToWAV(cafData: cafData)
/// // Use wavData with OpenAI Whisper, Apple Speech, etc.
/// ```
public struct AudioConverter {

    public enum AudioConverterError: Error, LocalizedError {
        case conversionFailed(String)
        case fileReadFailed(String)
        case fileWriteFailed(String)

        public var errorDescription: String? {
            switch self {
            case .conversionFailed(let message):
                return "Audio conversion failed: \(message)"
            case .fileReadFailed(let message):
                return "Failed to read audio file: \(message)"
            case .fileWriteFailed(let message):
                return "Failed to write audio file: \(message)"
            }
        }
    }

    /// Convert CAF audio data to WAV format for speech recognition
    /// - Parameter cafData: Raw audio data in CAF format
    /// - Returns: Audio data in WAV format
    /// - Throws: AudioConverterError if conversion fails
    public static func convertToWAV(cafData: Data) throws -> Data {
        let tempCAF = FileManager.default.temporaryDirectory
            .appendingPathComponent("convert_\(UUID().uuidString).caf")
        let tempWAV = FileManager.default.temporaryDirectory
            .appendingPathComponent("convert_\(UUID().uuidString).wav")

        defer {
            try? FileManager.default.removeItem(at: tempCAF)
            try? FileManager.default.removeItem(at: tempWAV)
        }

        // Write CAF data to temp file
        do {
            try cafData.write(to: tempCAF)
            print("[AudioConverter] Wrote CAF file: \(cafData.count) bytes")
        } catch {
            throw AudioConverterError.fileWriteFailed(error.localizedDescription)
        }

        // Read the CAF file
        let inputFile: AVAudioFile
        do {
            inputFile = try AVAudioFile(forReading: tempCAF)
            print("[AudioConverter] Input: \(inputFile.processingFormat.sampleRate)Hz, \(inputFile.processingFormat.channelCount)ch, \(inputFile.length) frames")
        } catch {
            throw AudioConverterError.fileReadFailed(error.localizedDescription)
        }

        // Read all audio into buffer
        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFile.processingFormat,
            frameCapacity: AVAudioFrameCount(inputFile.length)
        ) else {
            throw AudioConverterError.conversionFailed("Could not create input buffer")
        }

        do {
            try inputFile.read(into: inputBuffer)
            print("[AudioConverter] Read \(inputBuffer.frameLength) frames")
        } catch {
            throw AudioConverterError.fileReadFailed(error.localizedDescription)
        }

        // Create WAV output file with the SAME format as input
        // Speech APIs (OpenAI, Apple Speech, WhisperKit) can handle various formats
        // The key is just to have a valid WAV file
        let wavSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: inputFile.processingFormat.sampleRate,
            AVNumberOfChannelsKey: inputFile.processingFormat.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: inputFile.processingFormat.isInterleaved ? false : true
        ]

        do {
            let outputFile = try AVAudioFile(forWriting: tempWAV, settings: wavSettings, commonFormat: inputFile.processingFormat.commonFormat, interleaved: inputFile.processingFormat.isInterleaved)
            try outputFile.write(from: inputBuffer)
            print("[AudioConverter] Wrote WAV file")
        } catch {
            print("[AudioConverter] Direct write failed: \(error)")

            // Fallback: Try with simpler settings
            do {
                let simpleSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: inputFile.processingFormat.sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false
                ]
                let outputFile = try AVAudioFile(forWriting: tempWAV, settings: simpleSettings)
                try outputFile.write(from: inputBuffer)
                print("[AudioConverter] Wrote WAV with simple settings")
            } catch {
                throw AudioConverterError.fileWriteFailed("Could not write WAV: \(error.localizedDescription)")
            }
        }

        // Read the WAV file
        do {
            let wavData = try Data(contentsOf: tempWAV)
            print("[AudioConverter] Output WAV: \(wavData.count) bytes")
            return wavData
        } catch {
            throw AudioConverterError.fileReadFailed("Could not read WAV file: \(error.localizedDescription)")
        }
    }

    /// Convert CAF audio data to WAV and save to a file URL
    /// - Parameters:
    ///   - cafData: Raw audio data in CAF format
    ///   - outputURL: URL where the WAV file should be saved
    /// - Throws: AudioConverterError if conversion fails
    public static func convertToWAV(cafData: Data, outputURL: URL) throws {
        let wavData = try convertToWAV(cafData: cafData)
        try wavData.write(to: outputURL)
    }
}
