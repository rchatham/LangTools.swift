//
//  WhisperKitSTTProvider.swift
//  Audio
//
//  Example-app WhisperKit speech-to-text adapter
//

import Combine
import Foundation
import LangTools

#if canImport(WhisperKitLangTools) && canImport(AVFoundation) && !os(watchOS)
import AVFoundation
import WhisperKitLangTools

public typealias WhisperKitLoadingState = WhisperKitLangTools.WhisperKitLoadingState
public typealias WhisperKitSTTProvider = WhisperKitSpeechRecognitionProvider

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
#else
public enum WhisperKitLoadingState: Equatable, Sendable {
    case idle
    case downloading
    case loading
    case ready
    case failed(String)

    public var isLoading: Bool {
        switch self {
        case .downloading, .loading: return true
        case .idle, .ready, .failed: return false
        }
    }

    public var description: String {
        switch self {
        case .idle: return "Idle"
        case .downloading: return "Downloading model"
        case .loading: return "Loading model"
        case .ready: return "Ready"
        case .failed(let message): return "Failed: \(message)"
        }
    }
}
#endif
