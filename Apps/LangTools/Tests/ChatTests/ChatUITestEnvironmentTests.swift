//
//  ChatUITestEnvironmentTests.swift
//  ChatTests
//
//  Pure-policy regression tests using the injected resolve(rawMode:…) entry
//  point. No global env mutation, no ProcessInfo, no Bundle.main dependency.
//  All paths — valid, wrong bundle, unrecognized, Release, non-macOS — are
//  covered deterministically.
//
//  No real Keychain, network, or credential access is performed.
//

import XCTest
@testable import Chat

final class ChatUITestEnvironmentTests: XCTestCase {

    private let fixtureBundle = ChatUITestEnvironment.fixtureBundleIdentifier
    private let ordinaryBundle = "com.reidchatham.LangTools-Example"

    // MARK: - No env var → nil (normal app run — all contexts)

    func testNoEnvVarReturnsNilOnFixtureBundle() throws {
        XCTAssertNil(try ChatUITestEnvironment.resolve(
            rawMode: nil, bundleIdentifier: fixtureBundle, isDebug: true, isMacOS: true
        ))
    }

    func testNoEnvVarReturnsNilOnOrdinaryBundle() throws {
        XCTAssertNil(try ChatUITestEnvironment.resolve(
            rawMode: nil, bundleIdentifier: ordinaryBundle, isDebug: true, isMacOS: true
        ))
    }

    // MARK: - Valid: fixture bundle + recognized mode

    func testStandardOnFixtureBundleReturnsStandard() throws {
        let mode = try ChatUITestEnvironment.resolve(
            rawMode: "standard", bundleIdentifier: fixtureBundle, isDebug: true, isMacOS: true
        )
        XCTAssertEqual(mode, .standard)
    }

    func testCodexSuccessOnFixtureBundleReturnsCodexSuccess() throws {
        let mode = try ChatUITestEnvironment.resolve(
            rawMode: "codexSuccess", bundleIdentifier: fixtureBundle, isDebug: true, isMacOS: true
        )
        XCTAssertEqual(mode, .codexSuccess)
    }

    func testCodexNotLoggedInOnFixtureBundleReturnsCodexNotLoggedIn() throws {
        let mode = try ChatUITestEnvironment.resolve(
            rawMode: "codexNotLoggedIn", bundleIdentifier: fixtureBundle, isDebug: true, isMacOS: true
        )
        XCTAssertEqual(mode, .codexNotLoggedIn)
    }

    // MARK: - Wrong bundle: any recognized mode throws wrongBundle

    func testStandardOnOrdinaryBundleThrowsWrongBundle() {
        XCTAssertThrowsError(try ChatUITestEnvironment.resolve(
            rawMode: "standard", bundleIdentifier: ordinaryBundle, isDebug: true, isMacOS: true
        )) { error in
            guard case ChatUITestEnvironmentError.wrongBundle = error else {
                XCTFail("Expected wrongBundle, got \(error)")
                return
            }
        }
    }

    func testCodexSuccessOnOrdinaryBundleThrowsWrongBundle() {
        XCTAssertThrowsError(try ChatUITestEnvironment.resolve(
            rawMode: "codexSuccess", bundleIdentifier: ordinaryBundle, isDebug: true, isMacOS: true
        )) { error in
            guard case ChatUITestEnvironmentError.wrongBundle = error else {
                XCTFail("Expected wrongBundle, got \(error)")
                return
            }
        }
    }

    func testCodexNotLoggedInOnOrdinaryBundleThrowsWrongBundle() {
        XCTAssertThrowsError(try ChatUITestEnvironment.resolve(
            rawMode: "codexNotLoggedIn", bundleIdentifier: ordinaryBundle, isDebug: true, isMacOS: true
        )) { error in
            guard case ChatUITestEnvironmentError.wrongBundle = error else {
                XCTFail("Expected wrongBundle, got \(error)")
                return
            }
        }
    }

    func testUnknownModeOnOrdinaryBundleThrowsWrongBundle() {
        // wrongBundle wins over unrecognizedMode when the bundle is wrong.
        XCTAssertThrowsError(try ChatUITestEnvironment.resolve(
            rawMode: "bogus", bundleIdentifier: ordinaryBundle, isDebug: true, isMacOS: true
        )) { error in
            guard case ChatUITestEnvironmentError.wrongBundle = error else {
                XCTFail("Expected wrongBundle, got \(error)")
                return
            }
        }
    }

    // MARK: - Unknown mode on fixture bundle throws unrecognizedMode

