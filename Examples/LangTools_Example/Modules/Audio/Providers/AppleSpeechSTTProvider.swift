//
//  AppleSpeechSTTProvider.swift
//  Audio
//
//  Example-app Apple Speech Framework speech-to-text adapter
//

import AppleLangTools
import Foundation
import LangTools
import Speech

public typealias AppleSpeechSTTProvider = AppleLangTools.AppleSpeechRecognitionProvider

extension AppleSpeechSTTProvider: SpeechRecognitionProvider {
    public var providerType: STTProviderType { .appleSpeech }

    public func requestPermission() async throws -> Bool {
        let state = await requestAuthorization()
        guard state == .authorized else { throw STTError.permissionDenied }
        return true
    }
}
