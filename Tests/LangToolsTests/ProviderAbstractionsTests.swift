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
        let request = LangToolsTextTranslationRequest(
            text: "Hello",
            sourceLanguageIdentifier: "en-US",
            targetLanguageIdentifier: "es-ES"
        )

        XCTAssertEqual(request.text, "Hello")
        XCTAssertEqual(request.sourceLanguageIdentifier, "en-US")
        XCTAssertEqual(request.targetLanguageIdentifier, "es-ES")
    }

    func testStringConformsToTranscriptionResponse() {
        let response: any LangToolsTranscriptionResponse = "hello world"

        XCTAssertEqual(response.transcriptText, "hello world")
        XCTAssertNil(response.detectedLanguageIdentifier)
    }

    func testDataConformsToAudioResponse() {
        let data = Data([0x01, 0x02, 0x03])
        let response: any LangToolsAudioResponse = data

        XCTAssertEqual(response.audioData, data)
    }

    // MARK: - State equality

    func testProviderAuthorizationStateEquality() {
        XCTAssertEqual(ProviderAuthorizationState.authorized, .authorized)
        XCTAssertEqual(ProviderAuthorizationState.denied, .denied)
        XCTAssertEqual(ProviderAuthorizationState.unavailable(reason: "x"), .unavailable(reason: "x"))
        XCTAssertNotEqual(ProviderAuthorizationState.authorized, .denied)
        XCTAssertNotEqual(ProviderAuthorizationState.unavailable(reason: "a"), .unavailable(reason: "b"))
    }

    func testProviderAssetStateEquality() {
        XCTAssertEqual(ProviderAssetState.ready, .ready)
        XCTAssertEqual(ProviderAssetState.failed(reason: "disk full"), .failed(reason: "disk full"))
        XCTAssertNotEqual(ProviderAssetState.ready, .missing)
        XCTAssertNotEqual(ProviderAssetState.failed(reason: "a"), .failed(reason: "b"))
    }

    func testSpeechAutoDetectWinnerUndetectedNotNilAmbiguous() {
        let winner = SpeechAutoDetectWinner.undetected
        XCTAssertNotEqual(winner, .primary)
        XCTAssertNotEqual(winner, .secondary)
        XCTAssertEqual(winner, .undetected)
    }

    // MARK: - Generic abstraction boundary

    func testGenericTTSBoundaryAcceptsAnyLangToolsSpeechSynthesisRequest() {
        func speechText(from request: some LangToolsSpeechSynthesisRequest) -> String {
            request.speechText
        }

        struct StubTTS: LangToolsSpeechSynthesisRequest {
            var speechText: String { "stub" }
            var speechVoiceIdentifier: String? { nil }
            var speechSpeed: Double? { nil }
            var speechResponseFormat: String? { nil }
        }

        XCTAssertEqual(speechText(from: StubTTS()), "stub")
    }

    func testGenericSTTBoundaryAcceptsAnyLangToolsSpeechTranscriptionRequest() {
        func audioFormat(from request: some LangToolsSpeechTranscriptionRequest) -> String? {
            request.speechAudioFormat
        }

        struct StubSTT: LangToolsSpeechTranscriptionRequest {
            typealias TranscriptionResponse = String
            var speechAudioData: Data? { nil }
            var speechAudioFileURL: URL? { nil }
            var speechAudioFormat: String? { "wav" }
            var speechLanguageIdentifier: String? { nil }
            var speechPrompt: String? { nil }
        }

        XCTAssertEqual(audioFormat(from: StubSTT()), "wav")
    }
}
