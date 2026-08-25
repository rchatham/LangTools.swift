//
//  AppleSpeechTests.swift
//  AppleSpeech
//
//  Tests for AppleSpeech module functionality
//

import XCTest
import Speech
import LangTools
@testable import AppleLangTools

final class AppleSpeechTests: XCTestCase {

    @MainActor
    func testResetStreamingTranscriptStateClearsPriorSessionText() {
        let provider = AppleSpeechRecognitionProvider(locale: Locale(identifier: "en-US"))

        provider.setStreamingTranscriptForTesting("previous session")
        provider.resetStreamingTranscriptState()

        XCTAssertEqual(provider.currentTranscript, "")
    }

    @MainActor
    func testStreamingFailureUsesSessionCallbackWithoutDuplicateEventHandlerDelivery() async {
        let provider = AppleSpeechRecognitionProvider(locale: Locale(identifier: "en-US"))
        let expectedError = NSError(domain: "AppleSpeechTests", code: 42, userInfo: [NSLocalizedDescriptionKey: "recognition failed"])
        var events: [SpeechRecognitionEvent] = []
        provider.eventHandler = { event in
            events.append(event)
        }

        do {
            _ = try await provider.test_failStreamingForTesting(expectedError) { error in
                events.append(.recognitionFailed(error.localizedDescription))
            }
            XCTFail("Expected blocking streaming continuation to throw")
        } catch {
            XCTAssertEqual((error as NSError).domain, expectedError.domain)
            XCTAssertEqual((error as NSError).code, expectedError.code)
            XCTAssertEqual(events, [.recognitionFailed("recognition failed")])
            XCTAssertFalse(provider.isStreaming)
        }
    }

    @MainActor
    func testStreamingFailureEmitsSessionFailureCallback() async {
        let provider = AppleSpeechRecognitionProvider(locale: Locale(identifier: "en-US"))
        let expectedError = NSError(domain: "AppleSpeechTests", code: 42, userInfo: [NSLocalizedDescriptionKey: "recognition failed"])
        var failedMessage: String?

        do {
            _ = try await provider.test_failStreamingForTesting(expectedError) { error in
                failedMessage = error.localizedDescription
            }
            XCTFail("Expected blocking streaming continuation to throw")
        } catch {
            XCTAssertEqual((error as NSError).domain, expectedError.domain)
            XCTAssertEqual((error as NSError).code, expectedError.code)
            XCTAssertEqual(failedMessage, "recognition failed")
            XCTAssertFalse(provider.isStreaming)
        }
    }

    @MainActor
    func testBlockingStreamingRejectsOverlappingSession() async {
        let provider = AppleSpeechRecognitionProvider(locale: Locale(identifier: "en-US"))
        let firstRun = Task { @MainActor in
            try await provider.test_runBlockedStreamingForTesting()
        }
        await Task.yield()

        do {
            _ = try await provider.test_runBlockedStreamingForTesting()
            XCTFail("Expected overlapping blocking streaming session to throw")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Recording failed: Streaming recognition is already active")
        }

        firstRun.cancel()
        _ = await firstRun.result
    }

    // MARK: - Locale Support Tests

    func testSupportedLocalesNotEmpty() {
        let locales = AppleSpeech.supportedLocales
        XCTAssertFalse(locales.isEmpty, "Should have at least one supported locale")
    }

    func testSupportedLocalesContainsEnglish() {
        let locales = AppleSpeech.supportedLocales
        let englishLocales = locales.filter { $0.language.languageCode?.identifier == "en" }
        XCTAssertFalse(englishLocales.isEmpty, "Should support English locale")
    }

    func testSupportedLocalesMatchesSFSpeechRecognizer() {
        let appleSpeechLocales = AppleSpeech.supportedLocales
        let sfLocales = SFSpeechRecognizer.supportedLocales()

        XCTAssertEqual(
            appleSpeechLocales.count,
            sfLocales.count,
            "AppleSpeech locales should match SFSpeechRecognizer locales"
        )
    }

    // MARK: - Authorization Tests

    func testRequestAuthorizationReturnsStatus() async {
        let status = await AppleSpeech.requestAuthorization()

        // Status should be one of the valid cases
        let validStatuses: Set<SFSpeechRecognizerAuthorizationStatus> = [
            .notDetermined, .denied, .restricted, .authorized
        ]
        XCTAssertTrue(
            validStatuses.contains(status),
            "Should return a valid authorization status"
        )
    }

    // MARK: - Model Tests

    func testModelRawValues() {
        XCTAssertEqual(AppleSpeech.Model.onDevice.rawValue, "on-device")
    }

    func testModelCaseIterable() {
        let allModels = AppleSpeech.Model.allCases
        XCTAssertEqual(allModels.count, 1, "Should have exactly one model")
        XCTAssertTrue(allModels.contains(.onDevice))
    }

    func testModelCodable() throws {
        let model = AppleSpeech.Model.onDevice

        // Test encoding
        let encoder = JSONEncoder()
        let data = try encoder.encode(model)

        // Test decoding
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(AppleSpeech.Model.self, from: data)

        XCTAssertEqual(decoded, model)
    }
}
