import XCTest
import OpenAI
import Ollama
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

    func testExplicitOpenAIRouteRejectsSurroundingWhitespace() {
        for slug in [OpenAI.Model.gpt4o_mini.rawValue, "gpt-server-fixture", "vendor/custom-model"] {
            for padding in [" ", "\t", "\n", "\r\n", "\u{00A0}"] {
                for paddedSlug in [padding + slug, slug + padding, padding + slug + padding] {
                    XCTAssertNil(Model(rawValue: "openai/" + paddedSlug),
                                 "Reject padded model ID: \(paddedSlug.debugDescription)")
                }
            }
        }
    }

    func testExplicitOpenAIRoutePreservesValidIDs() {
        XCTAssertEqual(Model(rawValue: "openai/" + OpenAI.Model.gpt4o_mini.rawValue), .openAI(.gpt4o_mini))
        for slug in ["gpt-server-fixture", "vendor/custom-model"] {
            let model = Model(rawValue: "openai/" + slug)
            XCTAssertEqual(model, .openAI(OpenAI.Model(customModelID: slug)))
            XCTAssertEqual(model?.slug, slug)
            XCTAssertEqual(model?.rawValue, "openai/" + slug)
        }
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

    func testProxyOllamaCatalogAndTitlesIgnoreDirectEndpointAvailability() throws {
        let suiteName = "ChatModelSourceTests.proxy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let keychain = Keychain(service: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keys = KeychainService(keychain: keychain)
        let endpoint = OllamaEndpointConfiguration(
            userDefaults: defaults,
            credentialStore: MobileHelperCredentialStore(keychain: keychain)
        )
        let access = ProviderAccessManager(
            keychainService: keys,
            sessionStore: AuthSessionStore(keychain: keychain),
            ollamaEndpointConfiguration: endpoint
        )
        let proxyModel = Model.ollama(try XCTUnwrap(Ollama.Model(rawValue: "server-only-model")))
        let directModel = try XCTUnwrap(Ollama.Model(rawValue: "local-only-model"))
        let source = ChatModelSource(state: .ready([proxyModel]))
        let viewModel = ChatSettingsView.ViewModel(
            clearMessages: {},
            modelSource: source,
            generationSettingsStore: FakeGenSettingsStore(),
            conversationSettingsStore: ChatConversationSettingsStore(userDefaults: defaults),
            accessManager: access,
            codexHelperTokenStore: CodexHelperTokenStore(defaults: defaults, keychain: keys)
        )

        XCTAssertTrue(viewModel.isProxyContext)
        XCTAssertFalse(viewModel.canManageAccess)
        XCTAssertEqual(viewModel.availableModels, [proxyModel])
        XCTAssertEqual(viewModel.model, proxyModel)
        XCTAssertFalse(access.availableChatModels().contains(proxyModel))
        XCTAssertEqual(viewModel.modelPickerTitle(for: proxyModel), proxyModel.rawValue)

        let snapshot = try endpoint.update("http://local-fixture.local:11434")
        XCTAssertTrue(endpoint.storeModels([directModel], for: snapshot))
        access.refresh()
        XCTAssertTrue(access.availableChatModels().contains(.ollama(directModel)))
        XCTAssertEqual(viewModel.availableModels, [proxyModel], "Local discovery must not enter the server catalog")
        XCTAssertEqual(viewModel.modelPickerTitle(for: proxyModel), proxyModel.rawValue)

        source.update(.failed("catalog fixture"))
        XCTAssertEqual(viewModel.availableModels, [])
        XCTAssertEqual(viewModel.model, proxyModel, "Catalog failures preserve the server selection")
        XCTAssertEqual(viewModel.modelPickerTitle(for: proxyModel), proxyModel.rawValue)

        source.update(.direct)
        XCTAssertTrue(viewModel.availableModels.contains(.ollama(directModel)))
        XCTAssertEqual(viewModel.modelPickerTitle(for: proxyModel),
                       "\(proxyModel.rawValue) — Unavailable on current Ollama server")
    }

    func testLoadSettingsReconcilesProxyModelAndLoadsGenerationSettings() throws {
        let savedModel = Model.openAI(OpenAI.Model(customModelID: "gpt-server-fixture"))
        UserDefaults.model = savedModel
        let store = FakeGenSettingsStore(settings: try ChatGenerationSettings(maxOutputTokens: 2048, temperature: 0.5))
        let source = ChatModelSource()
        let viewModel = ChatSettingsView.ViewModel(
            clearMessages: {},
            modelSource: source,
            generationSettingsStore: store
        )
        source.update(.ready([.openAI(.gpt4o_mini), savedModel]))
        viewModel.loadSettings()
        XCTAssertEqual(viewModel.model, savedModel, "existing selection preserved when present in catalog")
        XCTAssertEqual(viewModel.generationSettings.maxOutputTokens, 2048)
        XCTAssertEqual(viewModel.generationSettings.temperature, 0.5)
        XCTAssertEqual(store.loadCount, 1)
    }

    func testSaveSettingsPersistsProxyModelAndGenerationSettings() throws {
        let selected = Model.openAI(OpenAI.Model(customModelID: "gpt-server-fixture"))
        let store = FakeGenSettingsStore()
        let source = ChatModelSource()
        let viewModel = ChatSettingsView.ViewModel(
            clearMessages: {},
            modelSource: source,
            generationSettingsStore: store
        )
        source.update(.ready([.openAI(.gpt4o_mini), selected]))
        viewModel.model = selected
        viewModel.generationSettings = try ChatGenerationSettings(maxOutputTokens: 4096, temperature: 0.25)
        source.update(.failed("fixture"))
        viewModel.saveSettings()
        XCTAssertEqual(UserDefaults.model, selected)
        XCTAssertEqual(Model(rawValue: selected.rawValue), selected)
        XCTAssertEqual(store.saveCount, 1)
        XCTAssertEqual(store.settings.maxOutputTokens, 4096)
        XCTAssertEqual(store.settings.temperature, 0.25)
    }

    func testLoadSettingsWithInjectedStoreUsesProvidedStore() throws {
        let store = FakeGenSettingsStore(settings: try ChatGenerationSettings(maxOutputTokens: 512, temperature: 0.9))
        let viewModel = ChatSettingsView.ViewModel(
            clearMessages: {},
            generationSettingsStore: store
        )
        viewModel.loadSettings()
        XCTAssertEqual(store.loadCount, 1)
        XCTAssertEqual(viewModel.generationSettings.maxOutputTokens, 512)
        XCTAssertEqual(viewModel.generationSettings.temperature, 0.9)
    }

    func testSaveSettingsWithInjectedStoreSavesToProvidedStore() throws {
        let store = FakeGenSettingsStore()
        let viewModel = ChatSettingsView.ViewModel(
            clearMessages: {},
            generationSettingsStore: store
        )
        viewModel.generationSettings = try ChatGenerationSettings(maxOutputTokens: 1024, temperature: 0.6)
        viewModel.saveSettings()
        XCTAssertEqual(store.saveCount, 1)
        XCTAssertEqual(store.settings.maxOutputTokens, 1024)
        XCTAssertEqual(store.settings.temperature, 0.6)
        XCTAssertNil(viewModel.generationSettingsError)
    }

    // MARK: - Independent model preservation

    private var testOllamaModel: Model {
        Model(rawValue: "ollama/test-model")!
    }
    private var testOllamaCloudModel: Model {
        Model(rawValue: "ollama-cloud/test-cloud")!
    }

    func testIndependentModelsDoNotAppearInHostedModels() {
        let source = ChatModelSource()
        source.updateIndependentModels([testOllamaModel])
        source.update(.ready([.openAI(.gpt4o_mini)]))
        // Hosted models should not include ollama
        XCTAssertFalse(source.models.contains(testOllamaModel))
        // allModels should include both
        XCTAssertTrue(source.allModels.contains(testOllamaModel))
        XCTAssertTrue(source.allModels.contains(.openAI(.gpt4o_mini)))
    }

    func testIndependentModelsRejectsOrdinaryHostedRoutes() {
        let source = ChatModelSource()
        source.updateIndependentModels([
            testOllamaModel,
            testOllamaCloudModel,
            .openAI(.gpt4o_mini), // should be filtered out
            .anthropic(.claude46Sonnet)  // should be filtered out
        ])
        XCTAssertEqual(source.independentModels.count, 2)
        XCTAssertTrue(source.independentModels.contains(testOllamaModel))
        XCTAssertTrue(source.independentModels.contains(testOllamaCloudModel))
        XCTAssertFalse(source.independentModels.contains(.openAI(.gpt4o_mini)))
    }

    func testOllamaSelectionSurvivesCatalogStateChanges() {
        UserDefaults.model = testOllamaModel
        let source = ChatModelSource()
        for state: ChatModelSource.State in [
            .loading, .authenticationRequired, .empty,
            .failed("fixture"), .unsupportedCatalog, .ready([]), .direct,
            .ready([.openAI(.gpt4o_mini)])
        ] {
            source.update(state)
            XCTAssertEqual(source.reconciledSelection(testOllamaModel), testOllamaModel,
                           "ollama selection must survive state: \(state)")
        }
    }

    func testOllamaCloudSelectionSurvivesCatalogStateChanges() {
        UserDefaults.model = testOllamaCloudModel
        let source = ChatModelSource()
        for state: ChatModelSource.State in [
            .loading, .authenticationRequired, .empty,
            .failed("fixture"), .unsupportedCatalog, .ready([]), .direct,
            .ready([.openAI(.gpt4o_mini)])
        ] {
            source.update(state)
            XCTAssertEqual(source.reconciledSelection(testOllamaCloudModel), testOllamaCloudModel,
                           "ollamaCloud selection must survive state: \(state)")
        }
    }

    func testOrdinarySelectionReconcilesNormally() {
        let source = ChatModelSource()
        let selected = Model.codex(.gpt5_4)
        source.update(.ready([.openAI(.gpt4o_mini)]))
        XCTAssertEqual(source.reconciledSelection(selected), .openAI(.gpt4o_mini))
    }

    func testVMStateSinkReconcilesOrdinarySelectionUsingEmittedReadyState() {
        UserDefaults.model = .openAI(.gpt4o)
        let source = ChatModelSource()
        let vm = ChatSettingsView.ViewModel(clearMessages: {}, modelSource: source)
        vm.loadSettings()
        source.update(.ready([.openAI(.gpt4o_mini)]))
        XCTAssertEqual(vm.model, .openAI(.gpt4o_mini))
    }

    func testVMStateSinkPreservesLocalCloudSelectionThroughReady() {
        UserDefaults.model = testOllamaModel
        let source = ChatModelSource()
        let vm = ChatSettingsView.ViewModel(clearMessages: {}, modelSource: source)
        vm.loadSettings()
        source.update(.ready([.openAI(.gpt4o_mini)]))
        XCTAssertEqual(vm.model, testOllamaModel,
                       "ollama model should not be replaced by first hosted model")
    }

    func testVMStateSinkPreservesCloudSelectionThroughReady() {
        UserDefaults.model = testOllamaCloudModel
        let source = ChatModelSource()
        let vm = ChatSettingsView.ViewModel(clearMessages: {}, modelSource: source)
        vm.loadSettings()
        source.update(.ready([.openAI(.gpt4o_mini)]))
        XCTAssertEqual(vm.model, testOllamaCloudModel,
                       "cloud model should not be replaced by first hosted model")
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

private final class FakeGenSettingsStore: ChatGenerationSettingsStoring {
    var settings: ChatGenerationSettings
    private(set) var loadCount = 0
    private(set) var saveCount = 0
    private(set) var resetCount = 0

    init(settings: ChatGenerationSettings = .automatic) {
        self.settings = settings
    }

    func load() -> ChatGenerationSettings {
        loadCount += 1
        return settings
    }

    func save(_ settings: ChatGenerationSettings) {
        saveCount += 1
        self.settings = settings
    }

    func reset() {
        resetCount += 1
        settings = .automatic
    }
}
