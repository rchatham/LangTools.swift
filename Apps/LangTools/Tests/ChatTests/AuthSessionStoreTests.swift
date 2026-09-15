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

    override func tearDown() {
        try? keychain.removeAll()
        super.tearDown()
    }

    func testSaveAndLoadSession() throws {
        let session = AccountSession(
            provider: .openAI,
            accountIdentifier: "user@example.com",
            accessToken: "token",
            refreshToken: "refresh-token",
            idToken: "id-token",
            tokenType: "Bearer",
            accessibleModelIDs: ["gpt-4o-mini", "gpt-5.3-codex-spark"]
        )

        try store.save(session)
        let loaded = try store.session(for: .openAI)

        XCTAssertEqual(loaded?.id, session.id)
        XCTAssertEqual(loaded?.accountIdentifier, session.accountIdentifier)
        XCTAssertEqual(loaded?.accessibleModelIDs, session.accessibleModelIDs)
        XCTAssertEqual(loaded?.accessToken, CodexSessionMarker.value)
        XCTAssertNil(loaded?.refreshToken)
        XCTAssertNil(loaded?.idToken)
        XCTAssertNil(loaded?.tokenType)
        XCTAssertNil(loaded?.expiresAt)
    }

    func testLoadOlderSessionPayloadWithoutNewOptionalFields() throws {
        let json = """
        {
          "id": "\(UUID())",
          "provider": "openAI",
          "accountIdentifier": "user@example.com",
          "accessToken": "token",
          "refreshToken": "refresh-token",
          "expiresAt": null,
          "accessibleModelIDs": ["gpt-5.3-codex-spark"],
          "createdAt": 0
        }
        """
        try keychain.set(json, key: "openAI:accountSession")

        let loaded = try store.session(for: .openAI)

        XCTAssertEqual(loaded?.accountIdentifier, "user@example.com")
        XCTAssertEqual(loaded?.accessToken, CodexSessionMarker.value)
        XCTAssertNil(loaded?.refreshToken)
        XCTAssertNil(loaded?.idToken)
        XCTAssertNil(loaded?.tokenType)

        let rewritten = try XCTUnwrap(keychain.getString("openAI:accountSession"))
        XCTAssertFalse(rewritten.contains("refresh-token"))
        XCTAssertFalse(rewritten.contains("\"accessToken\":\"token\""))
    }

    func testClaudeCodeCredentialsArePreserved() throws {
        let session = AccountSession(
            provider: .claudeCode,
            accountIdentifier: "claude-user",
            accessToken: "claude-access",
            refreshToken: "claude-refresh",
            idToken: "claude-id",
            tokenType: "Bearer"
        )

        try store.save(session)

        XCTAssertEqual(try store.session(for: .claudeCode), session)
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
