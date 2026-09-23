import Anthropic
import Foundation
import Gemini
import KeychainAccess
import LangTools
import Ollama
import OpenAI
import XAI
import XCTest
@testable import Chat

@MainActor
final class NetworkClientAuthTests: XCTestCase {
    private var keychain: Keychain!
    private var keychainService: KeychainService!
    private var sessionStore: AuthSessionStore!
    private var accessManager: ProviderAccessManager!

    override func setUp() {
        super.setUp()
        keychain = Keychain(service: "NetworkClientAuthTests.\(UUID().uuidString)")
        keychainService = KeychainService(keychain: keychain)
        sessionStore = AuthSessionStore(keychain: keychain)
        accessManager = ProviderAccessManager(keychainService: keychainService, sessionStore: sessionStore)
    }

    override func tearDown() {
        try? keychain.removeAll()
        super.tearDown()
    }


    func testClaudeCodeAccountSessionStillUsesProxyTransport() async throws {
        let anthropicModel = try XCTUnwrap(Anthropic.Model.allCases.first)
        let session = AccountSession(
            provider: .claudeCode,
            accountIdentifier: "claude-user",
            accessToken: "access-token",
            accessibleModelIDs: [anthropicModel.rawValue]
        )
        try sessionStore.save(session)
        accessManager.refresh()

        let proxyTransport = TestAccountProxyTransport()
        let client = NetworkClient(
            keychainService: keychainService,
            accountLoginService: StubAccountLoginService(),
            accountProxyTransport: proxyTransport,
            providerAccessManager: accessManager
        )

        let message = try await client.performChatCompletionRequest(
            messages: [Message(text: "Hello", role: .user)],
            model: .claudeCode(anthropicModel),
            tools: nil,
            toolChoice: nil
        )

        XCTAssertEqual(message.text, "proxied response")
        XCTAssertEqual(proxyTransport.lastModel, .claudeCode(anthropicModel))
        XCTAssertEqual(proxyTransport.lastSession?.accountIdentifier, "claude-user")
    }

    func testDisconnectClearsLocalSessionWhenRemoteLogoutFails() async throws {
        try sessionStore.save(AccountSession(
            provider: .openAI,
            accountIdentifier: "openai-user",
            accessToken: "access-token",
            accessibleModelIDs: ["gpt-5.5"]
        ))
        accessManager.refresh()
        let client = NetworkClient(
            keychainService: keychainService,
            accountLoginService: FailingLogoutAccountLoginService(),
            accountProxyTransport: TestAccountProxyTransport(),
            providerAccessManager: accessManager
        )

        try await client.disconnectAccount(.openAI)

        XCTAssertNil(accessManager.session(for: .openAI))
        XCTAssertFalse(accessManager.statesForAccessUI().first { $0.accessDestination == .codex }?.hasAccountSession ?? true)
    }

    func testDisconnectClearsLocalSessionWhenAlreadyLoggedOutHelperReturnsSuccess() async throws {
        try sessionStore.save(AccountSession(
            provider: .openAI,
            accountIdentifier: "openai-user",
            accessToken: "access-token",
            accessibleModelIDs: ["gpt-5.5"]
        ))
        accessManager.refresh()
        let client = NetworkClient(
            keychainService: keychainService,
            accountLoginService: StubAccountLoginService(),
            accountProxyTransport: TestAccountProxyTransport(),
            providerAccessManager: accessManager
        )

        try await client.disconnectAccount(.openAI)

        XCTAssertNil(accessManager.session(for: .openAI))
        XCTAssertFalse(accessManager.statesForAccessUI().first { $0.accessDestination == .codex }?.hasAccountSession ?? true)
    }