    func testUnknownModeOnFixtureBundleThrowsUnrecognizedMode() {
        XCTAssertThrowsError(try ChatUITestEnvironment.resolve(
            rawMode: "bogusNonexistentMode", bundleIdentifier: fixtureBundle, isDebug: true, isMacOS: true
        )) { error in
            guard case ChatUITestEnvironmentError.unrecognizedMode = error else {
                XCTFail("Expected unrecognizedMode, got \(error)")
                return
            }
        }
    }

    func testEmptyStringModeOnFixtureBundleThrowsUnrecognizedMode() {
        // Empty string is not a recognized case.
        XCTAssertThrowsError(try ChatUITestEnvironment.resolve(
            rawMode: "", bundleIdentifier: fixtureBundle, isDebug: true, isMacOS: true
        )) { error in
            guard case ChatUITestEnvironmentError.unrecognizedMode = error else {
                XCTFail("Expected unrecognizedMode, got \(error)")
                return
            }
        }
    }

    // MARK: - Release: always nil regardless of env var / bundle

    func testStandardOnFixtureBundleReleaseReturnsNil() throws {
        XCTAssertNil(try ChatUITestEnvironment.resolve(
            rawMode: "standard", bundleIdentifier: fixtureBundle, isDebug: false, isMacOS: true
        ))
    }

    func testStandardOnOrdinaryBundleReleaseReturnsNil() throws {
        XCTAssertNil(try ChatUITestEnvironment.resolve(
            rawMode: "standard", bundleIdentifier: ordinaryBundle, isDebug: false, isMacOS: true
        ))
    }

    func testNoEnvVarReleaseReturnsNil() throws {
        XCTAssertNil(try ChatUITestEnvironment.resolve(
            rawMode: nil, bundleIdentifier: fixtureBundle, isDebug: false, isMacOS: true
        ))
    }

    // MARK: - Non-macOS: always nil

    func testStandardOnFixtureBundleNonMacOSReturnsNil() throws {
        XCTAssertNil(try ChatUITestEnvironment.resolve(
            rawMode: "standard", bundleIdentifier: fixtureBundle, isDebug: true, isMacOS: false
        ))
    }

    func testStandardOnFixtureBundleNonMacOSReleaseReturnsNil() throws {
        XCTAssertNil(try ChatUITestEnvironment.resolve(
            rawMode: "standard", bundleIdentifier: fixtureBundle, isDebug: false, isMacOS: false
        ))
    }

    // MARK: - Bundle identity

    func testFixtureBundleIdentifierIsExpected() {
        XCTAssertEqual(fixtureBundle, "com.reidchatham.LangTools-Example-UIFixture")
    }

    // MARK: - Namespace isolation

    func testFixtureKeychainServiceIsUnique() {
        let fixtureService = ChatUITestEnvironment.fixtureKeychainService
        let ordinaryService = "com.reidchatham.LangTools_Example"
        XCTAssertNotEqual(fixtureService, ordinaryService)
        XCTAssertTrue(fixtureService.contains("UIFixture"))
    }

    func testFixtureUserDefaultsSuiteIsUnique() {
        let fixtureSuite = ChatUITestEnvironment.fixtureUserDefaultsSuite
        XCTAssertTrue(fixtureSuite.contains("UIFixture"))
    }

    // MARK: - Error descriptions are non-empty and do not leak raw env

    func testWrongBundleErrorDescriptionIsSanitized() {
        let desc = ChatUITestEnvironmentError.wrongBundle.description
        XCTAssertFalse(desc.isEmpty)
        XCTAssertFalse(desc.contains("LANGTOOLS_UI_TEST_MODE="))
    }

    func testUnrecognizedModeErrorDescriptionIsSanitized() {
        let desc = ChatUITestEnvironmentError.unrecognizedMode.description
        XCTAssertFalse(desc.isEmpty)
        XCTAssertFalse(desc.contains("LANGTOOLS_UI_TEST_MODE="))
        // Must not contain the raw untrusted mode value.
        XCTAssertFalse(desc.contains("bogus"))
    }

    // MARK: - Raw value round-trip

    func testAllCasesRoundTripViaRawValue() {
        for mode in ChatUITestEnvironment.allCases {
            XCTAssertEqual(ChatUITestEnvironment(rawValue: mode.rawValue), mode)
        }
    }

    func testAllRawValuesAreUnique() {
        let rawValues = ChatUITestEnvironment.allCases.map(\.rawValue)
        XCTAssertEqual(Set(rawValues).count, rawValues.count)
    }

    func testCaseInsensitiveIsNotMatched() {
        XCTAssertNil(ChatUITestEnvironment(rawValue: "STANDARD"))
    }
}