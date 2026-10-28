import XCTest
import LangTools

#if canImport(WhisperKit) && canImport(AVFoundation) && !os(watchOS)
@testable import WhisperKitLangTools

@available(macOS 13, iOS 16, *)
final class WhisperKitSpeechRecognitionProviderTests: XCTestCase {
    @MainActor
    func testConfigureAutoClearsLanguageIdentifier() {
        let provider = WhisperKitSpeechRecognitionProvider(languageIdentifier: "en")

        provider.configure(languageIdentifier: "auto")

        XCTAssertNil(provider.configuredLanguageIdentifier)
    }

    @MainActor
    func testConfigureSpecificLanguageSetsLanguageIdentifier() {
        let provider = WhisperKitSpeechRecognitionProvider(languageIdentifier: nil)

        provider.configure(languageIdentifier: "es")

        XCTAssertEqual(provider.configuredLanguageIdentifier, "es")
    }

    @MainActor
    func testStartRecognitionAllowsLazyModelInitialization() {
        let provider = WhisperKitSpeechRecognitionProvider()

        XCTAssertFalse(provider.isAvailable)
        XCTAssertFalse(provider.isListening)
        XCTAssertNoThrow(try provider.startRecognition())
        XCTAssertTrue(provider.isListening)
        provider.stopRecognition(finalizePending: false, clearTranscript: true)
    }

    @MainActor
    func testInitialAssetStateIsUnknownBeforeModelPreparation() {
        let provider = WhisperKitSpeechRecognitionProvider()

        XCTAssertEqual(provider.assetState, .unknown)
    }

    @MainActor
    func testStripSpecialTokensRemovesBracketedAnnotations() {
        let provider = WhisperKitSpeechRecognitionProvider()

        XCTAssertEqual(
            provider.stripSpecialTokens("<|startoftranscript|> Hello [Music] there [BLANK_AUDIO] friend"),
            "Hello there friend"
        )
    }

    #if DEBUG
    @MainActor
    func testPendingInitializationWaitersResumeOnSuccess() async throws {
        let provider = WhisperKitSpeechRecognitionProvider()
        provider.test_beginInitialization()

        let waiter = Task { @MainActor in
            try await provider.test_enqueuePendingInitializationContinuation()
        }
        await Task.yield()

        provider.test_completeInitializationForTesting()

        try await waiter.value
        XCTAssertFalse(provider.test_isInitializing)
        XCTAssertFalse(provider.test_hasPendingInitializationContinuations)
    }

    @MainActor
    func testPendingInitializationWaitersResumeOnCancellation() async {
        let provider = WhisperKitSpeechRecognitionProvider()
        provider.test_beginInitialization()

        let waiter = Task { @MainActor in
            try await provider.test_enqueuePendingInitializationContinuation()
        }
        await Task.yield()

        provider.test_cancelInitializationForTesting()

        do {
            _ = try await waiter.value
            XCTFail("Expected initialization waiter to resume with cancellation")
        } catch is CancellationError {
            XCTAssertFalse(provider.test_isInitializing)
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    @MainActor
    func testPendingInitializationWaiterObservesCallerCancellation() async {
        let provider = WhisperKitSpeechRecognitionProvider()
        provider.test_beginInitialization()

        let waiter = Task { @MainActor in
            try await provider.test_enqueuePendingInitializationContinuation()
        }
        await Task.yield()

        waiter.cancel()

        do {
            _ = try await waiter.value
            XCTFail("Expected initialization waiter to throw cancellation")
        } catch is CancellationError {
            XCTAssertFalse(provider.test_hasPendingInitializationContinuations)
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }
    #endif

    @MainActor
    func testResetStreamingTranscriptStateClearsPriorSessionText() {
        let provider = WhisperKitSpeechRecognitionProvider()

        provider.setStreamingTranscriptForTesting("previous session")
        provider.resetStreamingTranscriptState()

        XCTAssertEqual(provider.currentTranscript, "")
        XCTAssertEqual(provider.lastTranscribedText, "")
    }

    @MainActor
    func testStreamingFailureRoutesToSingleSessionCallback() {
        let provider = WhisperKitSpeechRecognitionProvider()
        let error = WhisperKitLangToolsSpeechError.transcriptionFailed("boom")
        var events: [SpeechRecognitionEvent] = []
        provider.eventHandler = { event in
            events.append(event)
        }

        provider.handleStreamingFailure(error, onError: { error in
            provider.eventHandler?(.recognitionFailed(error.localizedDescription))
        })

        XCTAssertEqual(provider.lastError?.localizedDescription, error.localizedDescription)
        XCTAssertEqual(events, [.recognitionFailed(error.localizedDescription)])
    }

    @MainActor
    func testStreamingFinalEventIsDeduplicated() {
        let provider = WhisperKitSpeechRecognitionProvider()
        var events: [SpeechRecognitionEvent] = []

        provider.emitStreamingRecognitionEvent("hello", isFinal: true) { event in
            events.append(event)
        }
        provider.emitStreamingRecognitionEvent("hello", isFinal: true) { event in
            events.append(event)
        }
        provider.eventHandler = { event in
            events.append(event)
        }
        provider.emitFinalTranscriptionIfNeeded("hello")

        XCTAssertEqual(events, [.finalTranscription("hello")])
    }

    @MainActor
    func testResetClearsLazyStreamingState() {
        let provider = WhisperKitSpeechRecognitionProvider()

        XCTAssertNoThrow(try provider.startRecognition())
        XCTAssertTrue(provider.isStreaming)

        provider.reset()

        XCTAssertFalse(provider.isStreaming)
        XCTAssertEqual(provider.loadingState, .idle)
        XCTAssertNil(provider.lastError)
    }
}
#endif
