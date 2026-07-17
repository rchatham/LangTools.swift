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
}
#endif
