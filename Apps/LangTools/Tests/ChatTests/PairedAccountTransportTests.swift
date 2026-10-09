import Anthropic
import Foundation
import HelperLink
import LangTools
import OpenAI
import XCTest
@testable import Chat

/// All credentials and sessions are synthetic and memory-backed. No Keychain,
/// provider accounts, helper daemon or fixed server ports are used.
@MainActor
final class PairedAccountTransportTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var credentials: AccountMemoryCredentials!
    private var selections: AccountTransportSelectionStore!
    private var urlSession: URLSession!
    private var secrets: AccountMemorySecrets!
    private var sessionStore: AuthSessionStore!
    private var keys: AccountMemoryKeys!
    private var manager: ProviderAccessManager!
    private var ollamaConfiguration: OllamaEndpointConfiguration!
    private let helperID = "11111111-1111-4111-8111-111111111111"
    private let deviceToken = String(repeating: "c", count: 64)

    override func setUp() {
        super.setUp()
        suite = "PairedAccountTransportTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        credentials = AccountMemoryCredentials()
        selections = AccountTransportSelectionStore(userDefaults: defaults, credentialStore: credentials)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PairedAccountURLProtocol.self]
        urlSession = URLSession(configuration: config)
        secrets = AccountMemorySecrets()
        sessionStore = AuthSessionStore(secretStore: secrets)
        keys = AccountMemoryKeys()
        ollamaConfiguration = OllamaEndpointConfiguration(userDefaults: defaults, credentialStore: credentials)
        manager = ProviderAccessManager(keychainService: keys, sessionStore: sessionStore,
            ollamaEndpointConfiguration: ollamaConfiguration,
            accountTransports: selections)
        PairedAccountURLProtocol.reset()
    }
    override func tearDown() {
        manager = nil
        selections = nil
        urlSession.invalidateAndCancel()
        defaults.removePersistentDomain(forName: suite)
        PairedAccountURLProtocol.reset()
        super.tearDown()
    }

    func testDefaultsPairingDoesNotSelectAccountsAndChoicesPersistIndependently() throws {
        XCTAssertEqual(selections.snapshot(for: .openAI).choice, .existing)
        XCTAssertEqual(selections.snapshot(for: .claudeCode).choice, .existing)
        try register()
        XCTAssertEqual(selections.snapshot(for: .openAI).label, "Local Codex helper")
        XCTAssertEqual(selections.snapshot(for: .claudeCode).label, "Claude Code backend")
        selections.select(.pairedHelper, for: .openAI)
        let restored = AccountTransportSelectionStore(userDefaults: defaults, credentialStore: credentials)
        XCTAssertTrue(restored.snapshot(for: .openAI).isPaired)
        XCTAssertEqual(restored.snapshot(for: .openAI).helperID, helperID)
        XCTAssertEqual(restored.snapshot(for: .claudeCode).choice, .existing)
        XCTAssertTrue(restored.snapshot(for: .openAI).connection?.session.delegate is MobileHelperSessionDelegate)
        XCTAssertTrue(restored.snapshot(for: .openAI).modelIDs.isEmpty, "A restored connection must rediscover, not restore a stale account catalog")
        XCTAssertFalse(String(describing: defaults.dictionaryRepresentation()).contains(deviceToken))
    }

    func testMissingPairingAndMissingGrantsFailBeforeNetworkWithNoFallback() async throws {
        for grants in [nil, ["ollama"]] {
            if let grants { try register(capabilities: grants) }
            selections.select(.pairedHelper, for: .openAI)
            let transport = transport()
            do {
                _ = try await transport.performChatCompletionRequest(messages: [], model: .codex(.gpt5_5), session: codexSession(), tools: nil, toolChoice: nil)
                XCTFail("Expected fail-closed route")
            } catch { XCTAssertTrue(error is MobileHelperError) }
            XCTAssertTrue(PairedAccountURLProtocol.requests.isEmpty)
        }
        try register(capabilities: ["codex"])
        selections.select(.pairedHelper, for: .claudeCode)
        do {
            _ = try await transport().performChatCompletionRequest(messages: [], model: .claudeCode(claudeModel()), session: claudeSession(), tools: nil, toolChoice: nil)
            XCTFail("Expected missing Claude grant")
        } catch { XCTAssertEqual(error as? MobileHelperError, .missingCapability("claude")) }
        XCTAssertTrue(PairedAccountURLProtocol.requests.isEmpty)
    }

    func testArbitraryHTTPSDefaultsCannotBecomePairedRouteAndStrictLocalGateRemains() async throws {
        defaults.set("https://192.168.1.7:8086", forKey: "codexHelperBaseURL")
        selections.select(.pairedHelper, for: .openAI)
        XCTAssertThrowsError(try selections.snapshot(for: .openAI).requireConnection())
        selections.select(.existing, for: .openAI)
        let transport = AccountProxyTransport(configuration: AccountBackendConfiguration(
            baseURL: URL(string: "http://127.0.0.1:8080")!,
            codexHelperBaseURL: URL(string: "https://192.168.1.7:8086")!, codexHelperToken: "local-token"),
            urlSession: urlSession, selections: selections)
        do {
            _ = try await transport.performChatCompletionRequest(messages: [], model: .codex(.gpt5_5), session: codexSession(), tools: nil, toolChoice: nil)
            XCTFail("Strict loopback gate must reject LAN defaults")
        } catch { XCTAssertTrue(error.localizedDescription.contains("loopback")) }
        XCTAssertTrue(PairedAccountURLProtocol.requests.isEmpty)
    }

    func testCodexChatAndConversationCleanupUseDeviceTokenNotOAuthOrLocalToken() async throws {
        try register()
        selections.select(.pairedHelper, for: .openAI)
        PairedAccountURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "192.168.1.7")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(self.deviceToken)")
            XCTAssertNil(request.value(forHTTPHeaderField: "X-LangTools-Account-Token"))
            return (request.httpMethod == "DELETE" ? 204 : 200, request.httpMethod == "DELETE" ? "" : #"{"content":"hello"}"#)
        }
        let id = UUID()
        let transport = transport()
        let message = try await transport.performChatCompletionRequest(messages: [Message(text: "hi", role: .user)], model: .codex(.gpt5_5), session: codexSession(), conversationID: id, tools: nil, toolChoice: nil)
        XCTAssertEqual(message.text, "hello")
        selections.select(.existing, for: .openAI)
        await transport.endConversation(id: id)
        XCTAssertEqual(PairedAccountURLProtocol.requests.map { $0.url!.path }, ["/v1/account/chat/completions", "/v1/account/conversations/\(id.uuidString.lowercased())"])
    }

    func testCodexOAuthCredentialRejectedBeforeSendingAnything() async throws {
        try register()
        selections.select(.pairedHelper, for: .openAI)
        let session = AccountSession(provider: .openAI, accountIdentifier: "user", accessToken: "oauth-must-not-travel")
        do {
            _ = try await transport().performChatCompletionRequest(messages: [], model: .codex(.gpt5_5), session: session, tools: nil, toolChoice: nil)
            XCTFail("OAuth is not a Codex helper credential")
        } catch { XCTAssertEqual(error as? AccountBackendConfigurationError, .credentialMismatch(.codexHelper)) }
        XCTAssertTrue(PairedAccountURLProtocol.requests.isEmpty)
    }

    func testClaudeTokenSeparationAndAccountSessionRequired() async throws {
        try register()
        selections.select(.pairedHelper, for: .claudeCode)
        PairedAccountURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/claude/chat/completions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(self.deviceToken)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-LangTools-Account-Token"), "backend-account-token")
            return (200, #"{"content":"claude"}"#)
        }
        let result = try await transport().performChatCompletionRequest(messages: [], model: .claudeCode(claudeModel()), session: claudeSession(), tools: nil, toolChoice: nil)
        XCTAssertEqual(result.text, "claude")
        XCTAssertThrowsError(try PairedAccountRoute(snapshot: selections.snapshot(for: .claudeCode), session: nil))
    }

    func testStreamingCapturesRouteBeforeTaskAndFutureRequestsUseNewSelection() async throws {
        try register()
        selections.select(.pairedHelper, for: .openAI)
        PairedAccountURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "192.168.1.7")
            return (200, #"{"type":"delta","delta":"hi"}"# + "\n" + #"{"type":"complete","content":"hi"}"# + "\n")
        }
        let transport = transport()
        let stream = try transport.streamChatCompletionRequest(messages: [], model: .codex(.gpt5_5), session: codexSession(), stream: true, tools: nil, toolChoice: nil)
        try selections.disconnectHelper()
        var text = ""
        for try await delta in stream { text += delta }
        XCTAssertEqual(text, "hi")
        XCTAssertThrowsError(try transport.streamChatCompletionRequest(messages: [], model: .codex(.gpt5_5), session: codexSession(), stream: true, tools: nil, toolChoice: nil))
        XCTAssertEqual(PairedAccountURLProtocol.requests.count, 1)
    }

    func testNonstreamingStreamCapturesRouteAndLeaseSurvivesDisconnect() async throws {
        try register()
        selections.select(.pairedHelper, for: .openAI)
        PairedAccountURLProtocol.handler = { _ in (200, #"{"content":"hello"}"#) }
        var snapshot: AccountTransportSelectionStore.Snapshot? = selections.snapshot(for: .openAI)
        weak var lease = snapshot?.connection?.sessionLease
        let stream = try transport().streamChatCompletionRequest(messages: [], model: .codex(.gpt5_5), session: codexSession(), stream: false, tools: nil, toolChoice: nil)
        try selections.disconnectHelper()
        snapshot = nil
        XCTAssertNotNil(lease)
        var text = ""
        for try await delta in stream { text += delta }
        XCTAssertEqual(text, "hello")
        let deadline = Date().addingTimeInterval(2)
        while lease != nil && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertNil(lease)
    }

    func testCatalogDiscoveryReadOnlyStatusAndModelsCreatesOnlyCodexMarker() async throws {
        try register()
        selections.select(.pairedHelper, for: .openAI)
        installCatalogResponses()
        await manager.refreshPairedAccount(.openAI)
        XCTAssertEqual(PairedAccountURLProtocol.requests.map { $0.url!.path }, ["/v1/mobile/health", "/v1/account/status", "/v1/models/codex"])
        XCTAssertTrue(PairedAccountURLProtocol.requests.allSatisfy { $0.httpMethod == "GET" })
        XCTAssertTrue(PairedAccountURLProtocol.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(deviceToken)" })
        let session = try XCTUnwrap(manager.session(for: .openAI))
        XCTAssertEqual(session.accessToken, CodexSessionMarker.value)
        XCTAssertNil(session.refreshToken)
        XCTAssertEqual(session.accountIdentifier, "Signed-in Mac")
        XCTAssertEqual(manager.availableChatModels().map(\.rawValue), ["codex/gpt-5.5"])
        XCTAssertTrue(secrets.values.isEmpty, "Discovery does not save OAuth/session credentials on the phone")
    }

    func testClaudeCatalogNeedsExistingBackendSessionAndUsesRelayPath() async throws {
        try register()
        selections.select(.pairedHelper, for: .claudeCode)
        await manager.refreshPairedAccount(.claudeCode)
        XCTAssertTrue(PairedAccountURLProtocol.requests.isEmpty)
        XCTAssertNil(manager.session(for: .claudeCode))
        try sessionStore.save(claudeSession())
        installCatalogResponses()
        await manager.refreshPairedAccount(.claudeCode)
        XCTAssertEqual(PairedAccountURLProtocol.requests.map { $0.url!.path }, ["/v1/mobile/health", "/v1/claude/models"])
        XCTAssertNil(PairedAccountURLProtocol.requests[0].value(forHTTPHeaderField: "X-LangTools-Account-Token"))
        XCTAssertEqual(PairedAccountURLProtocol.requests[1].value(forHTTPHeaderField: "X-LangTools-Account-Token"), "backend-account-token")
        XCTAssertEqual(manager.session(for: .claudeCode)?.accessToken, "backend-account-token")
        XCTAssertEqual(manager.availableChatModels().map(\.route), [.claudeCode])
    }

    func testCatalogLossAndAToBToARejectStalePublicationsAndPriorModels() throws {
        try register()
        selections.select(.pairedHelper, for: .openAI)
        let a = selections.snapshot(for: .openAI)
        XCTAssertTrue(selections.publish(modelIDs: ["gpt-5.5"], accountIdentifier: "a", for: a))
        manager.refresh()
        XCTAssertFalse(manager.availableChatModels().isEmpty)
        try register(helperID: "33333333-3333-4333-8333-333333333333", name: "Mac B")
        XCTAssertTrue(manager.availableChatModels().isEmpty)
        let b = selections.snapshot(for: .openAI)
        try register()
        XCTAssertFalse(selections.publish(modelIDs: ["old-a"], accountIdentifier: "a", for: a))
        XCTAssertFalse(selections.publish(modelIDs: ["old-b"], accountIdentifier: "b", for: b))
        let fresh = selections.snapshot(for: .openAI)
        XCTAssertTrue(selections.publish(modelIDs: ["gpt-5.5"], accountIdentifier: "new-a", for: fresh))
        XCTAssertTrue(selections.fail(MobileHelperError.unavailable, for: fresh))
        XCTAssertTrue(manager.availableChatModels().isEmpty)
        XCTAssertNil(manager.session(for: .openAI))
    }

    func testRevocationRedirectOrUnavailableClearsCatalogWithoutFallback() async throws {
        for status in [401, 403, 307, 503] {
            try register()
            selections.select(.pairedHelper, for: .openAI)
            let snapshot = selections.snapshot(for: .openAI)
            XCTAssertTrue(selections.publish(modelIDs: ["gpt-5.5"], accountIdentifier: "mac", for: snapshot))
            PairedAccountURLProtocol.handler = { _ in (status, "") }
            do {
                _ = try await transport().performChatCompletionRequest(messages: [], model: .codex(.gpt5_5), session: codexSession(), tools: nil, toolChoice: nil)
                XCTFail("Expected helper failure")
            } catch { XCTAssertTrue(error is MobileHelperError) }
            XCTAssertTrue(selections.snapshot(for: .openAI).isPaired)
            XCTAssertTrue(manager.availableChatModels().isEmpty)
            XCTAssertNil(manager.session(for: .openAI))
        }
        XCTAssertEqual(PairedAccountURLProtocol.requests.count, 4)
        XCTAssertTrue(PairedAccountURLProtocol.requests.allSatisfy { $0.url?.host == "192.168.1.7" })
    }

    func testDirectAPIModelsNeverUseMobileTokenAndLabelsReflectActualRoute() throws {
        try register()
        selections.select(.pairedHelper, for: .openAI)
        selections.select(.pairedHelper, for: .claudeCode)
        keys.apiKeys[.openAI] = "direct-key"
        keys.apiKeys[.anthropic] = "direct-anthropic-key"
        manager.refresh()
        let client = NetworkClient(keychainService: keys, accountLoginService: AccountNoLoginService(),
            accountProxyTransport: transport(), providerAccessManager: manager)
        let provider = try XCTUnwrap(client.langTool(for: .openAI, with: "direct-key") as? OpenAI)
        let request = try provider.prepare(request: OpenAI.ChatCompletionRequest(model: .gpt4o_mini, messages: [], stream: false))
        XCTAssertEqual(request.url?.host, "api.openai.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer direct-key")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-LangTools-Account-Token"))
        XCTAssertFalse(String(describing: request.allHTTPHeaderFields).contains(deviceToken))
        let viewModel = ChatSettingsView.ViewModel(clearMessages: {}, accessManager: manager,
            codexHelperTokenStore: CodexHelperTokenStore(defaults: defaults, keychain: secrets))
        XCTAssertEqual(viewModel.transportLabel(for: .openAI(.gpt5_5)), "Direct API key")
        XCTAssertEqual(viewModel.transportLabel(for: .anthropic(claudeModel())), "Direct API key")
        XCTAssertEqual(viewModel.transportLabel(for: .codex(.gpt5_5)), "LangToolsHelper (Test Mac)")
        XCTAssertTrue(viewModel.modelPickerTitle(for: .codex(.gpt5_5)).contains("LangToolsHelper (Test Mac)"))
        selections.select(.existing, for: .claudeCode)
        XCTAssertEqual(viewModel.transportLabel(for: .claudeCode(claudeModel())), "Claude Code backend")
        selections.select(.existing, for: .openAI)
        XCTAssertEqual(viewModel.transportLabel(for: .codex(.gpt5_5)), "Local Codex helper")
        XCTAssertTrue(PairedAccountURLProtocol.requests.isEmpty)
    }

    func testDisconnectDeletionFailureStillFailsClosedAfterRelaunch() throws {
        try register()
        selections.select(.pairedHelper, for: .openAI)
        credentials.failRemoval = true
        XCTAssertThrowsError(try selections.disconnectHelper())
        XCTAssertThrowsError(try selections.snapshot(for: .openAI).requireConnection())
        let restored = AccountTransportSelectionStore(userDefaults: defaults, credentialStore: credentials)
        XCTAssertTrue(restored.snapshot(for: .openAI).isPaired)
        XCTAssertThrowsError(try restored.snapshot(for: .openAI).requireConnection())
    }

    func testConnectPairedCodexIsReadOnlyDiscoveryAndFailureDoesNotClaimLogin() async throws {
        try register()
        selections.select(.pairedHelper, for: .openAI)
        installCatalogResponses()
        let client = NetworkClient(keychainService: keys, accountLoginService: AccountNoLoginService(),
            accountProxyTransport: transport(), providerAccessManager: manager)
        try await client.connectCodexHelper()
        XCTAssertEqual(manager.session(for: .openAI)?.accessToken, CodexSessionMarker.value)
        XCTAssertTrue(PairedAccountURLProtocol.requests.allSatisfy { $0.httpMethod == "GET" })
        XCTAssertFalse(PairedAccountURLProtocol.requests.contains { $0.url?.path.contains("login") == true })
        PairedAccountURLProtocol.handler = { _ in (503, "") }
        do { try await client.connectAccount(.openAI); XCTFail("Unavailable helper must not claim successful login") }
        catch { XCTAssertTrue(error is MobileHelperError) }
        XCTAssertNil(manager.session(for: .openAI))
    }

    func testOllamaDisconnectRetiresRegistrationBeforeAccountRoutesAreSelected() throws {
        for failRemoval in [false, true] {
            credentials.failRemoval = false
            try register()
            selections.select(.existing, for: .openAI)
            selections.select(.existing, for: .claudeCode)
            selections.select(.pairedHelper, for: .openAI)
            let connection = try XCTUnwrap(selections.snapshot(for: .openAI).connection)
            selections.select(.existing, for: .openAI)
            try ollamaConfiguration.selectHelper(connection)
            credentials.failRemoval = failRemoval
            let service = OllamaService(endpointConfiguration: ollamaConfiguration, providerAccessManager: manager)
            if failRemoval { XCTAssertThrowsError(try service.disconnectHelper()) }
            else { try service.disconnectHelper() }
            XCTAssertEqual(selections.snapshot(for: .openAI).choice, .existing)
            XCTAssertEqual(selections.snapshot(for: .claudeCode).choice, .existing)
            selections.select(.pairedHelper, for: .openAI)
            XCTAssertThrowsError(try selections.snapshot(for: .openAI).requireConnection())
            let restored = AccountTransportSelectionStore(userDefaults: defaults, credentialStore: credentials)
            restored.select(.pairedHelper, for: .claudeCode)
            XCTAssertThrowsError(try restored.snapshot(for: .claudeCode).requireConnection())
        }
    }

    func testAccountModelRouteCannotFallThroughWhenDisconnectRacesAccessCheck() async throws {
        try register()
        selections.select(.pairedHelper, for: .claudeCode)
        try sessionStore.save(claudeSession())
        installCatalogResponses()
        await manager.refreshPairedAccount(.claudeCode)
        let client = NetworkClient(keychainService: keys, accountLoginService: AccountNoLoginService(),
            accountProxyTransport: transport(), providerAccessManager: manager)
        PairedAccountURLProtocol.reset()
        secrets.onRead = { key in
            guard key == "claudeCode:accountSession" else { return }
            self.secrets.onRead = nil
            do { try self.selections.disconnectHelper() } catch { XCTFail("Synthetic disconnect failed: \(error)") }
        }
        do {
            _ = try await client.performChatCompletionRequest(messages: [], model: .claudeCode(claudeModel()))
            XCTFail("Missing account snapshot must fail closed")
        } catch {
            XCTAssertEqual(error as? NetworkClient.NetworkError, .modelAccessUnavailable(Model.claudeCode(claudeModel()).rawValue))
        }
        XCTAssertTrue(PairedAccountURLProtocol.requests.isEmpty)
    }

    func testCancellationDoesNotInvalidateHealthySelectionOrCatalog() async throws {
        try register()
        selections.select(.pairedHelper, for: .openAI)
        let snapshot = selections.snapshot(for: .openAI)
        XCTAssertTrue(selections.publish(modelIDs: ["gpt-5.5"], accountIdentifier: "Mac", for: snapshot))
        PairedAccountURLProtocol.handler = { _ in throw URLError(.cancelled) }
        do {
            _ = try await transport().performChatCompletionRequest(messages: [], model: .codex(.gpt5_5), session: codexSession(), tools: nil, toolChoice: nil)
            XCTFail("Expected cancellation")
        } catch { XCTAssertEqual((error as? URLError)?.code, .cancelled) }
        XCTAssertTrue(selections.isCurrent(snapshot))
        XCTAssertNotNil(manager.session(for: .openAI))
        XCTAssertFalse(manager.availableChatModels().isEmpty)
    }

    func testClaudeCatalogIsBoundToSessionRevisionIncludingAToBToA() async throws {
        try register()
        selections.select(.pairedHelper, for: .claudeCode)
        let original = claudeSession()
        try sessionStore.save(original)
        installCatalogResponses()
        await manager.refreshPairedAccount(.claudeCode)
        XCTAssertNotNil(manager.session(for: .claudeCode))
        try sessionStore.save(AccountSession(provider: .claudeCode, accountIdentifier: "Other User", accessToken: "other-token"))
        XCTAssertNil(manager.session(for: .claudeCode))
        XCTAssertTrue(manager.availableChatModels().isEmpty)
        try sessionStore.save(original)
        XCTAssertNil(manager.session(for: .claudeCode), "Restoring session A must not resurrect A's stale catalog")
        let originalHandler = PairedAccountURLProtocol.handler!
        PairedAccountURLProtocol.handler = { request in
            if request.url?.path == "/v1/claude/models" {
                try self.sessionStore.removeSession(for: .claudeCode)
                try self.sessionStore.save(original)
            }
            return try originalHandler(request)
        }
        await manager.refreshPairedAccount(.claudeCode)
        XCTAssertNil(manager.session(for: .claudeCode), "A late discovery result must not publish to a changed account session")
        XCTAssertTrue(manager.availableChatModels().isEmpty)
    }

    func testAccountDisconnectClearsSharedOllamaFutureRoutesEvenIfDeletionFails() throws {
        try register()
        selections.select(.pairedHelper, for: .openAI)
        let captured = selections.snapshot(for: .openAI)
        try ollamaConfiguration.selectHelper(try XCTUnwrap(captured.connection))
        let ollamaSnapshot = ollamaConfiguration.snapshot()
        XCTAssertTrue(ollamaConfiguration.storeModels([.init(rawValue: "fixture-model")!], for: ollamaSnapshot))
        credentials.failRemoval = true
        XCTAssertThrowsError(try manager.disconnectPairedHelper())
        XCTAssertThrowsError(try selections.snapshot(for: .openAI).requireConnection())
        XCTAssertTrue(ollamaConfiguration.cachedModels().isEmpty)
        XCTAssertThrowsError(try ollamaConfiguration.snapshot().provider(directSession: .shared))
        XCTAssertEqual(try captured.requireConnection().credential.token, deviceToken)
        XCTAssertEqual(try ollamaSnapshot.provider(directSession: .shared).configuration.apiKey, deviceToken)
        let restored = OllamaEndpointConfiguration(userDefaults: defaults, credentialStore: credentials)
        XCTAssertThrowsError(try restored.snapshot().provider(directSession: .shared))
    }

    func testCleanupReachesEveryConversationOwnerAfterHelperSwitch() async throws {
        try register()
        selections.select(.pairedHelper, for: .openAI)
        PairedAccountURLProtocol.handler = { _ in (200, #"{"content":"ok"}"#) }
        let transport = transport()
        let id = UUID()
        _ = try await transport.performChatCompletionRequest(messages: [], model: .codex(.gpt5_5), session: codexSession(), conversationID: id, tools: nil, toolChoice: nil)
        try register(helperID: "33333333-3333-4333-8333-333333333333", name: "Mac B")
        _ = try await transport.performChatCompletionRequest(messages: [], model: .codex(.gpt5_5), session: codexSession(), conversationID: id, tools: nil, toolChoice: nil)
        await transport.endConversation(id: id)
        XCTAssertEqual(PairedAccountURLProtocol.requests.filter { $0.httpMethod == "DELETE" }.count, 2)
    }

    func testOllamaCannotSelectAccountOnlyGrantIncludingPersistedSelection() throws {
        try register(capabilities: ["codex"])
        selections.select(.pairedHelper, for: .openAI)
        let connection = try XCTUnwrap(selections.snapshot(for: .openAI).connection)
        XCTAssertThrowsError(try ollamaConfiguration.selectHelper(connection)) {
            XCTAssertEqual($0 as? MobileHelperError, .missingCapability("ollama"))
        }
        defaults.set(helperID, forKey: OllamaEndpointConfiguration.helperSelectionKey)
        let restored = OllamaEndpointConfiguration(userDefaults: defaults, credentialStore: credentials)
        XCTAssertTrue(restored.cachedModels().isEmpty)
        XCTAssertThrowsError(try restored.snapshot().provider(directSession: .shared))
        XCTAssertTrue(PairedAccountURLProtocol.requests.isEmpty)
    }

    func testAccountContextRetainsAuthorizedMacAcrossSessionToTransportBoundary() async throws {
        for switchToExisting in [true, false] {
            for operation in 0..<4 {
                try register()
                selections.select(.pairedHelper, for: .openAI)
                let snapshot = selections.snapshot(for: .openAI)
                XCTAssertTrue(selections.publish(modelIDs: ["gpt-5.5"], accountIdentifier: "Mac A", for: snapshot))
                let context = try XCTUnwrap(manager.accountRequestContext(for: .codex(.gpt5_5)))
                // The deterministic boundary is BEFORE transport capture, not
                // merely after data/stream has already captured its destination.
                if switchToExisting {
                    selections.select(.existing, for: .openAI)
                } else {
                    try register(helperID: "33333333-3333-4333-8333-333333333333", name: "Mac B",
                        endpoint: URL(string: "https://192.168.1.8:8086")!, token: String(repeating: "d", count: 64))
                }
                PairedAccountURLProtocol.reset()
                PairedAccountURLProtocol.handler = { request in
                    XCTAssertEqual(request.url?.host, "192.168.1.7", "Mac A's authorization must never travel to another route")
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(self.deviceToken)")
                    if operation == 2 { return (200, #"{"type":"complete","content":"Mac A"}"# + "\n") }
                    return (200, #"{"content":"Mac A"}"#)
                }
                let owner = transport()
                let bound = try owner.capturingRoute(session: context.session, snapshot: context.snapshot)
                if operation == 0 {
                    let message = try await bound.performChatCompletionRequest(messages: [], model: .codex(.gpt5_5), session: context.session, tools: nil, toolChoice: nil)
                    XCTAssertEqual(message.text, "Mac A")
                } else if operation == 3 {
                    let conversation = try XCTUnwrap(bound as? ConversationAwareAccountProxyTransportProtocol)
                    let id = UUID()
                    _ = try await conversation.performChatCompletionRequest(messages: [], model: .codex(.gpt5_5), session: context.session, conversationID: id, tools: nil, toolChoice: nil)
                    await owner.endConversation(id: id)
                    XCTAssertEqual(PairedAccountURLProtocol.requests.last?.httpMethod, "DELETE")
                } else {
                    var text = ""
                    for try await delta in try bound.streamChatCompletionRequest(messages: [], model: .codex(.gpt5_5), session: context.session, stream: operation == 2, tools: nil, toolChoice: nil) { text += delta }
                    XCTAssertEqual(text, "Mac A")
                }
                XCTAssertEqual(PairedAccountURLProtocol.requests.count, operation == 3 ? 2 : 1)
            }
        }
    }

    func testNetworkClientRejectsSelectionChangeDuringAuthorizationCaptureForDataStreamAndAgent() async throws {
        let previousOverride = ToolSettings.shared.agentModelOverride
        ToolSettings.shared.agentModelOverride = nil
        defer { ToolSettings.shared.agentModelOverride = previousOverride; secrets.onRead = nil }
        for switchToExisting in [true, false] {
            for operation in 0..<4 {
                try register()
                selections.select(.pairedHelper, for: .claudeCode)
                try sessionStore.save(claudeSession())
                installCatalogResponses()
                await manager.refreshPairedAccount(.claudeCode)
                let client = NetworkClient(keychainService: keys, accountLoginService: AccountNoLoginService(),
                    accountProxyTransport: transport(), providerAccessManager: manager)
                PairedAccountURLProtocol.reset()
                var readCount = 0
                secrets.onRead = { key in
                    guard key == "claudeCode:accountSession" else { return }
                    readCount += 1
                    // First read: access check. Second: authorization context's
                    // secure-store read, between snapshot and session resolution.
                    guard readCount == 2 else { return }
                    self.secrets.onRead = nil
                    if switchToExisting {
                        self.selections.select(.existing, for: .claudeCode)
                    } else {
                        do { try self.register(helperID: "33333333-3333-4333-8333-333333333333", name: "Mac B") }
                        catch { XCTFail("Synthetic helper switch failed: \(error)") }
                    }
                }
                do {
                    let model = Model.claudeCode(claudeModel())
                    if operation == 0 {
                        _ = try await client.performChatCompletionRequest(messages: [], model: model)
                    } else if operation == 3 {
                        _ = try client.agentContext(messages: [], model: model, eventHandler: { _ in })
                    } else {
                        for try await _ in try client.streamChatCompletionRequest(messages: [], model: model, stream: operation == 2) {}
                    }
                    XCTFail("Changed authorization revision must fail closed")
                } catch {
                    XCTAssertEqual(error as? NetworkClient.NetworkError, .modelAccessUnavailable(Model.claudeCode(claudeModel()).rawValue))
                }
                XCTAssertEqual(readCount, 2, "Exercise the context capture, not just the earlier access check")
                XCTAssertTrue(PairedAccountURLProtocol.requests.isEmpty, "No local, paired or direct-provider fallback")
            }
        }
    }

    func testAccountDiscoveryAllowsNarrowedHealthButRequiresProviderAndRejectsExpansion() async throws {
        try register()
        selections.select(.pairedHelper, for: .openAI)
        selections.select(.pairedHelper, for: .claudeCode)
        try sessionStore.save(claudeSession())
        installCatalogResponses()
        let catalogHandler = PairedAccountURLProtocol.handler!
        PairedAccountURLProtocol.handler = { request in
            if request.url?.path == "/v1/mobile/health" {
                return (200, #"{"version":1,"helperID":"\#(self.helperID)","capabilities":["codex"]}"#)
            }
            return try catalogHandler(request)
        }
        await manager.refreshPairedAccount(.openAI)
        XCTAssertNotNil(manager.session(for: .openAI), "Disabling Claude must not break enabled Codex")
        await manager.refreshPairedAccount(.claudeCode)
        XCTAssertEqual(selections.snapshot(for: .claudeCode).error, .missingCapability("claude"))
        XCTAssertFalse(PairedAccountURLProtocol.requests.contains { $0.url?.path == "/v1/claude/models" })

        try register(capabilities: ["codex"])
        installCatalogResponses() // Health tries to add Claude and Ollama.
        PairedAccountURLProtocol.reset()
        installCatalogResponses()
        await manager.refreshPairedAccount(.openAI)
        XCTAssertEqual(selections.snapshot(for: .openAI).error, .invalidIdentity)
        XCTAssertEqual(PairedAccountURLProtocol.requests.map { $0.url!.path }, ["/v1/mobile/health"])
    }

    func testOllamaReconnectAllowsOnlySubsetWithRequestedOllamaCapability() async throws {
        for scenario in [
            (grant: ["claude", "codex", "ollama"], health: ["ollama"], error: Optional<MobileHelperError>.none),
            (grant: ["claude", "codex", "ollama"], health: ["codex"], error: .missingCapability("ollama")),
            (grant: ["ollama"], health: ["codex", "ollama"], error: .invalidIdentity)
        ] {
            try register(capabilities: scenario.grant)
            selections.select(.pairedHelper, for: .openAI)
            let connection = try XCTUnwrap(selections.snapshot(for: .openAI).connection)
            try ollamaConfiguration.selectHelper(connection)
            PairedAccountURLProtocol.reset()
            PairedAccountURLProtocol.handler = { request in
                if request.url?.path == "/v1/mobile/health" {
                    let data = try JSONEncoder().encode(MobileHelperHealthResponse(helperID: self.helperID, capabilities: scenario.health))
                    return (200, String(decoding: data, as: UTF8.self))
                }
                return (200, #"{"version":"fixture"}"#)
            }
            let service = OllamaService(endpointConfiguration: ollamaConfiguration, providerAccessManager: manager)
            do {
                try await service.checkConnection()
                XCTAssertNil(scenario.error)
            } catch { XCTAssertEqual(error as? MobileHelperError, scenario.error) }
            XCTAssertEqual(PairedAccountURLProtocol.requests.count, scenario.error == nil ? 2 : 1)
            XCTAssertEqual(connection.credential.capabilities, scenario.grant, "Reconnect never expands or rewrites consent")
        }
    }

    func testPairingStillRejectsNarrowedHealthBeforePersisting() async throws {
        let payload = try version2Payload(capabilities: ["codex", "ollama"])
        installPairingResponses(exchange: ["codex", "ollama"], health: ["codex"])
        do {
            _ = try await pairingClient().pair(payload, deviceName: "Phone")
            XCTFail("Initial pairing must match the complete offered grant")
        } catch { XCTAssertEqual(error as? MobileHelperError, .invalidIdentity) }
        XCTAssertTrue(credentials.records.isEmpty)
    }

    func testPairingConsentCopyIsCapabilitySpecific() {
        let ollama = MobileHelperPairingConsent.detail(capabilities: ["ollama"])
        XCTAssertTrue(ollama.contains("no account, filesystem, or command access is granted"))
        let codex = MobileHelperPairingConsent.detail(capabilities: ["codex"])
        XCTAssertTrue(codex.contains("inherited native runtime tool permissions"))
        XCTAssertTrue(codex.contains("no per-device filesystem sandbox"))
        XCTAssertFalse(codex.contains("no account, filesystem, or command access is granted"))
        let claude = MobileHelperPairingConsent.detail(capabilities: ["claude"])
        XCTAssertTrue(claude.contains("account credentials and chats transit your trusted Mac"))
        XCTAssertTrue(claude.contains("not an API-key provider proxy"))
        let combined = MobileHelperPairingConsent.detail(capabilities: ["claude", "codex", "ollama"])
        XCTAssertTrue(combined.contains("native runtime tool permissions"))
        XCTAssertTrue(combined.contains("account credentials"))
        XCTAssertFalse(combined.contains("no account, filesystem, or command access is granted"))
    }

    func testV1PairingRejectsBroadenedScopeBeforeHealth() async throws {
        let payload = MobileHelperPairingPayload(endpoint: URL(string: "https://192.168.1.7:8086")!, helperID: helperID,
            fingerprint: String(repeating: "a", count: 64), code: String(repeating: "b", count: 64), name: "Mac")
        PairedAccountURLProtocol.handler = { _ in
            (200, #"{"version":1,"helperID":"\#(self.helperID)","deviceID":"22222222-2222-4222-8222-222222222222","token":"\#(self.deviceToken)","capabilities":["codex","ollama"]}"#)
        }
        do {
            _ = try await pairingClient().pair(payload, deviceName: "Phone")
            XCTFail("v1 QR must be Ollama-only")
        } catch { XCTAssertEqual(error as? MobileHelperError, .invalidIdentity) }
        XCTAssertEqual(PairedAccountURLProtocol.requests.map { $0.url!.path }, ["/v1/mobile/pair"])
        XCTAssertTrue(credentials.records.isEmpty)
    }

    func testV2AccountOnlyPairingRegistersButDoesNotSelectAccountOrOllama() async throws {
        let payload = try version2Payload(capabilities: ["codex"])
        installPairingResponses(exchange: ["codex"], health: ["codex"])
        let coordinator = MobileHelperPairingCoordinator(configuration: ollamaConfiguration, client: pairingClient(), accountTransports: selections, didSelect: {})
        let original = ollamaConfiguration.snapshot()
        coordinator.handle(try payload.pairingURL())
        coordinator.confirm(payload, generation: coordinator.pendingGeneration, deviceName: "Phone")
        try await waitUntil { !coordinator.isPairing }
        XCTAssertNil(coordinator.errorMessage)
        XCTAssertEqual(ollamaConfiguration.snapshot(), original)
        XCTAssertEqual(selections.snapshot(for: .openAI).choice, .existing)
        XCTAssertEqual(selections.snapshot(for: .claudeCode).choice, .existing)
        selections.select(.pairedHelper, for: .openAI)
        XCTAssertEqual(try selections.snapshot(for: .openAI).requireConnection().credential.capabilities, ["codex"])
    }

    func testV2PairingScopeMismatchNeverSavesConnection() async throws {
        let payload = try version2Payload(capabilities: ["codex"])
        for scope in [(exchange: ["codex", "ollama"], health: ["codex", "ollama"]), (exchange: ["codex"], health: ["ollama"])] {
            installPairingResponses(exchange: scope.exchange, health: scope.health)
            let coordinator = MobileHelperPairingCoordinator(configuration: ollamaConfiguration, client: pairingClient(), accountTransports: selections, didSelect: {})
            coordinator.handle(try payload.pairingURL())
            coordinator.confirm(payload, generation: coordinator.pendingGeneration, deviceName: "Phone")
            try await waitUntil { !coordinator.isPairing }
            XCTAssertNotNil(coordinator.errorMessage)
            XCTAssertTrue(credentials.records.isEmpty)
            XCTAssertFalse(ollamaConfiguration.snapshot().isHelper)
        }
    }

    private func version2Payload(capabilities: [String]) throws -> MobileHelperPairingPayload {
        let payload = MobileHelperPairingPayload(version: 2, endpoint: URL(string: "https://192.168.1.7:8086")!, helperID: helperID,
            fingerprint: String(repeating: "a", count: 64), code: String(repeating: "b", count: 64), name: "Mac", capabilities: capabilities)
        // Unexpected QR contract errors fail rather than skip these tests.
        return try MobileHelperPairingPayload.parse(payload.pairingURL())
    }
    private func pairingClient() -> MobileHelperPairingClient {
        MobileHelperPairingClient(sessionFactory: { _, _ in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [PairedAccountURLProtocol.self]
            return URLSession(configuration: configuration)
        })
    }
    private func installPairingResponses(exchange: [String], health: [String]) {
        PairedAccountURLProtocol.handler = { request in
            let object: Data
            if request.url?.path == "/v1/mobile/pair" {
                object = try JSONEncoder().encode(MobileHelperPairingResponse(helperID: self.helperID,
                    deviceID: "22222222-2222-4222-8222-222222222222", token: self.deviceToken, capabilities: exchange))
            } else {
                object = try JSONEncoder().encode(MobileHelperHealthResponse(helperID: self.helperID, capabilities: health))
            }
            return (200, String(decoding: object, as: UTF8.self))
        }
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            if Date() >= deadline { throw URLError(.timedOut) }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func register(capabilities: [String] = ["claude", "codex", "ollama"], helperID: String? = nil, name: String = "Test Mac", endpoint: URL? = nil, token: String? = nil) throws {
        let credential = MobileHelperCredential(endpoint: endpoint ?? URL(string: "https://192.168.1.7:8086")!,
            helperID: helperID ?? self.helperID, fingerprint: String(repeating: "a", count: 64), name: name,
            deviceID: "22222222-2222-4222-8222-222222222222", token: token ?? deviceToken, capabilities: capabilities)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PairedAccountURLProtocol.self]
        let pairedSession = URLSession(configuration: config)
        try selections.registerPairedHelper(MobileHelperConnection(credential: credential, session: pairedSession))
    }
    private func codexSession() -> AccountSession {
        AccountSession(provider: .openAI, accountIdentifier: "Mac", accessToken: CodexSessionMarker.value, accessibleModelIDs: ["gpt-5.5"])
    }
    private func claudeModel() -> Anthropic.Model { Anthropic.Model.allCases[0] }
    private func claudeSession() -> AccountSession {
        AccountSession(provider: .claudeCode, accountIdentifier: "Claude User", accessToken: "backend-account-token", accessibleModelIDs: [claudeModel().rawValue])
    }
    private func transport() -> AccountProxyTransport {
        AccountProxyTransport(configuration: AccountBackendConfiguration(baseURL: URL(string: "http://127.0.0.1:8080")!,
            codexHelperBaseURL: URL(string: "http://127.0.0.1:8765")!, codexHelperToken: "local-token"),
            urlSession: urlSession, selections: selections)
    }
    private func installCatalogResponses() {
        PairedAccountURLProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/mobile/health": return (200, #"{"version":1,"helperID":"\#(self.helperID)","capabilities":["claude","codex","ollama"]}"#)
            case "/v1/account/status": return (200, #"{"provider":"openAI","authenticated":true,"accountIdentifier":"Signed-in Mac","accessibleModelIDs":["gpt-5.5"]}"#)
            case "/v1/models/codex": return (200, #"{"models":["gpt-5.5"]}"#)
            case "/v1/claude/models": return (200, #"{"models":["\#(self.claudeModel().rawValue)"]}"#)
            default: throw URLError(.unsupportedURL)
            }
        }
    }
}

private final class AccountMemoryCredentials: MobileHelperCredentialStoring, @unchecked Sendable {
    var records: [String: MobileHelperCredential] = [:]
    var failRemoval = false
    func load(helperID: String) throws -> MobileHelperCredential? { records[helperID] }
    func save(_ credential: MobileHelperCredential) throws { records[credential.helperID] = credential }
    func remove(helperID: String) throws {
        if failRemoval { throw MobileHelperError.persistence("synthetic deletion failure") }
        records.removeValue(forKey: helperID)
    }
}
private final class AccountMemorySecrets: KeychainSecretStoring {
    var values: [String: String] = [:]
    var onRead: ((String) -> Void)?
    func setSecret(_ value: String, forKey key: String) throws { values[key] = value }
    func readSecret(forKey key: String) throws -> String? { onRead?(key); return values[key] }
    func removeSecret(forKey key: String) throws { values.removeValue(forKey: key) }
}
private final class AccountMemoryKeys: KeychainService {
    var apiKeys: [APIService: String] = [:]
    override func getApiKey(for service: APIService) -> String? { apiKeys[service] }
    override func saveApiKey(apiKey: String, for service: APIService) { apiKeys[service] = apiKey }
    override func deleteApiKey(for service: APIService) { apiKeys.removeValue(forKey: service) }
}
private final class PairedAccountURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String))?
    private static let lock = NSLock()
    private static var recorded: [URLRequest] = []
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    static func reset() { lock.lock(); defer { lock.unlock() }; recorded = []; handler = nil }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.recorded.append(request); Self.lock.unlock()
        do {
            let (status, body) = try Self.handler?(request) ?? (500, "")
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/x-ndjson"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
private struct AccountNoLoginService: AccountLoginService {
    func beginLogin(for provider: AccountLoginProvider) async throws -> AccountSession { throw MobileHelperError.accountUnavailable }
    func beginCodexHelperLogin() async throws -> AccountSession { throw MobileHelperError.accountUnavailable }
    func refreshSession(_ session: AccountSession) async throws -> AccountSession { throw MobileHelperError.accountUnavailable }
    func handleRedirect(_ url: URL) async throws -> AccountSession { throw MobileHelperError.accountUnavailable }
    func logout(provider: AccountLoginProvider) async throws { throw MobileHelperError.accountUnavailable }
    func logoutCodexHelper() async throws { throw MobileHelperError.accountUnavailable }
    func fetchAccessibleModels(for provider: AccountLoginProvider) async throws -> [String] { throw MobileHelperError.accountUnavailable }
}
