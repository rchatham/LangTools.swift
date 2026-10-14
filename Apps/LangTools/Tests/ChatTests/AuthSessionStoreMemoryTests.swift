import Foundation
import KeychainAccess
import XCTest
@testable import Chat

final class AuthSessionStoreMemoryTests: XCTestCase {
    func testConcreteKeychainInitializerRemainsAFunctionReference() {
        let legacy: (Keychain) -> AuthSessionStore = AuthSessionStore.init(keychain:)
        _ = legacy // Never execute: no host Keychain operations in this suite.
    }

    func testRoundTripUsesExactLegacyKeysAndCodablePayload() throws {
        let secrets = SettingsMemorySecretStore()
        let store = AuthSessionStore(secretStore: secrets)
        var sessions: [AccountSession] = []
        for provider in AccountLoginProvider.allCases {
            let session = AccountSession(provider: provider, accountIdentifier: "fixture-account",
                accessToken: "fixture-access", refreshToken: "fixture-refresh", idToken: "fixture-id",
                tokenType: "Bearer", expiresAt: Date(timeIntervalSince1970: 1234),
                accessibleModelIDs: ["fixture-model"], createdAt: Date(timeIntervalSince1970: 100))
            sessions.append(session)
            try store.save(session)
            XCTAssertEqual(try store.session(for: provider), session)
            let json = try XCTUnwrap(secrets.values["\(provider.rawValue):accountSession"])
            XCTAssertEqual(try JSONDecoder().decode(AccountSession.self, from: Data(json.utf8)), session)
            let actual = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary
            let expected = try JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? NSDictionary
            XCTAssertEqual(actual, expected)
        }
        XCTAssertEqual(Set(secrets.values.keys), ["openAI:accountSession", "claudeCode:accountSession"])
        XCTAssertEqual(try store.allSessions(), sessions)
        try store.removeSession(for: .openAI)
        XCTAssertEqual(secrets.removedKeys, ["openAI:accountSession"])
        XCTAssertNil(try store.session(for: .openAI))
        XCTAssertEqual(try store.allSessions(), Array(sessions.dropFirst()))
        try store.removeSession(for: .claudeCode)
        XCTAssertEqual(secrets.removedKeys, ["openAI:accountSession", "claudeCode:accountSession"])
        XCTAssertEqual(try store.allSessions(), [])
    }

    func testSecretStoreErrorsPropagateUnchanged() throws {
        let secrets = SettingsMemorySecretStore()
        let store = AuthSessionStore(secretStore: secrets)
        let session = AccountSession(provider: .openAI, accountIdentifier: "fixture", accessToken: "fixture")
        secrets.failure = .write
        XCTAssertThrowsError(try store.save(session)) { XCTAssertEqual($0 as? SettingsMemorySecretStore.Failure, .write) }
        secrets.failure = .read
        XCTAssertThrowsError(try store.session(for: .openAI)) { XCTAssertEqual($0 as? SettingsMemorySecretStore.Failure, .read) }
        XCTAssertThrowsError(try store.allSessions()) { XCTAssertEqual($0 as? SettingsMemorySecretStore.Failure, .read) }
        secrets.failure = .remove
        XCTAssertThrowsError(try store.removeSession(for: .openAI)) { XCTAssertEqual($0 as? SettingsMemorySecretStore.Failure, .remove) }
    }

    func testMalformedRecordThrowsWithoutRewritingOrRemoving() {
        let secrets = SettingsMemorySecretStore()
        secrets.values["openAI:accountSession"] = "not-json"
        let store = AuthSessionStore(secretStore: secrets)
        XCTAssertThrowsError(try store.session(for: .openAI)) { XCTAssertTrue($0 is DecodingError) }
        XCTAssertThrowsError(try store.allSessions()) { XCTAssertTrue($0 is DecodingError) }
        XCTAssertEqual(secrets.values, ["openAI:accountSession": "not-json"])
        XCTAssertTrue(secrets.removedKeys.isEmpty)
    }

    func testOlderPayloadRetainsOptionalFieldCompatibility() throws {
        let secrets = SettingsMemorySecretStore()
        let json = """
        {"id":"\(UUID())","provider":"openAI","accountIdentifier":"fixture","accessToken":"fixture-token",
         "refreshToken":"fixture-refresh","accessibleModelIDs":["fixture-model"],"createdAt":0}
        """
        secrets.values["openAI:accountSession"] = json
        let session = try XCTUnwrap(AuthSessionStore(secretStore: secrets).session(for: .openAI))
        XCTAssertEqual(session.accessToken, "fixture-token")
        XCTAssertEqual(session.refreshToken, "fixture-refresh")
        XCTAssertNil(session.idToken)
        XCTAssertNil(session.tokenType)
        XCTAssertNil(session.expiresAt)
        XCTAssertEqual(secrets.values["openAI:accountSession"], json)
    }
}

/// Shared only by the bounded settings tests; every operation stays in memory.
final class SettingsMemorySecretStore: KeychainSecretStoring {
    enum Failure: Error, Equatable { case read, write, remove }
    var values: [String: String] = [:]
    var removedKeys: [String] = []
    var failure: Failure?

    func setSecret(_ value: String, forKey key: String) throws {
        if failure == .write { throw Failure.write }
        values[key] = value
    }

    func readSecret(forKey key: String) throws -> String? {
        if failure == .read { throw Failure.read }
        return values[key]
    }

    func removeSecret(forKey key: String) throws {
        if failure == .remove { throw Failure.remove }
        removedKeys.append(key)
        values.removeValue(forKey: key)
    }
}
