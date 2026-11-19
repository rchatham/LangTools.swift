import Foundation
import XCTest
@testable import ExampleAgents

final class ResearchCredentialStoreTests: XCTestCase {
    func testLegacyPreferencesTakePrecedenceWithoutSecureReadOrWrite() throws {
        try withPreferences { preferences in
            let secure = FakeSecureCredentials()
            preferences.set("dummy-legacy-preference", forKey: "serperApiKey")
            let store = fixture(preferences, secure)
            XCTAssertEqual(secure.reads, 0)
            XCTAssertEqual(try store.readApiKey(), "dummy-legacy-preference")
            XCTAssertEqual(secure.reads, 0)
            XCTAssertEqual(secure.writes, [])
        }
    }

    func testEmptyPreferencesFallBackWithoutSynchronizingOrWriting() throws {
        try withPreferences { preferences in
            let secure = FakeSecureCredentials()
            secure.key = "dummy-secure-key"
            preferences.set("", forKey: "serperApiKey")
            let store = fixture(preferences, secure)
            XCTAssertEqual(try store.readApiKey(), "dummy-secure-key")
            XCTAssertEqual(secure.reads, 1)
            XCTAssertEqual(preferences.string(forKey: "serperApiKey"), "")
            XCTAssertTrue(secure.writes.isEmpty)
        }
    }

    func testMissingAndEmptySecureKeysReturnNil() throws {
        try withPreferences { preferences in
            let secure = FakeSecureCredentials()
            let store = fixture(preferences, secure)
            XCTAssertNil(try store.readApiKey())
            secure.key = ""
            XCTAssertNil(try store.readApiKey())
            XCTAssertNil(preferences.string(forKey: "serperApiKey"))
            XCTAssertTrue(secure.writes.isEmpty)
        }
    }

    func testExplicitSaveUpdatesBothStoresOnlyAfterSecureSaveSucceeds() throws {
        try withPreferences { preferences in
            let secure = FakeSecureCredentials()
            let store = fixture(preferences, secure)
            try store.saveApiKey("dummy-new-key")
            XCTAssertEqual(secure.writes, ["dummy-new-key"])
            XCTAssertEqual(preferences.string(forKey: "serperApiKey"), "dummy-new-key")
            secure.fail = true
            XCTAssertThrowsError(try store.saveApiKey("dummy-rejected-key")) { error in
                XCTAssertEqual(error as? ResearchCredentialError, .storageUnavailable)
                XCTAssertFalse(error.localizedDescription.contains("dummy-private-key-error"))
            }
            XCTAssertEqual(preferences.string(forKey: "serperApiKey"), "dummy-new-key")
            XCTAssertThrowsError(try store.saveApiKey(""))
            XCTAssertEqual(secure.writes, ["dummy-new-key"])
        }
    }

    func testReadErrorsAreSanitizedRatherThanTreatedAsMissingCredentials() throws {
        try withPreferences { preferences in
            let secure = FakeSecureCredentials()
            secure.fail = true
            XCTAssertThrowsError(try fixture(preferences, secure).readApiKey()) { error in
                XCTAssertEqual(error as? ResearchCredentialError, .storageUnavailable)
                XCTAssertFalse(error.localizedDescription.contains("dummy-private-key-error"))
            }
        }
    }

    private func fixture(_ preferences: UserDefaults, _ secure: FakeSecureCredentials) -> StoredResearchCredentials {
        StoredResearchCredentials(
            preferences: preferences,
            readSecureKey: { try secure.read() },
            saveSecureKey: { try secure.save($0) }
        )
    }

    private func withPreferences(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "ResearchCredentialStoreTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        try body(preferences)
    }
}

private final class FakeSecureCredentials {
    var key: String?
    var reads = 0
    var writes: [String] = []
    var fail = false

    func read() throws -> String? {
        reads += 1
        if fail { throw NSError(domain: "dummy-private-key-error", code: 1) }
        return key
    }

    func save(_ key: String) throws {
        if fail { throw NSError(domain: "dummy-private-key-error", code: 1) }
        writes.append(key)
        self.key = key
    }
}
