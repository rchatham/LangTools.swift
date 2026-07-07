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
}
#endif
