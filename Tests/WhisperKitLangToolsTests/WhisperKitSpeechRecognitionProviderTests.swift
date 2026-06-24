import XCTest
import LangTools
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
    func testStartRecognitionThrowsWhenProviderIsUnavailable() {
        let provider = WhisperKitSpeechRecognitionProvider()

        XCTAssertFalse(provider.isAvailable)
        XCTAssertThrowsError(try provider.startRecognition()) { error in
            XCTAssertEqual(
                error.localizedDescription,
                WhisperKitLangToolsSpeechError.providerNotConfigured.localizedDescription
            )
        }
    }

    @MainActor
    func testInitialAssetStateIsUnknownBeforeModelPreparation() {
        let provider = WhisperKitSpeechRecognitionProvider()

        XCTAssertEqual(provider.assetState, .unknown)
    }
}
