import XCTest
import KeychainAccess
import Anthropic
import OpenAI
import OpenRouter
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
            [.openAI, .codex, .anthropic, .claudeCode, .xAI, .gemini, .openRouter]
                + CompatibleProvider.allCases.map(\.accessDestination)
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

    // MARK: - OpenRouter

    private func makeOpenRouterCatalog(fetcher: @escaping OpenRouterModelCatalog.Fetcher = { _ in [] }) -> OpenRouterModelCatalog {
        let suiteName = "ProviderAccessManagerTests.OpenRouter.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return OpenRouterModelCatalog(userDefaults: defaults, fetcher: fetcher)
    }

    func testOpenRouterKeyOffersTheAutoRouterBeforeTheCatalogLoads() throws {
        let manager = ProviderAccessManager(keychainService: keychainService, sessionStore: sessionStore, openRouterCatalog: makeOpenRouterCatalog())
        XCTAssertTrue(manager.state(for: .openRouter).availableModels.isEmpty, "no key means no OpenRouter models")

        keychainService.saveApiKey(apiKey: "or-key", for: .openRouter)
        manager.refresh()

        XCTAssertEqual(manager.state(for: .openRouter).availableModels, [.openRouter(.auto)])
        XCTAssertTrue(manager.availableChatModels().contains(.openRouter(.auto)))
        let accessState = manager.statesForAccessUI().first { $0.accessDestination == .openRouter }
        XCTAssertEqual(accessState?.authStatus, .apiKeyConfigured)
        XCTAssertNil(manager.unavailableReason(for: try XCTUnwrap(accessState)))
    }

    @MainActor
    func testOpenRouterCatalogRefreshPopulatesAvailableModels() async throws {
        let catalog = makeOpenRouterCatalog { apiKey in
            XCTAssertEqual(apiKey, "or-key")
            return [
                .init(id: "openai/gpt-4o", name: "OpenAI: GPT-4o", contextLength: 128_000, supportedParameters: ["tools"]),
                .init(id: "anthropic/claude-sonnet-4.5", supportedParameters: ["tools", "structured_outputs"]),
                .init(id: "openrouter/auto"),
                .init(id: "meta-llama/llama-3.2-3b-instruct:free", supportedParameters: ["temperature"]),
            ]
        }
        keychainService.saveApiKey(apiKey: "or-key", for: .openRouter)
        let manager = ProviderAccessManager(keychainService: keychainService, sessionStore: sessionStore, openRouterCatalog: catalog)

        let entries = try await catalog.refresh(apiKey: "or-key")
        manager.refresh()

        XCTAssertEqual(entries.map(\.id), ["anthropic/claude-sonnet-4.5", "meta-llama/llama-3.2-3b-instruct:free", "openai/gpt-4o", "openrouter/auto"], "entries are sorted by slug")
        XCTAssertEqual(manager.state(for: .openRouter).availableModels.map(\.rawValue), [
            "openrouter/openrouter/auto",
            "openrouter/anthropic/claude-sonnet-4.5",
            "openrouter/meta-llama/llama-3.2-3b-instruct:free",
            "openrouter/openai/gpt-4o",
        ], "the router leads and is not duplicated")
        XCTAssertEqual(catalog.entry(for: "openai/gpt-4o")?.contextLength, 128_000)
        XCTAssertEqual(catalog.entry(for: "meta-llama/llama-3.2-3b-instruct:free")?.supportsTools, false)
    }

    func testOpenRouterCatalogFailureKeepsTheCachedCatalog() async {
        struct Unreachable: Error {}
        let catalog = makeOpenRouterCatalog { _ in throw Unreachable() }
        catalog.store([.init(id: "openai/gpt-4o", supportsTools: true)])

        do {
            try await catalog.refresh(apiKey: "or-key")
            XCTFail("Expected the fetch to fail")
        } catch {}

        XCTAssertEqual(catalog.entries().map(\.id), ["openai/gpt-4o"])
    }

    func testOpenRouterCatalogPersistsAcrossInstances() {
        let suiteName = "ProviderAccessManagerTests.OpenRouter.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        OpenRouterModelCatalog(userDefaults: defaults).store([.init(id: "b/model", supportsTools: true), .init(id: "a/model", supportsTools: false)])

        XCTAssertEqual(OpenRouterModelCatalog(userDefaults: defaults).models(), [.auto, "a/model", "b/model"])
    }

    func testOpenRouterCatalogDropsEntriesWithInvalidSlugs() {
        let catalog = makeOpenRouterCatalog()
        catalog.store([
            .init(id: "openai/gpt-4o", supportsTools: true),
            .init(id: "", supportsTools: true),
            .init(id: "  ", supportsTools: true),
            .init(id: " padded/model ", supportsTools: true),
        ])

        XCTAssertEqual(catalog.entries().map(\.id), ["openai/gpt-4o"])
        XCTAssertEqual(catalog.models(), [.auto, "openai/gpt-4o"])
    }

    func testOpenRouterModelsRoundTripThroughRoutedRawValues() {
        for model in [Model.openRouter("anthropic/claude-sonnet-4.5"), .openRouter(.auto), .openRouter("meta-llama/llama-3.2-3b-instruct:free")] {
            XCTAssertEqual(Model(rawValue: model.rawValue), model, model.rawValue)
        }
        XCTAssertEqual(Model.openRouter(.auto).rawValue, "openrouter/openrouter/auto")
        XCTAssertEqual(Model.openRouter("anthropic/claude-sonnet-4.5").slug, "anthropic/claude-sonnet-4.5")
        XCTAssertNil(Model(rawValue: "openrouter/ anthropic/claude-sonnet-4.5"), "padded slugs are rejected")
        XCTAssertEqual(Model.openRouter("x/y").apiService, .openRouter)
        XCTAssertEqual(AccessDestination.destination(for: .openRouter("x/y")), .openRouter)
        XCTAssertEqual(AccessDestination.platform(for: .openRouter), .openRouter)
        XCTAssertEqual(AccessDestination.openRouter.service, .openRouter)
    }

    // MARK: - OpenAI-compatible providers

    private func makeCompatibleCatalog(fetcher: @escaping CompatibleModelCatalog.Fetcher = { _, _ in [] }) -> CompatibleModelCatalog {
        let suiteName = "ProviderAccessManagerTests.Compatible.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return CompatibleModelCatalog(userDefaults: defaults, fetcher: fetcher)
    }

    func testCompatibleProviderKeyOffersSuggestedModelsBeforeTheCatalogLoads() throws {
        let manager = ProviderAccessManager(keychainService: keychainService, sessionStore: sessionStore, compatibleCatalog: makeCompatibleCatalog())
        XCTAssertTrue(manager.state(for: .groq).availableModels.isEmpty, "no key means no Groq models")

        keychainService.saveApiKey(apiKey: "groq-key", for: .groq)
        manager.refresh()

        XCTAssertEqual(manager.state(for: .groq).availableModels, CompatibleProvider.groq.knownModelIDs.map { .compatible(.groq, $0) })
        let accessState = try XCTUnwrap(manager.statesForAccessUI().first { $0.accessDestination == .groq })
        XCTAssertEqual(accessState.authStatus, .apiKeyConfigured)
        XCTAssertEqual(accessState.displayName, "Groq")
        XCTAssertNil(manager.unavailableReason(for: accessState))
        XCTAssertTrue(manager.state(for: .mistral).availableModels.isEmpty, "keys are per provider")
    }

    @MainActor
    func testCompatibleCatalogRefreshKeepsOnlyChatModels() async throws {
        let catalog = makeCompatibleCatalog { provider, apiKey in
            XCTAssertEqual(provider, .groq)
            XCTAssertEqual(apiKey, "groq-key")
            return [
                .init(id: "llama-3.3-70b-versatile", contextWindow: 131_072),
                .init(id: "whisper-large-v3", isChatModel: false),
                .init(id: "openai/gpt-oss-120b", supportsTools: true),
            ]
        }
        keychainService.saveApiKey(apiKey: "groq-key", for: .groq)
        let manager = ProviderAccessManager(keychainService: keychainService, sessionStore: sessionStore, compatibleCatalog: catalog)

        try await catalog.refresh(.groq, apiKey: "groq-key")
        manager.refresh()

        XCTAssertEqual(manager.state(for: .groq).availableModels.map(\.rawValue), [
            "groq/llama-3.3-70b-versatile",
            "groq/openai/gpt-oss-120b",
        ])
        XCTAssertEqual(catalog.entry(for: .groq, id: "llama-3.3-70b-versatile")?.contextLength, 131_072)
    }

    /// `CompatibleProvider`, `APIService`, `ModelRoute`, and `AccessDestination`
    /// share raw values and convert with force unwraps; a case missing from one
    /// of them would trap at runtime.
    func testCompatibleProviderCasesExistInEveryProviderEnum() {
        for provider in CompatibleProvider.allCases {
            XCTAssertEqual(provider.service.rawValue, provider.rawValue)
            XCTAssertEqual(provider.route.rawValue, provider.rawValue)
            XCTAssertEqual(provider.accessDestination.rawValue, provider.rawValue)
            XCTAssertEqual(CompatibleProvider(service: provider.service), provider)
            XCTAssertEqual(provider.accessDestination.service, provider.service)
            XCTAssertEqual(provider.accessDestination.displayName, provider.displayName)
            XCTAssertEqual(AccessDestination.destination(for: .compatible(provider, "model")), provider.accessDestination)
            XCTAssertEqual(AccessDestination.platform(for: provider.service), provider.accessDestination)
        }
    }

    func testCompatibleProviderWithoutAModelCatalogKeepsSuggestedModels() async throws {
        let catalog = makeCompatibleCatalog { _, _ in
            XCTFail("Perplexity has no catalog endpoint")
            return []
        }

        let entries = try await catalog.refresh(.perplexity, apiKey: "pplx-key")

        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(catalog.modelIDs(for: .perplexity), CompatibleProvider.perplexity.knownModelIDs)
    }

    func testCompatibleCatalogFailureKeepsTheCachedCatalog() async {
        struct Unreachable: Error {}
        let catalog = makeCompatibleCatalog { _, _ in throw Unreachable() }
        catalog.store([.init(id: "mistral-large-latest", supportsTools: true)], for: .mistral)

        do {
            try await catalog.refresh(.mistral, apiKey: "key")
            XCTFail("Expected the fetch to fail")
        } catch {}

        XCTAssertEqual(catalog.modelIDs(for: .mistral), ["mistral-large-latest"])
    }

    func testCompatibleModelsRoundTripThroughRoutedRawValues() {
        for provider in CompatibleProvider.allCases {
            let model = Model.compatible(provider, provider.knownModelIDs[0])
            XCTAssertEqual(Model(rawValue: model.rawValue), model, model.rawValue)
            XCTAssertEqual(model.apiService, provider.service)
            XCTAssertEqual(AccessDestination.destination(for: model), provider.accessDestination)
            XCTAssertEqual(AccessDestination.platform(for: provider.service), provider.accessDestination)
            XCTAssertEqual(provider.accessDestination.service, provider.service)
        }
        XCTAssertEqual(Model.compatible(.vercel, "anthropic/claude-sonnet-4.5").rawValue, "vercel/anthropic/claude-sonnet-4.5")
        XCTAssertNil(Model(rawValue: "groq/"), "an empty slug is not an Ollama model name")
        XCTAssertNil(Model(rawValue: "groq/ llama"), "padded slugs are rejected")
    }

    func testPickerGroupsModelsByProviderAndFilters() {
        let models: [Model] = [.openAI(.gpt4o), .compatible(.groq, "llama-3.3-70b-versatile"), .openAI(.gpt4o_mini), .openRouter(.auto)]

        XCTAssertEqual(Model.pickerGroups(models).map(\.title), ["OpenAI Platform", "Groq", "OpenRouter"])
        XCTAssertEqual(Model.pickerGroups(models, matching: "groq llama").flatMap(\.models), [.compatible(.groq, "llama-3.3-70b-versatile")])
        XCTAssertEqual(Model.pickerGroups(models, matching: "GPT-4O-MINI").flatMap(\.models), [.openAI(.gpt4o_mini)])
        XCTAssertEqual(Model.pickerGroups(models, matching: "no match", keeping: .openRouter(.auto)).flatMap(\.models), [.openRouter(.auto)], "the selection stays visible")
    }
}
