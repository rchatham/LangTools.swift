import Agents
import Foundation
import KeychainAccess
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
    private var keychain: Keychain!
    private var keychainService: KeychainService!
    private var sessionStore: AuthSessionStore!
    private var accessManager: ProviderAccessManager!

    override func setUp() {
        super.setUp()
        suiteName = "OllamaEndpointRoutingTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        endpointConfiguration = OllamaEndpointConfiguration(userDefaults: defaults,
            credentialStore: MobileHelperCredentialStore(keychain: Keychain(service: suiteName + ".helper")))

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OllamaRoutingURLProtocol.self]
        session = URLSession(configuration: configuration)
        OllamaRoutingURLProtocol.reset()

        keychain = Keychain(service: suiteName)
        keychainService = KeychainService(keychain: keychain)
        sessionStore = AuthSessionStore(keychain: keychain)
        accessManager = ProviderAccessManager(
            keychainService: keychainService,
            sessionStore: sessionStore,
            ollamaEndpointConfiguration: endpointConfiguration
        )
    }

    override func tearDown() {
        session.invalidateAndCancel()
        try? keychain.removeAll()
        defaults.removePersistentDomain(forName: suiteName)
        OllamaRoutingURLProtocol.reset()
        super.tearDown()
    }

    func testDiscoveryVersionChatStreamAndAgentUseConfiguredEndpoint() async throws {
        _ = try endpointConfiguration.update("http://mac.local:11434")
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
        let agentProvider = try XCTUnwrap(context.langTool as? Ollama)
        XCTAssertEqual(agentProvider.configuration.baseURL.absoluteString, "http://mac.local:11434")

        let requests = OllamaRoutingURLProtocol.requests()
        XCTAssertTrue(requests.allSatisfy { $0.url?.host == "mac.local" })
        XCTAssertTrue(Set(requests.compactMap { $0.url?.path }).isSuperset(of: ["/api/tags", "/api/ps", "/api/version", "/api/chat"]))
    }

    func testStreamingCapturesEndpointBeforeEndpointChanges() async throws {
        _ = try endpointConfiguration.update("http://old.local:11434")
        OllamaRoutingURLProtocol.handler = { request in
            .json(Self.chatResponse(content: request.url?.host ?? "missing"), delay: 0.1)
        }
        let client = makeClient()
        let model = Model.ollama(try XCTUnwrap(Ollama.Model(rawValue: "llama3.2")))

        let oldStream = try client.streamChatCompletionRequest(
            messages: [Message(text: "Hi", role: .user)], model: model, stream: true,
            tools: nil, toolChoice: nil
        )
        _ = try endpointConfiguration.update("http://new.local:11434")
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
        _ = try endpointConfiguration.update("http://stream.local:11434")
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
        let capturedSnapshot = try endpointConfiguration.update("http://a.local:11434")
        _ = try endpointConfiguration.update("http://b.local:11434")
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
        _ = try endpointConfiguration.update("http://a.local:11434")
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

        let currentSnapshot = try endpointConfiguration.update("http://b.local:11434")
        viewModel.checkConnection(for: currentSnapshot)
        try await waitUntil { viewModel.isConnected && !viewModel.isCheckingConnection }
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(viewModel.isConnected)
        XCTAssertFalse(viewModel.isCheckingConnection)
        XCTAssertNil(viewModel.connectionError)
    }

    func testInFlightChatsRemainBoundToCapturedEndpoints() async throws {
        _ = try endpointConfiguration.update("http://old.local:11434")
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
        _ = try endpointConfiguration.update("http://new.local:11434")
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
        _ = try service.updateEndpoint("http://old.local:11434")
        try await waitUntil { OllamaRoutingURLProtocol.requests().contains { $0.url?.host == "old.local" } }
        _ = try service.updateEndpoint("http://new.local:11434")

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

        _ = try service.updateEndpoint("http://a.local:11434")
        try await waitUntil {
            OllamaRoutingURLProtocol.requests().contains { $0.url?.host == "a.local" && $0.url?.path == "/api/tags" }
        }
        _ = try service.updateEndpoint("http://b.local:11434")
        try await waitUntil {
            OllamaRoutingURLProtocol.requests().contains { $0.url?.host == "b.local" && $0.url?.path == "/api/tags" }
        }
        _ = try service.updateEndpoint("http://a.local:11434")

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
        let viewModel = ChatSettingsView.ViewModel(clearMessages: {})
        viewModel.accessManager = accessManager
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
        let provider = try XCTUnwrap(context.langTool as? Ollama)
        XCTAssertTrue(provider.session === session)
        XCTAssertEqual(provider.configuration.apiKey, credential.token)
        XCTAssertEqual(provider.configuration.baseURL.path, "/v1/ollama")
        XCTAssertTrue(OllamaRoutingURLProtocol.requests().allSatisfy { $0.url?.host == "192.168.1.10" })
        try endpointConfiguration.disconnectHelper()
    }

    func testHelperStreamsCaptureOldCredentialsWhenSameIdentityIsRepaired() async throws {
        let helperID = UUID().uuidString
        func connection(token: String) -> MobileHelperConnection {
            let credential = MobileHelperCredential(endpoint: URL(string: "https://192.168.1.10:8086")!, helperID: helperID,
                fingerprint: String(repeating: "a", count: 64), name: "Mac", deviceID: UUID().uuidString,
                token: String(repeating: token, count: 64), capabilities: ["ollama"])
            return MobileHelperConnection(credential: credential, session: session)
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
        XCTAssertEqual((context.langTool as? Ollama)?.configuration.apiKey, String(repeating: "a", count: 64))
        let next = try client.streamChatCompletionRequest(messages: [], model: model, stream: true, tools: nil, toolChoice: nil)
        let nextResult = try await Self.collect(next)
        XCTAssertEqual(nextResult, "b")
        try endpointConfiguration.disconnectHelper()
    }

    private func makeClient() -> NetworkClient {
        NetworkClient(
            keychainService: keychainService,
            accountLoginService: RoutingStubAccountLoginService(),
            providerAccessManager: accessManager,
            ollamaEndpointConfiguration: endpointConfiguration,
            ollamaSession: session
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
