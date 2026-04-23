import XCTest
import KeychainAccess
@testable import Chat

final class ProviderAccessManagerTests: XCTestCase {
    private var keychain: Keychain!
    private var keychainService: KeychainService!
    private var sessionStore: AuthSessionStore!
    private var accessManager: ProviderAccessManager!

    override func setUp() {
        super.setUp()
        keychain = Keychain(service: "ProviderAccessManagerTests.\(UUID().uuidString)")
        keychainService = KeychainService(keychain: keychain)
        sessionStore = AuthSessionStore(keychain: keychain)
        accessManager = ProviderAccessManager(keychainService: keychainService, sessionStore: sessionStore)
    }

    func testNoCredentialsHidesRemoteModels() {
        accessManager.refresh()

        XCTAssertFalse(accessManager.availableChatModels().contains(where: { $0.apiService == .openAI }))
        XCTAssertFalse(accessManager.availableChatModels().contains(where: { $0.apiService == .anthropic }))
    }

    func testAPIKeyEnablesProviderModels() {
        keychainService.saveApiKey(apiKey: "sk-test", for: .openAI)
        accessManager.refresh()

        XCTAssertTrue(accessManager.state(for: .openAI).hasAPIKey)
        XCTAssertTrue(accessManager.availableChatModels().contains(where: { $0.apiService == .openAI }))
    }

    func testAccountSessionUsesAccessibleModelIDs() throws {
        let session = AccountSession(
            provider: .openAI,
            accountIdentifier: "openai-user",
            accessToken: "token",
            accessibleModelIDs: ["gpt-5.1-codex"]
        )

        try sessionStore.save(session)
        accessManager.refresh()

        let models = accessManager.state(for: .openAI).availableModels
        XCTAssertEqual(models.map(\.rawValue), ["gpt-5.1-codex"])
        XCTAssertTrue(models.first?.isCodexModel ?? false)
    }
}