    func testRequestForwardsToolEventHandlerToEveryProvider() throws {
        let client = NetworkClient(
            keychainService: keychainService,
            accountLoginService: StubAccountLoginService(),
            accountProxyTransport: TestAccountProxyTransport(),
            providerAccessManager: accessManager
        )
        let anthropicModel = try XCTUnwrap(Anthropic.Model.allCases.first)
        let xAIModel = try XCTUnwrap(XAI.Model.allCases.first)
        let geminiModel = try XCTUnwrap(Gemini.Model.allCases.first)
        let ollamaModel = try XCTUnwrap(Ollama.Model(rawValue: "llama3.2"))
        let models: [Model] = [
            .anthropic(anthropicModel),
            .claudeCode(anthropicModel),
            .openAI(.gpt4o_mini),
            .codex(.gpt5_5),
            .xAI(xAIModel),
            .gemini(geminiModel),
            .ollama(ollamaModel),
        ]
        let event = LangToolsToolEvent.toolCalled(TestToolSelection())
        var receivedEventCount = 0

        for model in models {
            let request = client.request(
                messages: [Message(text: "Hello", role: .user)],
                model: model,
                toolEventHandler: { _ in receivedEventCount += 1 }
            )
            switch request {
            case let request as Anthropic.MessageRequest:
                request.toolEventHandler?(event)
            case let request as OpenAI.ChatCompletionRequest:
                request.toolEventHandler?(event)
            case let request as Ollama.ChatRequest:
                request.toolEventHandler?(event)
            default:
                XCTFail("Unexpected request type for \(model)")
            }
        }

        XCTAssertEqual(receivedEventCount, models.count)
    }

    func testMissingAuthThrowsMissingApiKey() async throws {
        let client = NetworkClient(
            keychainService: keychainService,
            accountLoginService: StubAccountLoginService(),
            accountProxyTransport: TestAccountProxyTransport(),
            providerAccessManager: accessManager
        )

        do {
            _ = try await client.performChatCompletionRequest(
                messages: [Message(text: "Hello", role: .user)],
                model: .openAI(.gpt4o_mini),
                tools: nil,
                toolChoice: nil
            )
            XCTFail("Expected missing auth error")
        } catch let error as NetworkClient.NetworkError {
            XCTAssertEqual(error, .missingApiKey)
        }
    }

