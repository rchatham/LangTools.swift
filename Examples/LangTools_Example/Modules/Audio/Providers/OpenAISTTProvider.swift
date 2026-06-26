//
//  OpenAISTTProvider.swift
//  Audio
//
//  Example-app OpenAI Whisper speech-to-text adapter
//

import Foundation
import LangTools
import OpenAI
import class OpenAI.OpenAISTTProvider

extension OpenAISTTProvider: SpeechRecognitionProvider {
    public var providerType: STTProviderType { .openAIWhisper }

    public func requestPermission() async throws -> Bool {
        guard isAvailable else { throw STTError.providerNotConfigured }
        return true
    }
}
