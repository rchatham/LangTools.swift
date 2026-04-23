import XCTest
import KeychainAccess
@testable import Chat

final class AuthSessionStoreTests: XCTestCase {
    private var keychain: Keychain!
    private var store: AuthSessionStore!

    override func setUp() {
        super.setUp()
        keychain = Keychain(service: "AuthSessionStoreTests.\(UUID().uuidString)")
        store = AuthSessionStore(keychain: keychain)
    }

    func testSaveAndLoadSession() throws {
        let session = AccountSession(
            provider: .openAI,
            accountIdentifier: "user@example.com",
            accessToken: "token",
            accessibleModelIDs: ["gpt-4o-mini", "gpt-5.1-codex"]
        )

        try store.save(session)
        let loaded = try store.session(for: .openAI)

        XCTAssertEqual(loaded, session)
    }

    func testRemoveSession() throws {
        let session = AccountSession(
            provider: .claudeCode,
            accountIdentifier: "claude-user",
            accessToken: "token"
        )

        try store.save(session)
        try store.removeSession(for: .claudeCode)

        XCTAssertNil(try store.session(for: .claudeCode))
    }
}