    func testCodexAccountTransportOmitsUnsupportedTools() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccountProxyURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        AccountProxyURLProtocol.requestHandler = { request in
            let body = try AccountProxyURLProtocol.requestBody(request)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertNil(object["tools"])
            XCTAssertNil(object["toolChoice"])
            XCTAssertNil(object["conversationID"])
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"content":"Codex response"}"#.utf8))
        }
        defer { AccountProxyURLProtocol.requestHandler = nil }
        let transport = AccountProxyTransport(
            configuration: AccountBackendConfiguration(
                codexHelperBaseURL: URL(string: "http://127.0.0.1:9999")!,
                codexHelperToken: "helper-token"
            ),
            urlSession: urlSession
        )
        let session = AccountSession(
            provider: .openAI,
            accountIdentifier: "openai-user",
            accessToken: CodexSessionMarker.value,
            accessibleModelIDs: ["gpt-5.5"]
        )

        let response = try await transport.performChatCompletionRequest(
            messages: [Message(text: "Hello", role: .user)],
            model: .codex(.gpt5_5),
            session: session,
            tools: [Tool(name: "example", description: "Example", tool_schema: ToolSchema())],
            toolChoice: OpenAI.ChatCompletionRequest.ToolChoice.none
        )

        XCTAssertEqual(response.text, "Codex response")
    }

    func testCodexConversationPayloadAndCleanupUseHelperCredentials() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccountProxyURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        let conversationID = UUID()
        let cleanup = expectation(description: "cleanup request")
        AccountProxyURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer helper-token")
            if request.httpMethod == "DELETE" {
                XCTAssertEqual(request.url?.path, "/v1/account/conversations/\(conversationID.uuidString.lowercased())")
                cleanup.fulfill()
                return (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
            }
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try AccountProxyURLProtocol.requestBody(request)) as? [String: Any])
            XCTAssertEqual(object["conversationID"] as? String, conversationID.uuidString)
            XCTAssertNil(object["tools"])
            XCTAssertNil(object["toolChoice"])
            return (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(#"{"content":"Codex response"}"#.utf8))
        }
        defer { AccountProxyURLProtocol.requestHandler = nil }
        let transport = AccountProxyTransport(
            configuration: AccountBackendConfiguration(
                codexHelperBaseURL: URL(string: "http://127.0.0.1:9999")!,
                codexHelperToken: "helper-token"
            ),
            urlSession: urlSession
        )
        let session = AccountSession(
            provider: .openAI,
            accountIdentifier: "openai-user",
            accessToken: CodexSessionMarker.value,
            accessibleModelIDs: ["gpt-5.5"]
        )

        _ = try await transport.performChatCompletionRequest(
            messages: [Message(text: "Hello", role: .user)],
            model: .codex(.gpt5_5),
            session: session,
            conversationID: conversationID,
            tools: [Tool(name: "example", description: "Example", tool_schema: ToolSchema())],
            toolChoice: .auto
        )
        await transport.endConversation(id: conversationID)
        await fulfillment(of: [cleanup], timeout: 1)
    }

    func testInvalidCodexDestinationFailsBeforeStartingURLSession() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccountProxyURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        AccountProxyURLProtocol.requestHandler = { _ in
            XCTFail("Invalid routing must fail before URLSession starts")
            throw URLError(.badURL)
        }
        defer { AccountProxyURLProtocol.requestHandler = nil }
        let transport = AccountProxyTransport(
            configuration: AccountBackendConfiguration(
                codexHelperBaseURL: URL(string: "https://example.com:8765")!,
                codexHelperToken: "helper-token"
            ),
            urlSession: urlSession
        )
        let session = AccountSession(provider: .openAI, accountIdentifier: "acct", accessToken: CodexSessionMarker.value)

        do {
            _ = try await transport.performChatCompletionRequest(
                messages: [Message(text: "Hello", role: .user)],
                model: .codex(.gpt5_5),
                session: session,
                tools: nil,
                toolChoice: nil
            )
            XCTFail("Expected invalid destination error")
        } catch let error as NetworkClient.NetworkError {
            guard case .accountProxyTransportFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAccountProxyStreamParsesStrictNDJSONIncrementally() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccountProxyURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        AccountProxyURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/x-ndjson"])!
            let body = """
            {"type":"delta","delta":"Hello ","content":null,"error":null}
            {"type":"delta","delta":"world","content":null,"error":null}
            {"type":"complete","delta":null,"content":"Hello world","error":null}

            """
            return (response, Data(body.utf8))
        }
        defer { AccountProxyURLProtocol.requestHandler = nil }
        let transport = AccountProxyTransport(
            configuration: AccountBackendConfiguration(
                codexHelperBaseURL: URL(string: "http://127.0.0.1:9999")!,
                codexHelperToken: "helper-token"
            ),
            urlSession: urlSession
        )
        let session = AccountSession(provider: .openAI, accountIdentifier: "acct", accessToken: CodexSessionMarker.value)
        let stream = try transport.streamChatCompletionRequest(
            messages: [Message(text: "Hello", role: .user)],
            model: .codex(.gpt5_5),
            session: session,
            stream: true,
            tools: nil,
            toolChoice: nil
        )

        var chunks: [String] = []
        for try await chunk in stream { chunks.append(chunk) }

        XCTAssertEqual(chunks, ["Hello ", "world"])
    }

    func testCancellingStreamConsumerCancelsUnderlyingURLSessionRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DelayedAccountProxyURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        let stopped = expectation(description: "URLSession request stopped")
        DelayedAccountProxyURLProtocol.stopHandler = { stopped.fulfill() }
        defer { DelayedAccountProxyURLProtocol.stopHandler = nil }
        let transport = AccountProxyTransport(
            configuration: AccountBackendConfiguration(
                codexHelperBaseURL: URL(string: "http://127.0.0.1:9999")!,
                codexHelperToken: "helper-token"
            ),
            urlSession: urlSession
        )
        let stream = try transport.streamChatCompletionRequest(
            messages: [],
            model: .codex(.gpt5_5),
            session: AccountSession(provider: .openAI, accountIdentifier: "acct", accessToken: CodexSessionMarker.value),
            stream: true,
            tools: nil,
            toolChoice: nil
        )
        let receivedFirstDelta = expectation(description: "first delta")
        let consumer = Task {
            var iterator = stream.makeAsyncIterator()
            let first = try await iterator.next()
            XCTAssertEqual(first, "first")
            receivedFirstDelta.fulfill()
            _ = try await iterator.next()
        }

        await fulfillment(of: [receivedFirstDelta], timeout: 1)
        consumer.cancel()
        _ = await consumer.result
        await fulfillment(of: [stopped], timeout: 1)
    }

    func testAccountProxyStreamRejectsMalformedNDJSON() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccountProxyURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        AccountProxyURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("{not-json}\n".utf8))
        }
        defer { AccountProxyURLProtocol.requestHandler = nil }
        let transport = AccountProxyTransport(
            configuration: AccountBackendConfiguration(
                codexHelperBaseURL: URL(string: "http://127.0.0.1:9999")!,
                codexHelperToken: "helper-token"
            ),
            urlSession: urlSession
        )
        let stream = try transport.streamChatCompletionRequest(
            messages: [],
            model: .codex(.gpt5_5),
            session: AccountSession(provider: .openAI, accountIdentifier: "acct", accessToken: CodexSessionMarker.value),
            stream: true,
            tools: nil,
            toolChoice: nil
        )

        do {
            for try await _ in stream {}
            XCTFail("Expected malformed NDJSON error")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func testOpenAIAccountSessionUsesCLIChatBridge() async throws {
        let session = AccountSession(
            provider: .openAI,
            accountIdentifier: "openai-user",
            accessToken: "access-token",
            accessibleModelIDs: ["gpt-5.5"]
        )
        try sessionStore.save(session)
        accessManager.refresh()

        let proxyTransport = TestAccountProxyTransport()
        let bridge = TestOpenAIAccountChatBridge()
        let client = NetworkClient(
            keychainService: keychainService,
            accountLoginService: StubAccountLoginService(),
            accountProxyTransport: proxyTransport,
            openAIAccountChatBridge: bridge,
            providerAccessManager: accessManager
        )

        let message = try await client.performChatCompletionRequest(
            messages: [Message(text: "Hello", role: .user)],
            model: .codex(.gpt5_5),
            tools: nil,
            toolChoice: nil
        )

        XCTAssertEqual(message.text, "cli response")
        XCTAssertEqual(bridge.lastModel, .codex(.gpt5_5))
        XCTAssertNil(proxyTransport.lastSession)
    }

    func testCodexHelperMarkerUsesStatefulProxyAndEndsConversation() async throws {
        let session = AccountSession(
            provider: .openAI,
            accountIdentifier: "codex-helper",
            accessToken: CodexSessionMarker.value,
            accessibleModelIDs: ["gpt-5.5"]
        )
        try sessionStore.save(session)
        accessManager.refresh()

        let proxyTransport = TestAccountProxyTransport()
        let bridge = TestOpenAIAccountChatBridge()
        let client = NetworkClient(
            keychainService: keychainService,
            accountLoginService: StubAccountLoginService(),
            accountProxyTransport: proxyTransport,
            openAIAccountChatBridge: bridge,
            providerAccessManager: accessManager
        )
        let conversationID = UUID()

        let message = try await client.performChatCompletionRequest(
            messages: [Message(text: "Hello", role: .user)],
            model: .codex(.gpt5_5),
            conversationID: conversationID,
            tools: nil,
            toolChoice: nil
        )
        await client.endConversation(id: conversationID)

        XCTAssertEqual(message.text, "conversation proxied response")
        XCTAssertEqual(proxyTransport.lastConversationID, conversationID)
        XCTAssertEqual(proxyTransport.endedConversationIDs, [conversationID])
        XCTAssertNil(bridge.lastModel)
    }

    func testRealOpenAIAccountConversationUsesCLIAndDoesNotEndHelperSession() async throws {
        let session = AccountSession(
            provider: .openAI,
            accountIdentifier: "openai-user",
            accessToken: "access-token",
            accessibleModelIDs: ["gpt-5.5"]
        )
        try sessionStore.save(session)
        accessManager.refresh()

        let proxyTransport = TestAccountProxyTransport()
        let bridge = TestOpenAIAccountChatBridge()
        let client = NetworkClient(
            keychainService: keychainService,
            accountLoginService: StubAccountLoginService(),
            accountProxyTransport: proxyTransport,
            openAIAccountChatBridge: bridge,
            providerAccessManager: accessManager
        )
        let conversationID = UUID()

        let message = try await client.performChatCompletionRequest(
            messages: [Message(text: "Hello", role: .user)],
            model: .codex(.gpt5_5),
            conversationID: conversationID,
            tools: nil,
            toolChoice: nil
        )
        await client.endConversation(id: conversationID)

        XCTAssertEqual(message.text, "cli response")
        XCTAssertEqual(bridge.lastModel, .codex(.gpt5_5))
        XCTAssertNil(proxyTransport.lastConversationID)
        XCTAssertTrue(proxyTransport.endedConversationIDs.isEmpty)
    }

    func testRealOpenAIAccountStreamingUsesCLIWithoutHelperState() async throws {
        let session = AccountSession(
            provider: .openAI,
            accountIdentifier: "openai-user",
            accessToken: "access-token",
            accessibleModelIDs: ["gpt-5.5"]
        )
        try sessionStore.save(session)
        accessManager.refresh()

        let proxyTransport = TestAccountProxyTransport()
        let bridge = TestOpenAIAccountChatBridge()
        let client = NetworkClient(
            keychainService: keychainService,
            accountLoginService: StubAccountLoginService(),
            accountProxyTransport: proxyTransport,
            openAIAccountChatBridge: bridge,
            providerAccessManager: accessManager
        )
        let conversationID = UUID()

        let stream = try client.streamChatCompletionRequest(
            messages: [Message(text: "Hello", role: .user)],
            model: .codex(.gpt5_5),
            conversationID: conversationID,
            stream: true,
            tools: nil,
            toolChoice: nil
        )
        var chunks: [String] = []
        for try await chunk in stream { chunks.append(chunk) }
        await client.endConversation(id: conversationID)

        XCTAssertEqual(chunks, ["cli response"])
        XCTAssertEqual(bridge.lastModel, .codex(.gpt5_5))
        XCTAssertNil(proxyTransport.lastConversationID)
        XCTAssertTrue(proxyTransport.endedConversationIDs.isEmpty)
    }

    func testCodexHelperMarkerStreamingUsesStatefulProxy() async throws {
        let session = AccountSession(
            provider: .openAI,
            accountIdentifier: "codex-helper",
            accessToken: CodexSessionMarker.value,
            accessibleModelIDs: ["gpt-5.5"]
        )
        try sessionStore.save(session)
        accessManager.refresh()

        let proxyTransport = TestAccountProxyTransport()
        let bridge = TestOpenAIAccountChatBridge()
        let client = NetworkClient(
            keychainService: keychainService,
            accountLoginService: StubAccountLoginService(),
            accountProxyTransport: proxyTransport,
            openAIAccountChatBridge: bridge,
            providerAccessManager: accessManager
        )
        let conversationID = UUID()

        let stream = try client.streamChatCompletionRequest(
            messages: [Message(text: "Hello", role: .user)],
            model: .codex(.gpt5_5),
            conversationID: conversationID,
            stream: true,
            tools: nil,
            toolChoice: nil
        )
        var chunks: [String] = []
        for try await chunk in stream { chunks.append(chunk) }

        XCTAssertEqual(chunks, ["conversation proxied response"])
        XCTAssertEqual(proxyTransport.lastConversationID, conversationID)
        XCTAssertNil(bridge.lastModel)
    }

    func testOpenAIAccountChatBridgeErrorsPropagate() async throws {
        let session = AccountSession(
            provider: .openAI,
            accountIdentifier: "openai-user",
            accessToken: "access-token",
            accessibleModelIDs: ["gpt-5.5"]
        )
        try sessionStore.save(session)
        accessManager.refresh()

        let expectedError = CLIAccountSessionBridgeError.commandFailed("Error: OpenAI request failed (status 429): You exceeded your current quota")
        let bridge = TestOpenAIAccountChatBridge(error: expectedError)
        let client = NetworkClient(
            keychainService: keychainService,
            accountLoginService: StubAccountLoginService(),
            accountProxyTransport: TestAccountProxyTransport(),
            openAIAccountChatBridge: bridge,
            providerAccessManager: accessManager
        )

        do {
            _ = try await client.performChatCompletionRequest(
                messages: [Message(text: "Hello", role: .user)],
                model: .codex(.gpt5_5),
                tools: nil,
                toolChoice: nil
            )
            XCTFail("Expected bridge error")
        } catch let error as CLIAccountSessionBridgeError {
            XCTAssertEqual(error, expectedError)
        }
    }
}

