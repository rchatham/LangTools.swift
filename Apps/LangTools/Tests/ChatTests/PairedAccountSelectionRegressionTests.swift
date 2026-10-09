import Anthropic
import Foundation
import HelperLink
import LangTools
import Ollama
import OpenAI
import XCTest
@testable import Chat

/// Memory-only credentials, isolated defaults, and mock URL sessions. Even a
/// regressed direct fallback is intercepted; these tests cannot make paid calls.
@MainActor
final class PairedAccountSelectionRegressionTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var credentials: SelectionMemoryCredentials!
    private var secrets: SelectionMemorySecrets!
    private var keys: SelectionMemoryKeys!
    private var sessions: AuthSessionStore!
    private var selections: AccountTransportSelectionStore!
    private var endpoint: OllamaEndpointConfiguration!
    private var manager: ProviderAccessManager!
    private var mockSession: URLSession!
    private var savedStandardDefaults: [String: Any] = [:]
    private let standardKeys = ["model", "systemMessage", "codexHelperBaseURL"]
    private let helperID = "11111111-1111-4111-8111-111111111111"

    override func setUp() {
        super.setUp()
        // The actual settings model still uses these legacy standard keys.
        // Save/restore only the keys touched, not the whole application domain.
        for key in standardKeys {
            savedStandardDefaults[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
        suite = "PairedAccountSelectionRegressionTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        credentials = SelectionMemoryCredentials()
        secrets = SelectionMemorySecrets()
        keys = SelectionMemoryKeys()
        sessions = AuthSessionStore(secretStore: secrets)
        selections = AccountTransportSelectionStore(userDefaults: defaults, credentialStore: credentials)
        endpoint = OllamaEndpointConfiguration(userDefaults: defaults, credentialStore: credentials)
        mockSession = SelectionURLProtocol.makeSession()
        SelectionNetworkClient.directSession = mockSession
        manager = makeManager()
        SelectionURLProtocol.reset()
    }

    override func tearDown() {
        manager = nil
        selections = nil
        mockSession.invalidateAndCancel()
        SelectionNetworkClient.directSession = nil
        defaults.removePersistentDomain(forName: suite)
        for key in standardKeys {
            if let value = savedStandardDefaults[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        savedStandardDefaults = [:]
        SelectionURLProtocol.reset()
        super.tearDown()
    }

    func testRelaunchKeepsPersistedPairedAccountModelsWithDirectKeysConfigured() async throws {
        try register()
        for provider in AccountLoginProvider.allCases {
            try prepare(provider)
            let selected = model(for: provider)
            XCTAssertTrue(manager.availableChatModels().contains(selected))
            UserDefaults.model = selected
            // Relaunch restores the trusted connection and choice, but not its catalog.
            selections = AccountTransportSelectionStore(userDefaults: defaults, credentialStore: credentials)
            manager = makeManager()
            XCTAssertTrue(selections.snapshot(for: provider).isPaired)
            XCTAssertTrue(selections.snapshot(for: provider).modelIDs.isEmpty)
            try await assertSettingsPreserveUnavailable(provider)
        }
        XCTAssertTrue(SelectionURLProtocol.requests.isEmpty)
    }

    func testSettingsLoadAndSaveWhileActualDiscoveryIsPendingKeepSelection() async throws {
        try register()
        for provider in AccountLoginProvider.allCases {
            try prepare(provider)
            UserDefaults.model = model(for: provider)
            let started = expectation(description: "Pending \(provider) discovery")
            let release = DispatchSemaphore(value: 0)
            let responses = catalogResponses()
            SelectionURLProtocol.handler = { request in
                if request.url?.path == "/v1/mobile/health" {
                    started.fulfill()
                    guard release.wait(timeout: .now() + 5) == .success else { throw URLError(.timedOut) }
                }
                return try responses(request)
            }
            let discovery = Task { await manager.refreshPairedAccount(provider) }
            await fulfillment(of: [started], timeout: 3)
            do {
                XCTAssertTrue(selections.snapshot(for: provider).modelIDs.isEmpty)
                try await assertSettingsPreserveUnavailable(provider)
            } catch {
                release.signal()
                await discovery.value
                throw error
            }
            release.signal()
            await discovery.value
            XCTAssertTrue(manager.availableChatModels().contains(model(for: provider)))
            let settings = makeSettings()
            settings.loadSettings()
            XCTAssertEqual(settings.model, model(for: provider))
            XCTAssertNil(settings.selectedModelUnavailableReason)
            XCTAssertFalse(settings.modelPickerTitle(for: settings.model).contains("Unavailable"))
        }
        XCTAssertEqual(SelectionURLProtocol.directRequests.count, 0)
        XCTAssertTrue(SelectionURLProtocol.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    func testFailedDiscoveryKeepsSelectionAndNeverUsesConfiguredDirectAPIKeys() async throws {
        try register()
        for provider in AccountLoginProvider.allCases {
            try prepare(provider)
            UserDefaults.model = model(for: provider)
            SelectionURLProtocol.handler = { _ in (503, "") }
            await manager.refreshPairedAccount(provider)
            XCTAssertNotNil(selections.snapshot(for: provider).error)
            try await assertSettingsPreserveUnavailable(provider)
        }
        XCTAssertEqual(SelectionURLProtocol.directRequests.count, 0)
        XCTAssertTrue(SelectionURLProtocol.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    func testMissingCapabilityGrantsKeepSelectionAndFailBeforeAnyRequest() async throws {
        try register(capabilities: ["ollama"])
        for provider in AccountLoginProvider.allCases {
            try prepare(provider, publish: false)
            UserDefaults.model = model(for: provider)
            XCTAssertThrowsError(try selections.snapshot(for: provider).requireConnection())
            try await assertSettingsPreserveUnavailable(provider)
        }
        XCTAssertTrue(SelectionURLProtocol.requests.isEmpty)
    }

    func testDisconnectKeepsOpenSettingsSelectionAndPersistsItThroughRelaunch() async throws {
        for provider in AccountLoginProvider.allCases {
            try register()
            try prepare(provider)
            UserDefaults.model = model(for: provider)
            let openSettings = makeSettings()
            openSettings.loadSettings()
            XCTAssertNil(openSettings.selectedModelUnavailableReason)
            try manager.disconnectPairedHelper()
            openSettings.saveSettings()
            XCTAssertEqual(openSettings.model, model(for: provider))
            XCTAssertEqual(UserDefaults.model, model(for: provider))
            XCTAssertNotNil(openSettings.selectedModelUnavailableReason)
            try await assertSettingsPreserveUnavailable(provider)
            selections = AccountTransportSelectionStore(userDefaults: defaults, credentialStore: credentials)
            manager = makeManager()
            try await assertSettingsPreserveUnavailable(provider)
        }
        XCTAssertTrue(SelectionURLProtocol.requests.isEmpty)
    }

    func testDifferentNonemptyCatalogDoesNotImplicitlyReplaceSelectedAccountModel() async throws {
        try register()
        for provider in AccountLoginProvider.allCases {
            try prepare(provider)
            UserDefaults.model = model(for: provider)
            let snapshot = selections.snapshot(for: provider)
            let otherID = provider == .openAI ? "different-codex-fixture" : Anthropic.Model.allCases[1].rawValue
            XCTAssertTrue(selections.publish(modelIDs: [otherID], accountIdentifier: "Fixture Mac", for: snapshot,
                accountSessionRevision: sessions.revision(for: provider)))
            manager.refresh()
            try await assertSettingsPreserveUnavailable(provider)
        }
        XCTAssertTrue(SelectionURLProtocol.requests.isEmpty)
    }

    func testExplicitDirectReplacementStillPersistsAndIsTheOnlyWayToSendDirectly() async throws {
        try register()
        for provider in AccountLoginProvider.allCases {
            try prepare(provider, publish: false)
            UserDefaults.model = model(for: provider)
            let settings = makeSettings()
            settings.loadSettings()
            XCTAssertNotNil(settings.selectedModelUnavailableReason)
            let replacement: Model = provider == .openAI ? .openAI(.gpt4o_mini) : .anthropic(claudeModel())
            settings.model = replacement // Explicit picker selection, not catalog reconciliation.
            settings.saveSettings()
            XCTAssertEqual(UserDefaults.model, replacement)
            XCTAssertNil(settings.selectedModelUnavailableReason)
            XCTAssertTrue(settings.modelPickerTitle(for: replacement).contains("Direct API key"))
            let before = SelectionURLProtocol.directRequests.count
            do {
                _ = try await makeClient().performChatCompletionRequest(messages: [], model: UserDefaults.model)
                XCTFail("Synthetic direct transport always rejects requests")
            } catch {
                XCTAssertEqual(SelectionURLProtocol.directRequests.count, before + 1,
                    "Explicit direct selection reaches only the mock direct transport")
            }
        }
    }

    func testUnrelatedDirectProxyAndOllamaReconciliationSemanticsAreUnchanged() throws {
        let unavailableDirect = Model.openAI(OpenAI.Model(customModelID: "unavailable-direct-fixture"))
        XCTAssertEqual(manager.validateSelectedModel(unavailableDirect), manager.availableChatModels().first)
        XCTAssertEqual(manager.validateSelectedModel(.codex(.gpt5_5)), manager.availableChatModels().first,
            "Unpaired existing-account reconciliation retains its previous behavior")
        let ollama = Model.ollama(try XCTUnwrap(Ollama.Model(rawValue: "unavailable-ollama-fixture")))
        XCTAssertEqual(manager.validateSelectedModel(ollama), ollama)
        UserDefaults.model = ollama
        let direct = makeSettings()
        direct.loadSettings()
        direct.saveSettings()
        XCTAssertEqual(UserDefaults.model, ollama)
        XCTAssertTrue(direct.availableModels.contains(ollama))
        XCTAssertEqual(direct.modelPickerTitle(for: ollama), "\(ollama.rawValue) — Unavailable on current Ollama server")

        UserDefaults.model = .codex(.gpt5_5)
        let source = ChatModelSource(state: .ready([.openAI(.gpt4o_mini)]))
        let proxy = makeSettings(modelSource: source)
        proxy.loadSettings()
        proxy.saveSettings()
        XCTAssertEqual(UserDefaults.model, .openAI(.gpt4o_mini))
        XCTAssertEqual(proxy.availableModels, [.openAI(.gpt4o_mini)])
        XCTAssertEqual(proxy.modelPickerTitle(for: proxy.model), proxy.model.rawValue)
        XCTAssertNil(proxy.selectedModelUnavailableReason)
    }

    private func assertSettingsPreserveUnavailable(_ provider: AccountLoginProvider) async throws {
        let selected = model(for: provider)
        XCTAssertTrue(manager.hasAPIKey(for: .openAI))
        XCTAssertTrue(manager.hasAPIKey(for: .anthropic))
        XCTAssertFalse(manager.availableChatModels().contains(selected))
        let settings = makeSettings()
        settings.loadSettings()
        XCTAssertEqual(settings.model, selected, "Opening settings is not consent to change routes")
        XCTAssertEqual(UserDefaults.model, selected, "loadSettings must not overwrite the persisted route")
        XCTAssertTrue(settings.availableModels.contains(selected), "Actual picker must include its unavailable selection")
        XCTAssertTrue(settings.availableModels.contains { $0.route == .openAI })
        XCTAssertTrue(settings.availableModels.contains { $0.route == .anthropic })
        XCTAssertTrue(settings.modelPickerTitle(for: selected).contains("Unavailable"))
        XCTAssertTrue(settings.modelPickerTitle(for: selected).contains("LangToolsHelper"))
        XCTAssertTrue(try XCTUnwrap(settings.selectedModelUnavailableReason).contains("explicitly choose another model"))
        settings.saveSettings()
        XCTAssertEqual(UserDefaults.model, selected, "Closing settings is not consent to use a direct API key")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "model"), selected.rawValue)

        let before = SelectionURLProtocol.requests.count
        let client = makeClient()
        do {
            _ = try await client.performChatCompletionRequest(messages: [], model: UserDefaults.model)
            XCTFail("Unavailable preserved account selection must fail closed")
        } catch {
            let networkError = error as? NetworkClient.NetworkError
            XCTAssertTrue(networkError == .missingApiKey || networkError == .modelAccessUnavailable(selected.rawValue))
        }
        XCTAssertThrowsError(try client.streamChatCompletionRequest(messages: [], model: UserDefaults.model))
        XCTAssertEqual(SelectionURLProtocol.requests.count, before, "No paired, local, or direct fallback request")
        XCTAssertEqual(SelectionURLProtocol.directRequests.count, 0)
    }

    private func makeManager() -> ProviderAccessManager {
        ProviderAccessManager(keychainService: keys, sessionStore: sessions,
            ollamaEndpointConfiguration: endpoint, accountTransports: selections)
    }
    private func makeSettings(modelSource: ChatModelSource? = nil) -> ChatSettingsView.ViewModel {
        ChatSettingsView.ViewModel(clearMessages: {}, modelSource: modelSource,
            generationSettingsStore: ChatGenerationSettingsStore(userDefaults: defaults),
            conversationSettingsStore: ChatConversationSettingsStore(userDefaults: defaults),
            accessManager: manager, codexHelperTokenStore: CodexHelperTokenStore(defaults: defaults, keychain: secrets))
    }
    private func makeClient() -> NetworkClient {
        SelectionNetworkClient(keychainService: keys, accountLoginService: SelectionNoAccountService(),
            accountProxyTransport: AccountProxyTransport(configuration: AccountBackendConfiguration(
                baseURL: URL(string: "http://127.0.0.1:8080")!,
                codexHelperBaseURL: URL(string: "http://127.0.0.1:8765")!, codexHelperToken: "synthetic-local-token"),
                urlSession: mockSession, selections: selections),
            openAIAccountChatBridge: SelectionNoAccountService(), providerAccessManager: manager,
            ollamaEndpointConfiguration: endpoint, ollamaSession: mockSession,
            generationSettingsProvider: { .automatic })
    }
    private func claudeModel() -> Anthropic.Model { Anthropic.Model.allCases[0] }
    private func model(for provider: AccountLoginProvider) -> Model {
        provider == .openAI ? .codex(.gpt5_5) : .claudeCode(claudeModel())
    }
    private func prepare(_ provider: AccountLoginProvider, publish: Bool = true) throws {
        selections.select(.pairedHelper, for: provider)
        if provider == .claudeCode {
            try sessions.save(AccountSession(provider: provider, accountIdentifier: "Synthetic Claude User",
                accessToken: "synthetic-backend-token", accessibleModelIDs: [claudeModel().rawValue]))
        }
        if publish {
            XCTAssertTrue(selections.publish(modelIDs: [model(for: provider).slug], accountIdentifier: "Fixture Mac",
                for: selections.snapshot(for: provider), accountSessionRevision: sessions.revision(for: provider)))
        }
        manager.refresh()
    }
    private func register(capabilities: [String] = ["claude", "codex", "ollama"]) throws {
        let credential = MobileHelperCredential(endpoint: URL(string: "https://192.168.1.7:8086")!,
            helperID: helperID, fingerprint: String(repeating: "a", count: 64), name: "Fixture Mac",
            deviceID: "22222222-2222-4222-8222-222222222222", token: String(repeating: "c", count: 64),
            capabilities: capabilities)
        try selections.registerPairedHelper(MobileHelperConnection(credential: credential,
            session: SelectionURLProtocol.makeSession()))
    }
    private func catalogResponses() -> (URLRequest) throws -> (Int, String) {
        let helperID = helperID
        let claudeID = claudeModel().rawValue
        return { request in
            switch request.url?.path {
            case "/v1/mobile/health": return (200, #"{"version":1,"helperID":"\#(helperID)","capabilities":["claude","codex","ollama"]}"#)
            case "/v1/account/status": return (200, #"{"provider":"openAI","authenticated":true,"accountIdentifier":"Fixture Mac","accessibleModelIDs":["gpt-5.5"]}"#)
            case "/v1/models/codex": return (200, #"{"models":["gpt-5.5"]}"#)
            case "/v1/claude/models": return (200, #"{"models":["\#(claudeID)"]}"#)
            default: throw URLError(.unsupportedURL)
            }
        }
    }
}

private final class SelectionMemoryCredentials: MobileHelperCredentialStoring, @unchecked Sendable {
    private var records: [String: MobileHelperCredential] = [:]
    func load(helperID: String) throws -> MobileHelperCredential? { records[helperID] }
    func save(_ credential: MobileHelperCredential) throws { records[credential.helperID] = credential }
    func remove(helperID: String) throws { records.removeValue(forKey: helperID) }
}
private final class SelectionMemorySecrets: KeychainSecretStoring {
    private var values: [String: String] = [:]
    func setSecret(_ value: String, forKey key: String) throws { values[key] = value }
    func readSecret(forKey key: String) throws -> String? { values[key] }
    func removeSecret(forKey key: String) throws { values.removeValue(forKey: key) }
}
private final class SelectionMemoryKeys: KeychainService {
    private var apiKeys: [APIService: String] = [.openAI: "synthetic-openai-key", .anthropic: "synthetic-anthropic-key"]
    override func getApiKey(for service: APIService) -> String? { apiKeys[service] }
    override func saveApiKey(apiKey: String, for service: APIService) { apiKeys[service] = apiKey }
    override func deleteApiKey(for service: APIService) { apiKeys.removeValue(forKey: service) }
}
private final class SelectionNetworkClient: NetworkClient {
    static var directSession: URLSession!
    override func langTool(for service: APIService, with apiKey: String) -> (any LangTools)? {
        let baseURL = URL(string: "https://direct-api.invalid/v1/")!
        switch service {
        case .openAI: return OpenAI(baseURL: baseURL, apiKey: apiKey, session: Self.directSession)
        case .anthropic: return Anthropic(baseURL: baseURL, apiKey: apiKey, session: Self.directSession)
        default: return nil
        }
    }
}
private struct SelectionNoAccountService: AccountLoginService, OpenAIAccountChatBridging {
    func beginLogin(for provider: AccountLoginProvider) async throws -> AccountSession { throw MobileHelperError.accountUnavailable }
    func beginCodexHelperLogin() async throws -> AccountSession { throw MobileHelperError.accountUnavailable }
    func refreshSession(_ session: AccountSession) async throws -> AccountSession { throw MobileHelperError.accountUnavailable }
    func handleRedirect(_ url: URL) async throws -> AccountSession { throw MobileHelperError.accountUnavailable }
    func logout(provider: AccountLoginProvider) async throws { throw MobileHelperError.accountUnavailable }
    func logoutCodexHelper() async throws { throw MobileHelperError.accountUnavailable }
    func fetchAccessibleModels(for provider: AccountLoginProvider) async throws -> [String] { throw MobileHelperError.accountUnavailable }
    func performOpenAIChat(messages: [Message], model: Model) async throws -> Message { throw MobileHelperError.accountUnavailable }
}
private final class SelectionURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String))?
    private static let lock = NSLock()
    private static var recorded: [URLRequest] = []
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    static var directRequests: [URLRequest] { requests.filter { $0.url?.host == "direct-api.invalid" } }
    static func reset() { lock.lock(); defer { lock.unlock() }; recorded = []; handler = nil }
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SelectionURLProtocol.self]
        return URLSession(configuration: configuration)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.recorded.append(request); Self.lock.unlock()
        do {
            // Explicit direct requests are recorded and rejected locally, never sent.
            if request.url?.host == "direct-api.invalid" { throw URLError(.notConnectedToInternet) }
            guard let handler = Self.handler else { throw URLError(.unsupportedURL) }
            let (status, body) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
