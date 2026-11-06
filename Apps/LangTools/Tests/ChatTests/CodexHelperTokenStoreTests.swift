import Foundation
import XCTest
@testable import Chat

final class CodexHelperTokenStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "CodexHelperTokenStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testRepeatedReadsUseMemoryAndVerifiedWritesUpdateIt() throws {
        let keychain = TestSecretStore()
        keychain.value = "original"
        let store = CodexHelperTokenStore(defaults: defaults, keychain: keychain)
        for _ in 0..<10 { XCTAssertEqual(try store.loadToken(), "original") }
        XCTAssertEqual(keychain.readCount, 1)
        try store.setToken("updated")
        let count = keychain.readCount
        XCTAssertEqual(try store.loadToken(), "updated")
        XCTAssertEqual(keychain.readCount, count)
        store.invalidateCache()
        XCTAssertEqual(try store.loadToken(), "updated")
        XCTAssertEqual(keychain.readCount, count + 1)
    }

    func testLegacyTokenMigratesOnlyAfterVerifiedKeychainWrite() throws {
        defaults.set("legacy-token", forKey: CodexHelperTokenStore.key)
        let keychain = TestSecretStore()
        let store = CodexHelperTokenStore(defaults: defaults, keychain: keychain)

        XCTAssertEqual(try store.loadToken(), "legacy-token")
        XCTAssertEqual(keychain.value, "legacy-token")
        XCTAssertNil(defaults.string(forKey: CodexHelperTokenStore.key))
    }

    func testMigrationFailureFailsClosedAndRetainsLegacyForRetry() {
        defaults.set("legacy-token", forKey: CodexHelperTokenStore.key)
        let keychain = TestSecretStore()
        keychain.setError = TestSecretStore.Failure.write
        let store = CodexHelperTokenStore(defaults: defaults, keychain: keychain)

        XCTAssertThrowsError(try store.loadToken())
        // Fail closed: no usable token is returned when secure storage fails.
        XCTAssertEqual(store.token(), "")
        // The legacy value is retained so a future migration attempt can retry.
        XCTAssertEqual(defaults.string(forKey: CodexHelperTokenStore.key), "legacy-token")
    }

    func testVerificationFailureRetainsLegacyToken() {
        defaults.set("legacy-token", forKey: CodexHelperTokenStore.key)
        let keychain = TestSecretStore()
        keychain.ignoreWrites = true
        let store = CodexHelperTokenStore(defaults: defaults, keychain: keychain)

        XCTAssertThrowsError(try store.loadToken()) { error in
            XCTAssertEqual(error as? CodexHelperTokenStoreError, .verificationFailed)
        }
        XCTAssertEqual(defaults.string(forKey: CodexHelperTokenStore.key), "legacy-token")
    }

    func testSetTokenVerifiesWriteBeforeRemovingLegacyDefault() throws {
        defaults.set("legacy-token", forKey: CodexHelperTokenStore.key)
        let keychain = TestSecretStore()
        let store = CodexHelperTokenStore(defaults: defaults, keychain: keychain)

        try store.setToken("new-token")

        XCTAssertEqual(keychain.value, "new-token")
        XCTAssertNil(defaults.string(forKey: CodexHelperTokenStore.key))
    }
}

private final class TestSecretStore: KeychainSecretStoring {
    enum Failure: Error {
        case write
    }

    var readCount = 0
    var value: String?
    var setError: Error?
    var ignoreWrites = false

    func setSecret(_ value: String, forKey key: String) throws {
        _ = key
        if let setError { throw setError }
        if ignoreWrites == false { self.value = value }
    }

    func readSecret(forKey key: String) throws -> String? {
        _ = key
        readCount += 1
        return value
    }

    func removeSecret(forKey key: String) throws {
        _ = key
        value = nil
    }
}