private struct TestToolSelection: LangToolsToolSelection {
    let id: String?
    let name: String?
    let arguments: String

    init(id: String? = "test-call", name: String? = "test-tool", arguments: String = "{}") {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

private final class AccountProxyURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.requestHandler)
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

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
}

private final class DelayedAccountProxyURLProtocol: URLProtocol {
    static var stopHandler: (() -> Void)?
    private var completion: DispatchWorkItem?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/x-ndjson"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"type\":\"delta\",\"delta\":\"first\",\"content\":null,\"error\":null}\n".utf8))
        let completion = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.client?.urlProtocol(self, didLoad: Data("{\"type\":\"complete\",\"delta\":null,\"content\":\"first\",\"error\":null}\n".utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
        self.completion = completion
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: completion)
    }

    override func stopLoading() {
        completion?.cancel()
        Self.stopHandler?()
    }
}

private struct FailingLogoutAccountLoginService: AccountLoginService {
    func beginLogin(for provider: AccountLoginProvider) async throws -> AccountSession {
        throw AccountLoginError.sessionExchangeFailed("Not implemented")
    }

    func handleRedirect(_ url: URL) async throws -> AccountSession {
        throw AccountLoginError.sessionExchangeFailed("Not implemented")
    }

    func refreshSession(_ session: AccountSession) async throws -> AccountSession { session }

