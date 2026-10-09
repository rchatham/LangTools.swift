import Agents
import Foundation
import Ollama
import OpenAI
import XCTest
@testable import Chat

@MainActor
final class OllamaEndpointRoutingTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var endpointConfiguration: OllamaEndpointConfiguration!
    private var session: URLSession!
    private var keychainService: KeychainService!
    private var sessionStore: AuthSessionStore!
    private var accessManager: ProviderAccessManager!
    private var savedAgentModelOverride: Model?
    private var globalToolSettings: [String: Any] = [:]
    private let toolSettingsKeys = [
        "richContentEnabled", "keepsToolCallsInHistory", "crossProviderToolReplay", "voiceInputEnabled",
        "sttProviderRawValue", "voiceButtonReplaceSend", "sttLanguage", "whisperKitModelSize",
        "autoStopOnSilence", "silenceTimeoutSeconds", "streamingTranscriptionEnabled",
        "enableOpenAISimulatedStreaming", "streamingChunkIntervalSeconds", "maxToolIterations",
        "toolTimeoutSeconds", "autoRetryFailedTools", "agentModelOverride"
    ]

    override func setUp() {
        super.setUp()
        globalToolSettings = UserDefaults.standard.dictionaryRepresentation().filter { toolSettingsKeys.contains($0.key) }
        savedAgentModelOverride = ToolSettings.shared.agentModelOverride
        ToolSettings.shared.agentModelOverride = nil
        suiteName = "OllamaEndpointRoutingTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OllamaRoutingURLProtocol.self]
        session = URLSession(configuration: configuration)
        OllamaRoutingURLProtocol.reset()

        endpointConfiguration = OllamaEndpointConfiguration(userDefaults: defaults,
            credentialStore: OllamaMemoryHelperStore(), directSession: session)
        keychainService = OllamaMemoryKeychainService()
        sessionStore = AuthSessionStore(secretStore: OllamaMemorySecrets())
        accessManager = ProviderAccessManager(
            keychainService: keychainService,
            sessionStore: sessionStore,
            ollamaEndpointConfiguration: endpointConfiguration
        )
    }

    override func tearDown() {
        ToolSettings.shared.agentModelOverride = savedAgentModelOverride
        for key in toolSettingsKeys { UserDefaults.standard.set(globalToolSettings[key], forKey: key) }
        session.invalidateAndCancel()
        defaults.removePersistentDomain(forName: suiteName)
        OllamaRoutingURLProtocol.reset()
        super.tearDown()
    }

    func testDiscoveryVersionChatStreamAndAgentUseConfiguredEndpoint() async throws {
        _ = try endpointConfiguration.update("https://mac.local:11434")
        OllamaRoutingURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/tags":
                return .json(Self.modelsResponse(named: "llama3.2"))
            case "/api/ps":
                return .json(#"{"models":[]}"#)
            case "/api/version":
                return .json(#"{"version":"0.5.0"}"#)
            case "/api/chat":
                return .json(Self.chatResponse(content: "hello"))
            default:
                throw URLError(.unsupportedURL)
            }
        }

        let service = OllamaService(
            endpointConfiguration: endpointConfiguration,
            session: session,
            providerAccessManager: accessManager
        )
        service.refreshModels()
        try await waitUntil { service.availableModels.map(\.rawValue) == ["llama3.2"] }
        try await service.checkConnection()

        let client = makeClient()
        let model = Model.ollama(try XCTUnwrap(Ollama.Model(rawValue: "llama3.2")))
        let response = try await client.performChatCompletionRequest(
            messages: [Message(text: "Hi", role: .user)],
            model: model,
            tools: nil,
            toolChoice: nil
        )
        XCTAssertEqual(response.text, "hello")

        let stream = try client.streamChatCompletionRequest(
            messages: [Message(text: "Hi", role: .user)],
            model: model,
            stream: true,
            tools: nil,
            toolChoice: nil
        )
        var streamed = ""
        for try await chunk in stream { streamed += chunk }
        XCTAssertEqual(streamed, "hello")

        let context = try client.agentContext(messages: [], model: model) { _ in }
        XCTAssertNil(context.langTool as? Ollama, "Captured capabilities must not expose a mutable concrete provider")
        let agentRequest = try context.langTool.prepare(request: Ollama.ChatRequest(model: .init(rawValue: "llama3.2")!, messages: []))
        XCTAssertEqual(agentRequest.url?.absoluteString, "https://mac.local:11434/api/chat")

        let requests = OllamaRoutingURLProtocol.requests()
        XCTAssertTrue(requests.allSatisfy { $0.url?.host == "mac.local" })
        XCTAssertTrue(Set(requests.compactMap { $0.url?.path }).isSuperset(of: ["/api/tags", "/api/ps", "/api/version", "/api/chat"]))
    }

    func testStreamingCapturesEndpointBeforeEndpointChanges() async throws {
        _ = try endpointConfiguration.update("https://old.local:11434")
        OllamaRoutingURLProtocol.handler = { request in
            .json(Self.chatResponse(content: request.url?.host ?? "missing"), delay: 0.1)
        }
        let client = makeClient()
        let model = Model.ollama(try XCTUnwrap(Ollama.Model(rawValue: "llama3.2")))

        let oldStream = try client.streamChatCompletionRequest(
            messages: [Message(text: "Hi", role: .user)], model: model, stream: true,
            tools: nil, toolChoice: nil
        )
        _ = try endpointConfiguration.update("https://new.local:11434")
        let newStream = try client.streamChatCompletionRequest(
            messages: [Message(text: "Hi", role: .user)], model: model, stream: true,
            tools: nil, toolChoice: nil
        )

        async let oldResult = Self.collect(oldStream)
        async let newResult = Self.collect(newStream)
        let values = try await (oldResult, newResult)
        XCTAssertEqual(values.0, "old.local")
        XCTAssertEqual(values.1, "new.local")
    }

    func testMultiChunkStreamingResponseUsesConfiguredEndpoint() async throws {
        _ = try endpointConfiguration.update("https://stream.local:11434")
        OllamaRoutingURLProtocol.handler = { request in
            guard request.url?.path == "/api/chat" else { throw URLError(.unsupportedURL) }
            return .stream([
                Self.chatResponse(content: "hel", done: false),
                Self.chatResponse(content: "lo")
            ], interChunkDelay: 0.03)
        }
        let client = makeClient()
        let model = Model.ollama(try XCTUnwrap(Ollama.Model(rawValue: "llama3.2")))

        let stream = try client.streamChatCompletionRequest(
            messages: [Message(text: "Hi", role: .user)], model: model, stream: true,
            tools: nil, toolChoice: nil
        )

        let streamed = try await Self.collect(stream)
        XCTAssertEqual(streamed, "hello")
        XCTAssertEqual(OllamaRoutingURLProtocol.requests().map { $0.url?.host }, ["stream.local"])
    }

    func testLoadAndPullUseExplicitCapturedSnapshotAfterEndpointChanges() async throws {
        let capturedSnapshot = try endpointConfiguration.update("https://a.local:11434")
        _ = try endpointConfiguration.update("https://b.local:11434")
        OllamaRoutingURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/chat":
                return .json(Self.chatResponse(content: "loaded"))
            case "/api/pull":
                return .stream([
                    #"{"status":"downloading","total":100,"completed":25}"#,
                    #"{"status":"success","total":100,"completed":100}"#
                ], interChunkDelay: 0.03)
            default:
                throw URLError(.unsupportedURL)
            }
        }
        let service = OllamaService(
            endpointConfiguration: endpointConfiguration,
            session: session,
            providerAccessManager: accessManager
        )
        let model = try XCTUnwrap(Ollama.Model(rawValue: "llama3.2"))

        try await service.loadModel(model, for: capturedSnapshot)
        var progress: [Double] = []
        try await service.pullModel("llama3.2", for: capturedSnapshot) { progress.append($0) }

        let operationRequests = OllamaRoutingURLProtocol.requests()
        XCTAssertEqual(operationRequests.compactMap { $0.url?.host }, ["a.local", "a.local"])
        XCTAssertEqual(operationRequests.compactMap { $0.url?.path }, ["/api/chat", "/api/pull"])
        XCTAssertEqual(progress, [0.25, 1.0])
        XCTAssertEqual(operationRequests.last?.httpMethod, "POST")
    }

    func testStaleConnectionResultCannotOverwriteCurrentStatus() async throws {
        _ = try endpointConfiguration.update("https://a.local:11434")
        OllamaRoutingURLProtocol.handler = { request in
            guard request.url?.path == "/api/version" else { throw URLError(.unsupportedURL) }
            if request.url?.host == "a.local" {
                return .json(#"{"unexpected":true}"#, delay: 0.2)
            }
            return .json(#"{"version":"0.5.0"}"#)
        }
        let service = OllamaService(
            endpointConfiguration: endpointConfiguration,
            session: session,
            providerAccessManager: accessManager
        )
        let viewModel = OllamaSettingsView.ViewModel(
            ollamaService: service,
            endpointConfiguration: endpointConfiguration
        )
        viewModel.checkConnection()
        try await waitUntil {
            OllamaRoutingURLProtocol.requests().contains { $0.url?.host == "a.local" }
        }

        let currentSnapshot = try endpointConfiguration.update("https://b.local:11434")
        viewModel.checkConnection(for: currentSnapshot)
        try await waitUntil { viewModel.isConnected && !viewModel.isCheckingConnection }
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(viewModel.isConnected)
        XCTAssertFalse(viewModel.isCheckingConnection)
        XCTAssertNil(viewModel.connectionError)
    }

    func testInFlightChatsRemainBoundToCapturedEndpoints() async throws {
        _ = try endpointConfiguration.update("https://old.local:11434")
        OllamaRoutingURLProtocol.handler = { request in
            let host = request.url?.host ?? "missing"
            return .json(Self.chatResponse(content: host), delay: host == "old.local" ? 0.25 : 0)
        }
        let client = makeClient()
        let model = Model.ollama(try XCTUnwrap(Ollama.Model(rawValue: "llama3.2")))

        let oldTask = Task {
            try await client.performChatCompletionRequest(
                messages: [Message(text: "old", role: .user)], model: model,
                tools: nil, toolChoice: nil
            )
        }
        try await waitUntil { OllamaRoutingURLProtocol.requests().contains { $0.url?.host == "old.local" } }
        _ = try endpointConfiguration.update("https://new.local:11434")
        let newResponse = try await client.performChatCompletionRequest(
            messages: [Message(text: "new", role: .user)], model: model,
            tools: nil, toolChoice: nil
        )
        let oldResponse = try await oldTask.value

        XCTAssertEqual(oldResponse.text, "old.local")
        XCTAssertEqual(newResponse.text, "new.local")
    }

    func testStaleDiscoveryCannotOverwriteNewEndpointModelsOrCache() async throws {
        OllamaRoutingURLProtocol.handler = { request in
            let host = request.url?.host
            switch request.url?.path {
            case "/api/tags":
                return .json(
                    Self.modelsResponse(named: host == "old.local" ? "old-model" : "new-model"),
                    delay: host == "old.local" ? 0.25 : 0
                )
            case "/api/ps":
                return .json(#"{"models":[]}"#)
            default:
                throw URLError(.unsupportedURL)
            }
        }
        let service = OllamaService(
            endpointConfiguration: endpointConfiguration,
            session: session,
            providerAccessManager: accessManager
        )
        _ = try service.updateEndpoint("https://old.local:11434")
        try await waitUntil { OllamaRoutingURLProtocol.requests().contains { $0.url?.host == "old.local" } }
        _ = try service.updateEndpoint("https://new.local:11434")

        try await waitUntil { service.availableModels.map(\.rawValue) == ["new-model"] }
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(service.availableModels.map(\.rawValue), ["new-model"])
        XCTAssertEqual(endpointConfiguration.cachedModels().map(\.rawValue), ["new-model"])
        XCTAssertEqual(accessManager.state(for: .ollama).availableModels.map(\.slug), ["new-model"])
    }

    func testOldDiscoveryCannotOverwriteModelsAfterEndpointReturnsToSameURL() async throws {
        var aTagsRequestCount = 0
        OllamaRoutingURLProtocol.handler = { request in
            let host = request.url?.host
            switch request.url?.path {
            case "/api/tags":
                if host == "a.local" {
                    aTagsRequestCount += 1
                    return .json(
                        Self.modelsResponse(named: aTagsRequestCount == 1 ? "old-a-model" : "new-a-model"),
                        delay: aTagsRequestCount == 1 ? 0.25 : 0
                    )
                }
                return .json(Self.modelsResponse(named: "b-model"))
            case "/api/ps":
                return .json(#"{"models":[]}"#)
            default:
                throw URLError(.unsupportedURL)
            }
        }
        let service = OllamaService(
            endpointConfiguration: endpointConfiguration,
            session: session,
            providerAccessManager: accessManager
        )

        _ = try service.updateEndpoint("https://a.local:11434")
        try await waitUntil {
            OllamaRoutingURLProtocol.requests().contains { $0.url?.host == "a.local" && $0.url?.path == "/api/tags" }
        }
        _ = try service.updateEndpoint("https://b.local:11434")
        try await waitUntil {
            OllamaRoutingURLProtocol.requests().contains { $0.url?.host == "b.local" && $0.url?.path == "/api/tags" }
        }
        _ = try service.updateEndpoint("https://a.local:11434")

        try await waitUntil { service.availableModels.map(\.rawValue) == ["new-a-model"] }
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(service.availableModels.map(\.rawValue), ["new-a-model"])
        XCTAssertEqual(endpointConfiguration.cachedModels().map(\.rawValue), ["new-a-model"])
        XCTAssertEqual(accessManager.state(for: .ollama).availableModels.map(\.slug), ["new-a-model"])
    }

    func testUnavailableSelectedOllamaModelIsPreservedAndMarkedUnavailable() throws {
        let selected = Model.ollama(try XCTUnwrap(Ollama.Model(rawValue: "missing-model")))
        XCTAssertEqual(accessManager.validateSelectedModel(selected), selected)

        let original = UserDefaults.model
        defer { UserDefaults.model = original }
        let viewModel = ChatSettingsView.ViewModel(
            clearMessages: {},
            accessManager: accessManager,
            codexHelperTokenStore: CodexHelperTokenStore(defaults: defaults, keychain: keychainService)
        )
        viewModel.model = selected

        XCTAssertTrue(viewModel.availableModels.contains(selected))
        XCTAssertTrue(viewModel.modelPickerTitle(for: selected).contains("Unavailable on current Ollama server"))
    }

    func testHelperDiscoveryChatStreamingAndAgentUseOneAuthenticatedSnapshot() async throws {
        let helperID = UUID().uuidString
        let credential = MobileHelperCredential(endpoint: URL(string: "https://192.168.1.10:8086")!,
            helperID: helperID, fingerprint: String(repeating: "a", count: 64), name: "Test Mac",
            deviceID: UUID().uuidString, token: String(repeating: "b", count: 64), capabilities: ["ollama"])
        try endpointConfiguration.selectHelper(MobileHelperConnection(credential: credential, session: session))
        var chatCalls = 0
        OllamaRoutingURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(credential.token)")
            switch request.url?.path {
            case "/v1/mobile/health":
                return .json(#"{"version":1,"helperID":"\#(helperID)","capabilities":["ollama"]}"#)
            case "/v1/ollama/api/tags": return .json(Self.modelsResponse(named: "llama3.2"))
            case "/v1/ollama/api/ps": return .json(#"{"models":[]}"#)
            case "/v1/ollama/api/version": return .json(#"{"version":"0.5.0"}"#)
            case "/v1/ollama/api/chat":
                chatCalls += 1
                if chatCalls > 1 {
                    return .stream([Self.chatResponse(content: "hel", done: false), Self.chatResponse(content: "lo")], interChunkDelay: 0.03)
                }
                return .json(Self.chatResponse(content: "hello"))
            default: throw URLError(.unsupportedURL)
            }
        }
        let service = OllamaService(endpointConfiguration: endpointConfiguration, session: .shared, providerAccessManager: accessManager)
        service.refreshModels()
        try await waitUntil { service.availableModels.map(\.rawValue) == ["llama3.2"] }
        try await service.checkConnection()
        let client = makeClient()
        let model = Model.ollama(try XCTUnwrap(Ollama.Model(rawValue: "llama3.2")))
        let response = try await client.performChatCompletionRequest(messages: [], model: model, tools: nil, toolChoice: nil)
        XCTAssertEqual(response.text, "hello")
        let stream = try client.streamChatCompletionRequest(messages: [], model: model, stream: true, tools: nil, toolChoice: nil)
        let streamed = try await Self.collect(stream)
        XCTAssertEqual(streamed, "hello")
        let context = try client.agentContext(messages: [], model: model) { _ in }
        XCTAssertNil(context.langTool as? Ollama)
        let agentRequest = try context.langTool.prepare(request: Ollama.ChatRequest(model: .init(rawValue: "llama3.2")!, messages: []))
        XCTAssertTrue(context.langTool.session === session)
        XCTAssertEqual(agentRequest.value(forHTTPHeaderField: "Authorization"), "Bearer \(credential.token)")
        XCTAssertEqual(agentRequest.url?.path, "/v1/ollama/api/chat")
        XCTAssertTrue(OllamaRoutingURLProtocol.requests().allSatisfy { $0.url?.host == "192.168.1.10" })
        try endpointConfiguration.disconnectHelper()
    }

    func testHelperStreamsCaptureOldCredentialsWhenSameIdentityIsRepaired() async throws {
        let helperID = UUID().uuidString
        func connection(token: String) -> MobileHelperConnection {
            helperConnection(helperID: helperID, host: "192.168.1.10", token: token)
        }
        try endpointConfiguration.selectHelper(connection(token: "a"))
        OllamaRoutingURLProtocol.handler = { request in
            .json(Self.chatResponse(content: String(request.value(forHTTPHeaderField: "Authorization")!.suffix(1))))
        }
        let client = makeClient()
        let model = Model.ollama(try XCTUnwrap(Ollama.Model(rawValue: "llama3.2")))
        let stream = try client.streamChatCompletionRequest(messages: [], model: model, stream: true, tools: nil, toolChoice: nil)
        let context = try client.agentContext(messages: [], model: model) { _ in }
        try endpointConfiguration.selectHelper(connection(token: "b"))
        let oldResult = try await Self.collect(stream)
        XCTAssertEqual(oldResult, "a")
        let capturedRequest = try context.langTool.prepare(request: Ollama.ChatRequest(model: .init(rawValue: "llama3.2")!, messages: []))
        XCTAssertEqual(capturedRequest.value(forHTTPHeaderField: "Authorization"), "Bearer " + String(repeating: "a", count: 64))
        let next = try client.streamChatCompletionRequest(messages: [], model: model, stream: true, tools: nil, toolChoice: nil)
        let nextResult = try await Self.collect(next)
        XCTAssertEqual(nextResult, "b")
        try endpointConfiguration.disconnectHelper()
    }

    func testGenerationOverridesPreserveDirectChatAndStreamEndpointSnapshots() async throws {
        _ = try endpointConfiguration.update("https://old.local:11434")
        let settings = try Self.generationOverrides()
        OllamaRoutingURLProtocol.handler = { request in
            let streaming = try Self.assertGenerationOverrides(in: request, settings: settings)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.url?.path, "/api/chat")
            let host = request.url?.host ?? "missing"
            if streaming {
                return .stream([Self.chatResponse(content: host, done: false), Self.chatResponse(content: "")],
                               interChunkDelay: 0.01)
            }
            return .json(Self.chatResponse(content: host), delay: host == "old.local" ? 0.1 : 0)
        }
        let client = makeClient(generationSettingsProvider: { settings })
        let model = Model.ollama(try XCTUnwrap(Ollama.Model(rawValue: "llama3.2")))
        let oldStream = try client.streamChatCompletionRequest(messages: [], model: model, stream: true,
                                                               tools: nil, toolChoice: nil)
        let oldChat = Task {
            try await client.performChatCompletionRequest(messages: [], model: model, tools: nil, toolChoice: nil)
        }
        try await waitUntil { OllamaRoutingURLProtocol.requests().filter { $0.url?.host == "old.local" }.count == 2 }
        _ = try endpointConfiguration.update("https://new.local:11434")
        let newChat = try await client.performChatCompletionRequest(messages: [], model: model, tools: nil, toolChoice: nil)
        let newStream = try client.streamChatCompletionRequest(messages: [], model: model, stream: true,
                                                               tools: nil, toolChoice: nil)
        let oldChatResponse = try await oldChat.value
        let oldStreamResponse = try await Self.collect(oldStream)
        let newStreamResponse = try await Self.collect(newStream)
        XCTAssertEqual(oldChatResponse.text, "old.local")
        XCTAssertEqual(oldStreamResponse, "old.local")
        XCTAssertEqual(newChat.text, "new.local")
        XCTAssertEqual(newStreamResponse, "new.local")
        let requests = OllamaRoutingURLProtocol.requests()
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests.filter { $0.url?.host == "old.local" }.count, 2)
        XCTAssertEqual(requests.filter { $0.url?.host == "new.local" }.count, 2)
    }

    func testGenerationOverridesPreserveHelperChatAndStreamCredentialSnapshots() async throws {
        let helperID = UUID().uuidString
        let oldConnection = helperConnection(helperID: helperID, host: "192.168.1.10", token: "a")
        let newConnection = helperConnection(helperID: helperID, host: "192.168.1.11", token: "b")
        try endpointConfiguration.selectHelper(oldConnection)
        let settings = try Self.generationOverrides()
        OllamaRoutingURLProtocol.handler = { request in
            let streaming = try Self.assertGenerationOverrides(in: request, settings: settings)
            XCTAssertEqual(request.url?.path, "/v1/ollama/api/chat")
            let host = request.url?.host ?? "missing"
            let expectedToken = host == "192.168.1.10" ? oldConnection.credential.token : newConnection.credential.token
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(expectedToken)")
            if streaming {
                return .stream([Self.chatResponse(content: host, done: false), Self.chatResponse(content: "")],
                               interChunkDelay: 0.01)
            }
            return .json(Self.chatResponse(content: host), delay: host == "192.168.1.10" ? 0.1 : 0)
        }
        let client = makeClient(generationSettingsProvider: { settings })
        let model = Model.ollama(try XCTUnwrap(Ollama.Model(rawValue: "llama3.2")))
        let oldStream = try client.streamChatCompletionRequest(messages: [], model: model, stream: true,
                                                               tools: nil, toolChoice: nil)
        let oldChat = Task {
            try await client.performChatCompletionRequest(messages: [], model: model, tools: nil, toolChoice: nil)
        }
        try await waitUntil { OllamaRoutingURLProtocol.requests().filter { $0.url?.host == "192.168.1.10" }.count == 2 }
        try endpointConfiguration.selectHelper(newConnection)
        let newChat = try await client.performChatCompletionRequest(messages: [], model: model, tools: nil, toolChoice: nil)
        let newStream = try client.streamChatCompletionRequest(messages: [], model: model, stream: true,
                                                               tools: nil, toolChoice: nil)
        let oldChatResponse = try await oldChat.value
        let oldStreamResponse = try await Self.collect(oldStream)
        let newStreamResponse = try await Self.collect(newStream)
        XCTAssertEqual(oldChatResponse.text, "192.168.1.10")
        XCTAssertEqual(oldStreamResponse, "192.168.1.10")
        XCTAssertEqual(newChat.text, "192.168.1.11")
        XCTAssertEqual(newStreamResponse, "192.168.1.11")
        let requests = OllamaRoutingURLProtocol.requests()
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests.filter { $0.url?.host == "192.168.1.10" }.count, 2)
        XCTAssertEqual(requests.filter { $0.url?.host == "192.168.1.11" }.count, 2)
        try endpointConfiguration.disconnectHelper()
    }

    func testAgentModelOverrideIntoOllamaCapturesHelperInsteadOfConversationProvider() throws {
        let connection = helperConnection(helperID: UUID().uuidString, host: "192.168.1.10", token: "a")
        try endpointConfiguration.selectHelper(connection)
        let model = try XCTUnwrap(Ollama.Model(rawValue: "llama3.2"))
        ToolSettings.shared.agentModelOverride = .ollama(model)
        let client = makeClient(generationSettingsProvider: { XCTFail("Agent execution must not read chat generation overrides"); return .automatic })
        let context = try client.agentContext(messages: [], model: .openAI(.gpt4o_mini)) { _ in }
        XCTAssertNil(context.langTool as? Ollama)
        XCTAssertEqual(context.model as? Ollama.Model, model)
        _ = try endpointConfiguration.update("https://direct.local:11434")
        let capturedRequest = try context.langTool.prepare(request: Ollama.ChatRequest(model: model, messages: []))
        XCTAssertTrue(context.langTool.session === connection.session)
        XCTAssertEqual(capturedRequest.url?.absoluteString, "https://192.168.1.10:8086/v1/ollama/api/chat")
        XCTAssertEqual(capturedRequest.value(forHTTPHeaderField: "Authorization"), "Bearer \(connection.credential.token)")
        let next = try client.agentContext(messages: [], model: .openAI(.gpt4o_mini)) { _ in }
        let directRequest = try next.langTool.prepare(request: Ollama.ChatRequest(model: model, messages: []))
        XCTAssertEqual(directRequest.url?.absoluteString, "https://direct.local:11434/api/chat")
        XCTAssertNil(directRequest.value(forHTTPHeaderField: "Authorization"))
    }

    func testInvalidPersistedSourceBlocksDiscoveryProbeChatAgentAndCache() async throws {
        defaults.set("http://user:secret@remote.local?secret", forKey: OllamaEndpointConfiguration.endpointKey)
        endpointConfiguration = OllamaEndpointConfiguration(userDefaults: defaults, credentialStore: OllamaMemoryHelperStore(), directSession: session)
        accessManager = ProviderAccessManager(keychainService: keychainService, sessionStore: sessionStore, ollamaEndpointConfiguration: endpointConfiguration)
        let service = OllamaService(endpointConfiguration: endpointConfiguration, providerAccessManager: accessManager)
        XCTAssertNotNil(service.error as? OllamaEndpointConfiguration.ValidationError)
        service.refreshModels()
        try await waitUntil { !service.isLoading }
        XCTAssertTrue(service.availableModels.isEmpty)
        XCTAssertNotNil(service.error as? OllamaEndpointConfiguration.ValidationError)
        do { try await service.checkConnection(); XCTFail("Expected invalid source") }
        catch { XCTAssertNotNil(error as? OllamaEndpointConfiguration.ValidationError) }
        let client = makeClient()
        let model = Model.ollama(.init(rawValue: "local:cloud")!)
        do {
            _ = try await client.performChatCompletionRequest(messages: [], model: model, tools: nil, toolChoice: nil)
            XCTFail("Expected invalid source")
        } catch { XCTAssertNotNil(error as? OllamaEndpointConfiguration.ValidationError) }
        XCTAssertThrowsError(try client.agentContext(messages: [], model: model) { _ in })
        XCTAssertTrue(OllamaRoutingURLProtocol.requests().isEmpty)
        XCTAssertNil(defaults.object(forKey: OllamaEndpointConfiguration.modelsByEndpointKey))
        let vm = OllamaSettingsView.ViewModel(ollamaService: service)
        XCTAssertEqual(vm.serverUrl, "")
        XCTAssertEqual(vm.editingServerUrl, "")
        XCTAssertFalse(try XCTUnwrap(vm.endpointValidationError).contains("secret"))
    }

    func testFailedAndUnchangedSettingsSavesPreserveOperationsModelsAndDiagnostics() throws {
        let service = OllamaService(endpointConfiguration: endpointConfiguration, session: session, providerAccessManager: accessManager)
        service.availableModels = [.init(rawValue: "old")!]
        service.error = URLError(.cannotConnectToHost)
        let vm = OllamaSettingsView.ViewModel(ollamaService: service)
        vm.loadingModelName = "loading"
        vm.isPulling = true
        vm.pullProgress = 0.5
        vm.pullError = "keep pull diagnostic"
        vm.isConnected = true
        vm.connectionError = "keep connection diagnostic"
        let original = endpointConfiguration.snapshot()
        vm.editingServerUrl = "http://remote.local"
        XCTAssertFalse(vm.updateServerUrl())
        XCTAssertEqual(endpointConfiguration.snapshot(), original)
        XCTAssertEqual(vm.serverUrl, "http://localhost:11434")
        XCTAssertNotNil(vm.endpointValidationError)
        vm.editingServerUrl = " http://localhost:11434/ "
        XCTAssertTrue(vm.updateServerUrl())
        XCTAssertEqual(endpointConfiguration.snapshot(), original)
        XCTAssertEqual(vm.loadingModelName, "loading")
        XCTAssertTrue(vm.isPulling)
        XCTAssertEqual(vm.pullProgress, 0.5)
        XCTAssertEqual(vm.pullError, "keep pull diagnostic")
        XCTAssertTrue(vm.isConnected)
        XCTAssertEqual(vm.connectionError, "keep connection diagnostic")
        XCTAssertEqual(service.availableModels.map(\.rawValue), ["old"])
        XCTAssertEqual((service.error as? URLError)?.code, .cannotConnectToHost)
        XCTAssertTrue(OllamaRoutingURLProtocol.requests().isEmpty)
    }

    func testStaleSuccessfulAndFailedProbesThrowCancellationAndNeverRetarget() async throws {
        for success in [true, false] {
            OllamaRoutingURLProtocol.reset()
            let old = try endpointConfiguration.update("https://old.local/base")
            OllamaRoutingURLProtocol.handler = { request in
                XCTAssertEqual(request.url?.host, "old.local")
                return .json(success ? #"{"version":"0.5.0"}"# : #"{"invalid":true}"#, delay: 0.1)
            }
            let service = OllamaService(endpointConfiguration: endpointConfiguration, providerAccessManager: accessManager)
            let pending = Task { try await service.checkConnection(for: old) }
            try await waitUntil { !OllamaRoutingURLProtocol.requests().isEmpty }
            _ = try endpointConfiguration.update("https://new.local/base")
            do { try await pending.value; XCTFail("Stale probe must not succeed") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(OllamaRoutingURLProtocol.requests().count, 1)
            do { try await service.checkConnection(for: old); XCTFail("Already stale probe") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(OllamaRoutingURLProtocol.requests().count, 1)
        }
    }

    func testCancelledProbeDoesNotClearExistingDiagnosticOrPublishModels() async throws {
        OllamaRoutingURLProtocol.handler = { _ in .json(#"{"version":"0.5.0"}"#, delay: 0.1) }
        let service = OllamaService(endpointConfiguration: endpointConfiguration, session: session, providerAccessManager: accessManager)
        service.error = URLError(.cannotConnectToHost)
        let probe = Task { try await service.checkConnection() }
        try await waitUntil { !OllamaRoutingURLProtocol.requests().isEmpty }
        probe.cancel()
        do { try await probe.value; XCTFail("Cancelled probe") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual((service.error as? URLError)?.code, .cannotConnectToHost)
        XCTAssertTrue(service.availableModels.isEmpty)
    }

    func testSelectedHelperIsIndependentOfInvalidDormantDirectSourceAndDisconnectHasNoDestination() throws {
        defaults.set("http://remote.local", forKey: OllamaEndpointConfiguration.endpointKey)
        endpointConfiguration = OllamaEndpointConfiguration(userDefaults: defaults, credentialStore: OllamaMemoryHelperStore(), directSession: session)
        let connection = helperConnection(helperID: UUID().uuidString, host: "192.168.1.10", token: "a")
        try endpointConfiguration.selectHelper(connection)
        let selected = endpointConfiguration.snapshot()
        XCTAssertNil(selected.validationError)
        XCTAssertNotNil(endpointConfiguration.directValidationError)
        let captured = try selected.makeToolchain()
        let request = Ollama.ChatRequest(model: .init(rawValue: "local:cloud")!, messages: [], stream: false)
        XCTAssertEqual(try captured.prepare(request: request).url?.path, "/v1/ollama/api/chat")
        try endpointConfiguration.disconnectHelper()
        let disconnected = endpointConfiguration.snapshot()
        XCTAssertTrue(disconnected.isHelper)
        XCTAssertNil(disconnected.baseURL)
        XCTAssertNil(disconnected.cacheScope)
        XCTAssertFalse(endpointConfiguration.storeModels([.init(rawValue: "blocked")!], for: disconnected))
        XCTAssertThrowsError(try disconnected.makeToolchain())
        XCTAssertEqual(try captured.prepare(request: request).value(forHTTPHeaderField: "Authorization"), "Bearer \(connection.credential.token)")
        endpointConfiguration.useDirect()
        XCTAssertNil(endpointConfiguration.snapshot().baseURL)
        XCTAssertThrowsError(try endpointConfiguration.snapshot().makeToolchain())
    }

    func testLocalCloudSuffixKeepsFullModelIDAndNeverUsesCloudKeyOrAuthority() async throws {
        keychainService.saveApiKey(apiKey: "synthetic-cloud-secret", for: .ollama)
        accessManager.refresh()
        _ = try endpointConfiguration.update("https://daemon.local/custom%20base")
        OllamaRoutingURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "daemon.local")
            XCTAssertEqual(request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath }, "/custom%20base/api/chat")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: OllamaRoutingURLProtocol.requestBody(request)) as? [String: Any])
            XCTAssertEqual(payload["model"] as? String, "local:cloud")
            return .json(Self.chatResponse(content: "local"))
        }
        let client = makeClient()
        let local = Model.ollama(.init(rawValue: "local:cloud")!)
        let result = try await client.performChatCompletionRequest(messages: [], model: local, tools: nil, toolChoice: nil)
        XCTAssertEqual(result.text, "local")
        let agent = try client.agentContext(messages: [], model: local) { _ in }
        XCTAssertEqual((agent.model as? Ollama.Model)?.rawValue, "local:cloud")
        let request = try agent.langTool.prepare(request: Ollama.ChatRequest(model: .init(rawValue: "local:cloud")!, messages: []))
        XCTAssertEqual(request.url?.host, "daemon.local")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let count = OllamaRoutingURLProtocol.requests().count
        do {
            _ = try await client.performChatCompletionRequest(messages: [], model: .ollamaCloud(.init(rawValue: "local:cloud")!), tools: nil, toolChoice: nil)
            XCTFail("Standalone Cloud transport remains separate/unavailable")
        } catch { XCTAssertEqual(error as? NetworkClient.NetworkError, .ollamaCloudTransportUnavailable) }
        XCTAssertEqual(OllamaRoutingURLProtocol.requests().count, count)
    }

    func testInvalidLocalSourcePreservesIndependentCloudEligibilityOverrideAndCatalog() throws {
        let previousCloudCatalog = UserDefaults.standard.object(forKey: "ollamaCloudModels")
        defer { UserDefaults.standard.set(previousCloudCatalog, forKey: "ollamaCloudModels") }
        Model.updateCachedOllamaCloudModels([.init(rawValue: "synthetic-hosted:cloud")!])
        let local = endpointConfiguration.snapshot()
        XCTAssertTrue(endpointConfiguration.storeModels([.init(rawValue: "synthetic-local:cloud")!], for: local))
        keychainService.saveApiKey(apiKey: "synthetic-cloud-secret", for: .ollama)
        accessManager.refresh()
        XCTAssertTrue(accessManager.availableChatModels().contains { $0.rawValue == "ollama-cloud/synthetic-hosted" })
        defaults.set("http://remote.local", forKey: OllamaEndpointConfiguration.endpointKey)
        accessManager.refresh()
        XCTAssertTrue(accessManager.state(for: .ollama).availableModels.isEmpty)
        XCTAssertTrue(accessManager.availableChatModels().contains { $0.rawValue == "ollama-cloud/synthetic-hosted" })
        accessManager.configureOllamaCloudAccessEligibilityOverride { false }
        XCTAssertFalse(accessManager.availableChatModels().contains { $0.route == .ollamaCloud })
        keychainService.deleteApiKey(for: .ollama)
        accessManager.configureOllamaCloudAccessEligibilityOverride { true }
        XCTAssertTrue(accessManager.availableChatModels().contains { $0.rawValue == "ollama-cloud/synthetic-hosted" })
        accessManager.configureOllamaCloudAccessEligibilityOverride(nil)
        XCTAssertFalse(accessManager.availableChatModels().contains { $0.route == .ollamaCloud })
        XCTAssertEqual(Model.cachedOllamaCloudModels.map(\.rawValue), ["synthetic-hosted"])
        XCTAssertNil(endpointConfiguration.snapshot().baseURL)
    }

    func testCapturedToolchainPreservesIntermediateToolResponseCallbacksAndOldAuthority() async throws {
        let old = try endpointConfiguration.update("https://old.local/custom")
        let toolchain = try old.makeToolchain()
        _ = try endpointConfiguration.update("https://new.local")
        var toolCalls = 0
        let tool = OpenAI.Tool(name: "fixture_tool", description: nil, tool_schema: .init(), callback: { _, _ in
            toolCalls += 1
            return "synthetic tool result"
        })
        var requestCount = 0
        OllamaRoutingURLProtocol.handler = { request in
            requestCount += 1
            XCTAssertEqual(request.url?.host, "old.local")
            XCTAssertEqual(request.url?.path, "/custom/api/chat")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            if requestCount == 1 {
                return .json(#"{"model":"fixture-model","created_at":"2026-10-08T00:00:00Z","message":{"role":"assistant","content":"tool step","tool_calls":[{"function":{"name":"fixture_tool","arguments":{}}}]},"done":true}"#)
            }
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: OllamaRoutingURLProtocol.requestBody(request)) as? [String: Any])
            let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
            XCTAssertTrue(messages.contains { $0["role"] as? String == "tool" && $0["content"] as? String == "synthetic tool result" })
            return .json(Self.chatResponse(content: "final step"))
        }
        var callbacks: [String] = []
        let response = try await toolchain.perform(request: Ollama.ChatRequest(model: .init(rawValue: "fixture-model")!, messages: [], stream: false, tools: [tool]), onResponse: { response in
            callbacks.append(response.message?.content.text ?? "")
        })
        XCTAssertEqual(response.message?.content.text, "final step")
        XCTAssertEqual(callbacks, ["tool step", "final step"])
        XCTAssertEqual(toolCalls, 1)
        XCTAssertEqual(requestCount, 2)
    }

    private func helperConnection(helperID: String, host: String, token: String) -> MobileHelperConnection {
        let credential = MobileHelperCredential(endpoint: URL(string: "https://\(host):8086")!,
            helperID: helperID, fingerprint: String(repeating: "a", count: 64), name: "Test Mac",
            deviceID: UUID().uuidString, token: String(repeating: token, count: 64), capabilities: ["ollama"])
        // Each pairing owns a distinct synthetic session/lease, just like production.
        // Reusing a raw session across separate retirement leases would invalidate
        // a repaired pairing when the old captured operation completes.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OllamaRoutingURLProtocol.self]
        return MobileHelperConnection(credential: credential, session: URLSession(configuration: configuration))
    }

    private static func generationOverrides() throws -> ChatGenerationSettings {
        try ChatGenerationSettings(maxOutputTokens: 512, temperature: 0, topP: 0.8,
            frequencyPenalty: 0.2, presencePenalty: -0.1, topK: 40, seed: 42, stop: ["STOP"])
    }

    private static func assertGenerationOverrides(in request: URLRequest, settings: ChatGenerationSettings) throws -> Bool {
        let body = try OllamaRoutingURLProtocol.requestBody(request)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(payload["model"] as? String, "llama3.2")
        let options = try XCTUnwrap(payload["options"] as? [String: Any])
        XCTAssertEqual(options["num_predict"] as? Int, settings.maxOutputTokens)
        XCTAssertEqual(options["temperature"] as? Double, settings.temperature)
        XCTAssertEqual(options["top_p"] as? Double, settings.topP)
        XCTAssertEqual(options["frequency_penalty"] as? Double, settings.frequencyPenalty)
        XCTAssertEqual(options["presence_penalty"] as? Double, settings.presencePenalty)
        XCTAssertEqual(options["top_k"] as? Int, settings.topK)
        XCTAssertEqual(options["seed"] as? Int, settings.seed)
        XCTAssertEqual(options["stop"] as? [String], settings.stop)
        XCTAssertEqual(request.httpMethod, "POST")
        return try XCTUnwrap(payload["stream"] as? Bool)
    }

    private func makeClient(generationSettingsProvider: @escaping @Sendable () -> ChatGenerationSettings = { .automatic }) -> NetworkClient {
        NetworkClient(
            keychainService: keychainService,
            accountLoginService: RoutingStubAccountLoginService(),
            providerAccessManager: accessManager,
            ollamaEndpointConfiguration: endpointConfiguration,
            ollamaSession: session,
            generationSettingsProvider: generationSettingsProvider
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { throw WaitError.timedOut }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private static func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
        var value = ""
        for try await chunk in stream { value += chunk }
        return value
    }

    private static func modelsResponse(named name: String) -> String {
        #"{"models":[{"name":"\#(name)","modified_at":"2025-01-01T00:00:00Z","size":1,"digest":"digest","details":{"format":"gguf","family":"llama","families":[],"parameter_size":"1B","quantization_level":"Q4"}}]}"#
    }

    private static func chatResponse(content: String, done: Bool = true) -> String {
        #"{"model":"llama3.2","created_at":"2025-01-01T00:00:00Z","message":{"role":"assistant","content":"\#(content)"},"done":\#(done)}"#
    }

    private enum WaitError: Error { case timedOut }
}

private final class OllamaRoutingURLProtocol: URLProtocol {
    struct Stub {
        let statusCode: Int
        let bodyChunks: [Data]
        let delay: TimeInterval
        let interChunkDelay: TimeInterval

        static func json(_ body: String, delay: TimeInterval = 0) -> Stub {
            Stub(statusCode: 200, bodyChunks: [Data(body.utf8)], delay: delay, interChunkDelay: 0)
        }

        static func stream(_ lines: [String], interChunkDelay: TimeInterval) -> Stub {
            Stub(
                statusCode: 200,
                bodyChunks: lines.map { Data(($0 + "\n").utf8) },
                delay: 0,
                interChunkDelay: interChunkDelay
            )
        }
    }

    static var handler: ((URLRequest) throws -> Stub)? {
        get { lock.withLock { storedHandler } }
        set { lock.withLock { storedHandler = newValue } }
    }

    private static let lock = NSLock()
    private static var storedHandler: ((URLRequest) throws -> Stub)?
    private static var recordedRequests: [URLRequest] = []
    private var workItem: DispatchWorkItem?

    static func reset() {
        lock.withLock {
            storedHandler = nil
            recordedRequests = []
        }
    }

    static func requests() -> [URLRequest] {
        lock.withLock { recordedRequests }
    }

    static func requestBody(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
            if count == 0 { break }
            body.append(buffer, count: count)
        }
        return body
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let result: Result<Stub, Error> = Self.lock.withLock {
            Self.recordedRequests.append(request)
            return Result { try Self.storedHandler?(request) ?? { throw URLError(.badServerResponse) }() }
        }
        switch result {
        case .success(let stub):
            let item = DispatchWorkItem { [weak self] in
                guard let self, self.workItem?.isCancelled == false else { return }
                let response = HTTPURLResponse(
                    url: self.request.url!, statusCode: stub.statusCode,
                    httpVersion: nil, headerFields: ["Content-Type": "application/json"]
                )!
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                for chunk in stub.bodyChunks {
                    guard self.workItem?.isCancelled == false else { return }
                    self.client?.urlProtocol(self, didLoad: chunk)
                    if stub.interChunkDelay > 0 {
                        Thread.sleep(forTimeInterval: stub.interChunkDelay)
                    }
                }
                self.client?.urlProtocolDidFinishLoading(self)
            }
            workItem = item
            DispatchQueue.global().asyncAfter(deadline: .now() + stub.delay, execute: item)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        workItem?.cancel()
    }

}

private final class RoutingStubAccountLoginService: AccountLoginService {
    func beginLogin(for provider: AccountLoginProvider) async throws -> AccountSession { throw URLError(.userAuthenticationRequired) }
    func beginCodexHelperLogin() async throws -> AccountSession { throw URLError(.userAuthenticationRequired) }
    func handleRedirect(_ url: URL) async throws -> AccountSession { throw URLError(.userAuthenticationRequired) }
    func refreshSession(_ session: AccountSession) async throws -> AccountSession { session }
    func logout(provider: AccountLoginProvider) async throws {}
    func logoutCodexHelper() async throws {}
    func fetchAccessibleModels(for provider: AccountLoginProvider) async throws -> [String] { [] }
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
