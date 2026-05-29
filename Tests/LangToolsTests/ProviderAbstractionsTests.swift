import XCTest
@testable import LangTools

final class ProviderAbstractionsTests: XCTestCase {
    func testProviderCapabilitiesModelUnsupportedFeaturesExplicitly() {
        let capabilities = ProviderCapabilities(
            runsOnDevice: true,
            supportsStreamingPartials: false,
            supportsContinuousMode: false,
            supportsDualLanguageAutoDetect: false,
            requiresNetwork: false,
            requiresModelDownload: true
        )

        XCTAssertTrue(capabilities.runsOnDevice)
        XCTAssertFalse(capabilities.supportsStreamingPartials)
        XCTAssertFalse(capabilities.supportsContinuousMode)
        XCTAssertFalse(capabilities.supportsDualLanguageAutoDetect)
        XCTAssertFalse(capabilities.requiresNetwork)
        XCTAssertTrue(capabilities.requiresModelDownload)
    }

    func testProviderIDIsCodableAndHashable() throws {
        let providerID = LangToolsProviderID(rawValue: "local.whisper")
        let encoded = try JSONEncoder().encode(providerID)
        let decoded = try JSONDecoder().decode(LangToolsProviderID.self, from: encoded)

        XCTAssertEqual(decoded, providerID)
        XCTAssertEqual(Set([providerID, decoded]).count, 1)
    }

    func testTranslationRequestUsesBCP47Identifiers() {
        let request = TextTranslationRequest(
            text: "Hello",
            sourceLanguageIdentifier: "en-US",
            targetLanguageIdentifier: "es-ES"
        )

        XCTAssertEqual(request.text, "Hello")
        XCTAssertEqual(request.sourceLanguageIdentifier, "en-US")
        XCTAssertEqual(request.targetLanguageIdentifier, "es-ES")
    }
}
