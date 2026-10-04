import XCTest
import OpenAI
import KeychainAccess
@testable import Chat

@MainActor
final class ChatModelSourceTests: XCTestCase {
    private var savedModel: String?
    override func setUp() async throws {
        savedModel = UserDefaults.standard.string(forKey: "model")
    }
    override func tearDown() async throws {
        UserDefaults.standard.set(savedModel, forKey: "model")
    }

    func testExplicitOpenAIRoutePersistsCustomIDsWithoutInferringUnknownProviders() {
        let custom = Model.openAI(OpenAI.Model(customModelID: "gpt-server-fixture"))
        UserDefaults.model = custom
        XCTAssertEqual(UserDefaults.model, custom)
        XCTAssertEqual(Model(rawValue: custom.rawValue), custom)
        XCTAssertNil(Model(rawValue: "unknown/gpt-server-fixture"))
        XCTAssertNil(Model(rawValue: "anthropic/gpt-server-fixture"))
        XCTAssertNil(Model(rawValue: "openai/ "))
    }

    func testOnlyReadyNonemptyCatalogReconcilesSelection() {
        let selected = Model.codex(.gpt5_4)
        let first = Model.openAI(.gpt4o_mini)
        let source = ChatModelSource()
        for state: ChatModelSource.State in [.loading, .authenticationRequired, .empty,
            .failed("fixture"), .unsupportedCatalog, .ready([]), .direct] {
            source.update(state)
            XCTAssertEqual(source.reconciledSelection(selected), selected)
        }
        source.update(.ready([first, selected]))
        XCTAssertEqual(source.reconciledSelection(selected), selected)
        source.update(.ready([first]))
        XCTAssertEqual(source.reconciledSelection(selected), first)
    }

    func testSettingsCatalogReplacesDirectProviderModelsAndPreservesSelectionOnFailure() {
        let selected = Model.codex(.gpt5_4)
        UserDefaults.model = selected
        let source = ChatModelSource()
        let viewModel = ChatSettingsView.ViewModel(clearMessages: {}, modelSource: source)
        viewModel.loadSettings()
        XCTAssertEqual(viewModel.model, selected)
        XCTAssertTrue(viewModel.isProxyContext)
        XCTAssertFalse(viewModel.canManageAccess)
        XCTAssertEqual(viewModel.availableModels, [])
        source.update(.ready([.openAI(.gpt4o_mini)]))
        XCTAssertEqual(viewModel.availableModels, [.openAI(.gpt4o_mini)])
        XCTAssertEqual(viewModel.model, .openAI(.gpt4o_mini))
        source.update(.failed("fixture"))
        viewModel.saveSettings()
        XCTAssertEqual(UserDefaults.model, .openAI(.gpt4o_mini))
        XCTAssertEqual(viewModel.availableModels, [])
    }

    func testDefaultAndDirectCatalogUseExistingProviderAccessManager() throws {
        let keychain = Keychain(service: "ChatModelSourceTests.\(UUID().uuidString)")
        defer { try? keychain.removeAll() }
        let keys = KeychainService(keychain: keychain)
        keys.saveApiKey(apiKey: "fixture-key", for: .openAI)
        let access = ProviderAccessManager(keychainService: keys, sessionStore: AuthSessionStore(keychain: keychain))
        access.refresh()
        let direct = ChatSettingsView.ViewModel(clearMessages: {})
        direct.accessManager = access
        XCTAssertEqual(direct.availableModels, access.availableChatModels())
        XCTAssertFalse(direct.isProxyContext)
        let source = ChatModelSource(state: .direct)
        let composed = ChatSettingsView.ViewModel(clearMessages: {}, modelSource: source)
        composed.accessManager = access
        XCTAssertEqual(composed.availableModels, direct.availableModels)
        source.update(.ready([.openAI(.gpt4o_mini)]))
        XCTAssertEqual(composed.availableModels, [.openAI(.gpt4o_mini)])
    }
}
