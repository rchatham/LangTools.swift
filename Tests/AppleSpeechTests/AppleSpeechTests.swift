//
//  AppleSpeechTests.swift
//  AppleSpeech
//
//  Tests for AppleSpeech module functionality
//

import XCTest
import Speech
@testable import AppleSpeech

final class AppleSpeechTests: XCTestCase {

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
