//
//  WhisperKitSTTProvider.swift
//  Audio
//
//  Example-app WhisperKit speech-to-text adapter
//

import Combine
import Foundation
import LangTools
import WhisperKitLangTools

public typealias WhisperKitLoadingState = WhisperKitLangTools.WhisperKitLoadingState
public typealias WhisperKitSTTProvider = WhisperKitLangTools.WhisperKitSpeechRecognitionProvider

extension WhisperKitSTTProvider: SpeechRecognitionProvider {
    public var providerType: STTProviderType { .whisperKit }

    public func requestPermission() async throws -> Bool {
        if !isAvailable {
            try await reloadIfNeeded()
        }
        guard isAvailable else { throw STTError.notAvailable }
        return true
    }
}
