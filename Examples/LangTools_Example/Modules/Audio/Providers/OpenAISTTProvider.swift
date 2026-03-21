//
//  OpenAISTTProvider.swift
//  Audio
//
//  OpenAI Whisper-based speech-to-text provider
//

import Foundation
import OpenAI
import LangTools
import Chat

/// OpenAI Whisper-based speech-to-text provider
public class OpenAISTTProvider: STTProviderProtocol {
    public let name = "OpenAI Whisper"

    private var openAI: OpenAI?

    public init() {
        // Load API key from Keychain
        if let apiKey = KeychainService.shared.getApiKey(for: .openAI) {
            openAI = OpenAI(apiKey: apiKey)
        }
    }

    public var isAvailable: Bool {
        openAI != nil
    }

    public func requestPermission() async throws -> Bool {
        // OpenAI doesn't need device permissions, just API key
        guard isAvailable else {
            throw STTError.providerNotConfigured
        }
        return true
    }

    public func transcribe(audioData: Data) async throws -> String {
        // Try to refresh API key if not available
        if openAI == nil {
            refreshApiKey()
        }

        guard let openAI = openAI else {
            print("[OpenAI] Provider not configured - missing API key")
            throw STTError.providerNotConfigured
        }

        print("[OpenAI] Received audio data: \(audioData.count) bytes")

        // Convert CAF audio to WAV format (16kHz mono) for Whisper API
        let wavData: Data
        do {
            wavData = try AudioConverter.convertToWAV(cafData: audioData)
            print("[OpenAI] Converted to WAV: \(wavData.count) bytes")
        } catch {
            print("[OpenAI] Audio conversion failed: \(error)")
            throw STTError.transcriptionFailed("Audio conversion failed: \(error.localizedDescription)")
        }

        // Get language setting ("auto" means nil for auto-detection)
        let languageSetting = ToolSettings.shared.sttLanguage.rawValue
        let language: String? = languageSetting == "auto" ? nil : languageSetting

        // Create transcription request with WAV format
        let request = OpenAI.AudioTranscriptionRequest(
            file: wavData,
            fileType: .wav,
            language: language,
            responseFormat: .json
        )

        print("[OpenAI] Sending request to Whisper API...")

        // Perform the request
        do {
            let response = try await openAI.perform(request: request)
            print("[OpenAI] Transcription successful: '\(response.text)'")
            return response.text
        } catch {
            print("[OpenAI] API error: \(error)")
            print("[OpenAI] Error type: \(type(of: error))")
            if let urlError = error as? URLError {
                print("[OpenAI] URLError code: \(urlError.code.rawValue)")
            }
            throw STTError.transcriptionFailed("OpenAI API error: \(error.localizedDescription)")
        }
    }

    /// Update the API key (called when user updates settings)
    public func updateApiKey(_ apiKey: String) {
        openAI = OpenAI(apiKey: apiKey)
    }

    /// Refresh API key from Keychain
    public func refreshApiKey() {
        let service: APIService = .openAI
        print("[OpenAI STT] Refreshing API key from keychain...")
        print("[OpenAI STT] Looking up key for service: \(service), rawValue: '\(service.rawValue)'")
        if let apiKey = KeychainService.shared.getApiKey(for: service) {
            print("[OpenAI STT] Found API key (length: \(apiKey.count))")
            openAI = OpenAI(apiKey: apiKey)
        } else {
            print("[OpenAI STT] No API key found in keychain for '\(service.rawValue):apiKey'")
            openAI = nil
        }
    }
}