    func logout(provider: AccountLoginProvider) async throws {
        throw AccountLoginError.sessionExchangeFailed("Codex helper rejected the request.")
    }

    func fetchAccessibleModels(for provider: AccountLoginProvider) async throws -> [String] { [] }
}

private final class TestAccountProxyTransport: ConversationAwareAccountProxyTransportProtocol {
    private(set) var lastSession: AccountSession?
    private(set) var lastModel: Model?
    private(set) var lastConversationID: UUID?
    private(set) var endedConversationIDs: [UUID] = []
    private let error: Error?

    init(error: Error? = nil) {
        self.error = error
    }

    func performChatCompletionRequest(messages: [Message], model: Model, session: AccountSession, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?) async throws -> Message {
        _ = messages
        _ = tools
        _ = toolChoice
        lastSession = session
        lastModel = model
        if let error {
            throw error
        }
        return Message(text: "proxied response", role: .assistant)
    }

    func streamChatCompletionRequest(messages: [Message], model: Model, session: AccountSession, stream: Bool, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?) throws -> AsyncThrowingStream<String, Error> {
        _ = messages
        _ = stream
        _ = tools
        _ = toolChoice
        lastSession = session
        lastModel = model
        if let error {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: error)
            }
        }
        return AsyncThrowingStream { continuation in
            continuation.yield("proxied response")
            continuation.finish()
        }
    }

    func performChatCompletionRequest(messages: [Message], model: Model, session: AccountSession, conversationID: UUID, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?) async throws -> Message {
        _ = messages
        _ = tools
        _ = toolChoice
        lastSession = session
        lastModel = model
        lastConversationID = conversationID
        if let error { throw error }
        return Message(text: "conversation proxied response", role: .assistant)
    }

    func streamChatCompletionRequest(messages: [Message], model: Model, session: AccountSession, conversationID: UUID, stream: Bool, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?) throws -> AsyncThrowingStream<String, Error> {
        _ = messages
        _ = stream
        _ = tools
        _ = toolChoice
        lastSession = session
        lastModel = model
        lastConversationID = conversationID
        if let error {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: error)
            }
        }
        return AsyncThrowingStream { continuation in
            continuation.yield("conversation proxied response")
            continuation.finish()
        }
    }

    func endConversation(id: UUID) async {
        endedConversationIDs.append(id)
    }
}

private final class TestOpenAIAccountChatBridge: OpenAIAccountChatBridging {
    private(set) var lastMessages: [Message] = []
    private(set) var lastModel: Model?
    private let error: Error?

    init(error: Error? = nil) {
        self.error = error
    }

    func performOpenAIChat(messages: [Message], model: Model) async throws -> Message {
        lastMessages = messages
        lastModel = model
        if let error {
            throw error
        }
        return Message(text: "cli response", role: .assistant)
    }
}
