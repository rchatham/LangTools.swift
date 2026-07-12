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

    @MainActor
    func testResetStreamingTranscriptStateClearsPriorSessionText() {
        let provider = WhisperKitSpeechRecognitionProvider()

        provider.setStreamingTranscriptForTesting("previous session")
        provider.resetStreamingTranscriptState()

        XCTAssertEqual(provider.currentTranscript, "")
        XCTAssertEqual(provider.lastTranscribedText, "")
    }

    @MainActor
    func testStreamingFailureRoutesToSessionCallbackAndEventHandler() {
        let provider = WhisperKitSpeechRecognitionProvider()
        let error = WhisperKitLangToolsSpeechError.transcriptionFailed("boom")
        var eventHandlerEvents: [SpeechRecognitionEvent] = []
        var sessionEvents: [SpeechRecognitionEvent] = []
        provider.eventHandler = { event in
            eventHandlerEvents.append(event)
        }

        provider.handleStreamingFailure(error, onError: { error in
            sessionEvents.append(.recognitionFailed(error.localizedDescription))
        })

        XCTAssertEqual(provider.lastError?.localizedDescription, error.localizedDescription)
        XCTAssertEqual(eventHandlerEvents, [.recognitionFailed(error.localizedDescription)])
        XCTAssertEqual(sessionEvents, [.recognitionFailed(error.localizedDescription)])
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
