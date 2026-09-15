import XCTest
import KeychainAccess
import Anthropic
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

    override func tearDown() {
        try? keychain.removeAll()
        super.tearDown()
    }

    func testNoCredentialsKeepsRequestedSelectionWithoutInventingAccessibleFallback() {
        let requested = Model.codex(.gpt5_5)
        XCTAssertEqual(accessManager.validateSelectedModel(requested), requested)
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
            accessibleModelIDs: ["gpt-5.5", "gpt-5.3-codex-spark"]
        )

        try sessionStore.save(session)
        accessManager.refresh()

        let models = accessManager.state(for: .openAI).availableModels
        XCTAssertEqual(models.map(\.rawValue), ["codex/gpt-5.5", "codex/gpt-5.3-codex-spark"])
        XCTAssertEqual(models.first?.rawValue, "codex/gpt-5.5")
    }

    func testOpenAIAccountSessionPreservesFutureCodexModelSlug() throws {
        try sessionStore.save(AccountSession(
            provider: .openAI,
            accountIdentifier: "openai-user",
            accessToken: "token",
            accessibleModelIDs: ["gpt-future-codex"]
        ))
        accessManager.refresh()

        XCTAssertEqual(accessManager.state(for: .openAI).availableModels.map(\.rawValue), ["codex/gpt-future-codex"])
    }

    func testOpenAIAccountSessionWithoutAccessibleModelIDsExposesNoCodexModels() throws {
        let session = AccountSession(
            provider: .openAI,
            accountIdentifier: "openai-user",
            accessToken: "token",
            accessibleModelIDs: []
        )

        try sessionStore.save(session)
        accessManager.refresh()

        let modelIDs = accessManager.state(for: .openAI).availableModels.map(\.rawValue)
        XCTAssertEqual(modelIDs, [])
    }

    func testAccessUIPresentsOpenAIPlatformAndCodexSeparately() throws {
        keychainService.saveApiKey(apiKey: "sk-test", for: .openAI)
        try sessionStore.save(AccountSession(
            provider: .openAI,
            accountIdentifier: "openai-user",
            accessToken: "token",
            accessibleModelIDs: ["gpt-5.5"]
        ))
        accessManager.refresh()

        let openAIStates = accessManager.statesForAccessUI().filter { $0.service == .openAI }
        XCTAssertEqual(openAIStates.map(\.displayName), ["OpenAI Platform", "Codex Subscription"])
        XCTAssertEqual(openAIStates[0].availableModels.map(\.rawValue).filter { $0 == "openai/gpt-5.5" }, ["openai/gpt-5.5"])
        XCTAssertEqual(openAIStates[1].availableModels.map(\.rawValue), ["codex/gpt-5.5"])
    }

    func testAccessUIPresentsAnthropicPlatformAndClaudeCodeSeparately() throws {
        let anthropicModel = try XCTUnwrap(Anthropic.Model.allCases.first)
        keychainService.saveApiKey(apiKey: "sk-ant-test", for: .anthropic)
        try sessionStore.save(AccountSession(
            provider: .claudeCode,
            accountIdentifier: "claude-user",
            accessToken: "token",
            accessibleModelIDs: [anthropicModel.rawValue]
        ))
        accessManager.refresh()

        let states = accessManager.statesForAccessUI().filter { $0.service == .anthropic }
        XCTAssertEqual(states.map(\.accessDestination), [.anthropic, .claudeCode])
        XCTAssertEqual(states.map(\.displayName), ["Anthropic Platform", "Claude Code"])
        XCTAssertTrue(states[0].availableModels.allSatisfy { $0.route == .anthropic })
        XCTAssertEqual(states[1].availableModels.map(\.rawValue), ["claude-code/\(anthropicModel.rawValue)"])
    }

    func testAccessUIDestinationsAreIndependent() {
        XCTAssertEqual(
            accessManager.statesForAccessUI().compactMap(\.accessDestination),
            [.openAI, .codex, .anthropic, .claudeCode, .xAI, .gemini]
        )
    }

    func testOpenAIAPIKeyAndCodexSessionShowSeparateModelEntries() throws {
        keychainService.saveApiKey(apiKey: "sk-test", for: .openAI)
        let session = AccountSession(
            provider: .openAI,
            accountIdentifier: "openai-user",
            accessToken: "token",
            accessibleModelIDs: ["gpt-5.5", "gpt-5.3-codex-spark"]
        )

        try sessionStore.save(session)
        accessManager.refresh()

        let modelIDs = accessManager.state(for: .openAI).availableModels.map(\.rawValue)
        XCTAssertTrue(modelIDs.contains("codex/gpt-5.5"))
        XCTAssertTrue(modelIDs.contains("openai/gpt-5.5"))
        XCTAssertTrue(modelIDs.contains("codex/gpt-5.3-codex-spark"))
    }

    func testOpenAIAccountSessionDoesNotExposePlatformOnlyModelsWithoutAPIKey() throws {
        let session = AccountSession(
            provider: .openAI,
            accountIdentifier: "openai-user",
            accessToken: "token",
            accessibleModelIDs: ["gpt-5.5"]
        )

        try sessionStore.save(session)
        accessManager.refresh()

        let modelIDs = accessManager.state(for: .openAI).availableModels.map(\.rawValue)
        XCTAssertEqual(modelIDs, ["codex/gpt-5.5"])
        XCTAssertFalse(modelIDs.contains("openai/gpt-5.5"))
        XCTAssertFalse(modelIDs.contains("openai/gpt-4o-mini"))
    }

    func testConcurrentRefreshAndStateReadsAreSafeAcrossIsolation() async {
        // Exercises state(for:) from a nonisolated async context (mirroring
        // NetworkClient.ensureModelAccess) interleaved with main-thread
        // refresh() writes. The lock-protected snapshot must stay consistent
        // and never return a state for the wrong service.
        for index in 0..<400 {
            let service = APIService.allCases[index % APIService.allCases.count]
            // Nonisolated read of the access manager (no MainActor hop).
            let snapshot = accessManager.state(for: service)
            XCTAssertEqual(snapshot.service, service)
            if index % 2 == 0 {
                await MainActor.run { accessManager.refresh() }
            }
        }
        await MainActor.run { accessManager.refresh() }
        for service in APIService.allCases {
            XCTAssertEqual(accessManager.state(for: service).service, service)
        }
    }
}
