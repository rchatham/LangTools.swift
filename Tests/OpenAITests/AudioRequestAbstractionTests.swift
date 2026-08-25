import XCTest
import LangTools
@testable import OpenAI

final class AudioRequestAbstractionTests: XCTestCase {
    func testAudioSpeechRequestExposesGenericTTSShape() {
        let request = OpenAI.AudioSpeechRequest(
            model: .tts_1,
            input: "Hello",
            voice: .alloy,
            responseFormat: .mp3,
            speed: 1.25
        )

        let genericRequest: any LangToolsTTSRequest = request
        XCTAssertEqual(genericRequest.speechText, "Hello")
        XCTAssertEqual(genericRequest.speechVoiceIdentifier, "alloy")
        XCTAssertEqual(genericRequest.speechSpeed, 1.25)
        XCTAssertEqual(genericRequest.speechResponseFormat, "mp3")
    }

    func testAudioTranscriptionRequestExposesGenericSTTShape() {
        let audio = Data([0x01, 0x02])
        let request = OpenAI.AudioTranscriptionRequest(
            file: audio,
            fileType: .wav,
            prompt: "names: Hermes",
            language: "en"
        )

        let genericRequest: any LangToolsSTTRequest = request
        XCTAssertEqual(genericRequest.speechAudioData, audio)
        XCTAssertNil(genericRequest.speechAudioFileURL)
        XCTAssertEqual(genericRequest.speechAudioFormat, "wav")
        XCTAssertEqual(genericRequest.speechLanguageIdentifier, "en")
        XCTAssertEqual(genericRequest.speechPrompt, "names: Hermes")
    }

    func testAudioTranscriptionResponseExposesGenericText() {
        let response = OpenAI.AudioTranscriptionRequest.AudioTranscriptionResponse(
            task: "transcribe",
            language: "en",
            duration: 1.0,
            text: "Hello",
            words: nil,
            segments: nil
        )

        let genericResponse: any LangToolsTranscriptionResponse = response
        XCTAssertEqual(genericResponse.transcriptText, "Hello")
        XCTAssertEqual(genericResponse.detectedLanguageIdentifier, "en")
    }

    @MainActor
    func testOpenAISpeechRecognitionProviderExposesReusableSpeechRecognitionProvider() {
        let provider = OpenAISpeechRecognitionProvider(openAI: OpenAI(apiKey: "test"), defaultFileType: .mp3)

        XCTAssertTrue(provider.isAvailable)
        XCTAssertEqual(provider.providerID.rawValue, "openai.whisper")
        XCTAssertFalse(provider.capabilities.runsOnDevice)
        XCTAssertFalse(provider.capabilities.supportsStreamingPartials)
    }

    @MainActor
    func testOpenAISpeechRecognitionProviderDoesNotRequireAVFoundationConversion() {
        let provider = OpenAISpeechRecognitionProvider(defaultFileType: .mp3)

        provider.updateDefaultFileType(.m4a)
        provider.configure(languageIdentifier: "auto")

        XCTAssertFalse(provider.isAvailable)
        XCTAssertEqual(provider.authorizationState, .unavailable(reason: "Missing OpenAI client"))
    }

    @MainActor
    func testOpenAISpeechRecognitionProviderPreservesInjectedClientWhenRefreshing() {
        let provider = OpenAISpeechRecognitionProvider(openAI: OpenAI(apiKey: "test"))

        provider.refreshApiKey()
        provider.refreshAuthorizationState()

        XCTAssertTrue(provider.isAvailable)
        XCTAssertEqual(provider.authorizationState, .authorized)
    }

    @MainActor
    func testOpenAISpeechRecognitionProviderPreservesUpdatedClientWhenRefreshing() {
        let provider = OpenAISpeechRecognitionProvider()

        provider.updateOpenAI(OpenAI(apiKey: "test"))
        provider.refreshApiKey()
        provider.refreshAuthorizationState()

        XCTAssertTrue(provider.isAvailable)
        XCTAssertEqual(provider.authorizationState, .authorized)
    }

    @MainActor
    func testOpenAISpeechRecognitionProviderConformsToStreamingProvider() async throws {
        let provider = OpenAISpeechRecognitionProvider(openAI: OpenAI(apiKey: "test"))
        let streamingProvider: any StreamingSpeechRecognitionProviding = provider

        var events: [SpeechRecognitionEvent] = []
        XCTAssertTrue(streamingProvider.supportsExternalAudioStreaming)
        try await streamingProvider.startStreamingRecognition { event in
            events.append(event)
        }
        let result = await streamingProvider.stopStreamingRecognition()

        XCTAssertNil(result)
        XCTAssertTrue(events.isEmpty)
        XCTAssertFalse(streamingProvider.isStreaming)
    }

    @MainActor
    func testOpenAIStreamingAppendRequiresStartedSession() async {
        let provider = OpenAISpeechRecognitionProvider(openAI: OpenAI(apiKey: "test"))
        let streamingProvider: any StreamingSpeechRecognitionProviding = provider

        do {
            try await streamingProvider.appendStreamingAudio(Data([1]))
            XCTFail("Expected OpenAI streaming audio append to require an active session")
        } catch let error as StreamingSpeechRecognitionError {
            XCTAssertEqual(error, .notStreaming)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testOpenAIStreamingRequiresConfiguredClient() async {
        let provider = OpenAISpeechRecognitionProvider()
        let streamingProvider: any StreamingSpeechRecognitionProviding = provider

        do {
            try await streamingProvider.startStreamingRecognition { _ in }
            XCTFail("Expected OpenAI streaming to require a configured client")
        } catch let error as OpenAISpeechProviderError {
            XCTAssertEqual(error.localizedDescription, OpenAISpeechProviderError.providerNotConfigured.localizedDescription)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testSpeechSynthesisProviderUsesExplicitVoiceOverNeutralVoiceIdentifier() async throws {
        let request = makeSpeechSynthesisProvider().audioSpeechRequest(
            for: LangToolsSpeechSynthesisInput(text: "Hello", languageIdentifier: "en", voiceIdentifier: "nova"),
            voice: .echo
        )

        XCTAssertEqual(request.voice, .echo)
    }

    @MainActor
    func testSpeechSynthesisProviderFallsBackToNeutralVoiceIdentifier() async throws {
        let request = makeSpeechSynthesisProvider().audioSpeechRequest(
            for: LangToolsSpeechSynthesisInput(text: "Hello", languageIdentifier: "en", voiceIdentifier: "nova")
        )

        XCTAssertEqual(request.voice, .nova)
    }

    @MainActor
    func testSpeechSynthesisProviderFallsBackToAlloyForInvalidOrMissingNeutralVoiceIdentifier() async throws {
        let invalidVoiceRequest = makeSpeechSynthesisProvider().audioSpeechRequest(
            for: LangToolsSpeechSynthesisInput(text: "Hello", languageIdentifier: "en", voiceIdentifier: "invalid")
        )
        let missingVoiceRequest = makeSpeechSynthesisProvider().audioSpeechRequest(
            for: LangToolsSpeechSynthesisInput(text: "Hello", languageIdentifier: "en")
        )

        XCTAssertEqual(invalidVoiceRequest.voice, .alloy)
        XCTAssertEqual(missingVoiceRequest.voice, .alloy)
    }

    @MainActor
    private func makeSpeechSynthesisProvider() -> OpenAISpeechSynthesisProvider {
        OpenAISpeechSynthesisProvider(openAI: OpenAI(apiKey: "test"))
    }
}
