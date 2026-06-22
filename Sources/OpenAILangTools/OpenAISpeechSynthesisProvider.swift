import Foundation
import LangTools
import OpenAI

/// Reusable OpenAI text-to-speech provider adapter.
@MainActor
public final class OpenAISpeechSynthesisProvider: SpeechSynthesisProviding {
    public let providerID = LangToolsProviderID(rawValue: "openai.tts")
    public let displayName = "OpenAI Text-to-Speech"
    public let capabilities = ProviderCapabilities(
        runsOnDevice: false,
        requiresNetwork: true,
        requiresModelDownload: false
    )

    public private(set) var isSpeaking = false

    private let openAI: OpenAI
    private let model: OpenAI.Model
    private let responseFormat: OpenAI.AudioSpeechRequest.AudioSpeechResponseFormat

    public init(
        openAI: OpenAI,
        model: OpenAI.Model = .tts_1,
        responseFormat: OpenAI.AudioSpeechRequest.AudioSpeechResponseFormat = .mp3
    ) {
        self.openAI = openAI
        self.model = model
        self.responseFormat = responseFormat
    }

    public func speak(_ request: LangToolsSpeechSynthesisInput) throws {
        throw OpenAILangToolsSpeechError.liveRecognitionUnsupported
    }

    public func stopSpeaking() {
        isSpeaking = false
    }

    public func synthesize(
        _ request: LangToolsSpeechSynthesisInput,
        voice: OpenAI.AudioSpeechRequest.AudioSpeechVoice = .alloy
    ) async throws -> any LangToolsAudioResponse {
        let audioRequest = OpenAI.AudioSpeechRequest(
            model: model,
            input: request.text,
            voice: voice,
            responseFormat: responseFormat,
            speed: request.rate
        )
        let audioData: Data = try await openAI.perform(request: audioRequest)
        return audioData
    }
}
