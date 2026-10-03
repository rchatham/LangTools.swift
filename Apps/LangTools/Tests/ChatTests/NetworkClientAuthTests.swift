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
        await MainActor.run { accessManager.refresh() }

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
        await MainActor.run { accessManager.refresh() }
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
        await MainActor.run { accessManager.refresh() }
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

    func testGeminiRequestEncodesToolsAndToolChoiceAndWiresHandler() throws {
        let client = NetworkClient(
            keychainService: keychainService,
            accountLoginService: StubAccountLoginService(),
            accountProxyTransport: TestAccountProxyTransport(),
            providerAccessManager: accessManager
        )
        let geminiModel = try XCTUnwrap(Gemini.Model.allCases.first)
        let tool = Tool(name: "lookup_weather", description: "Look up weather", tool_schema: ToolSchema())
        let event = LangToolsToolEvent.toolCalled(TestToolSelection(name: "lookup_weather"))
        var receivedEventCount = 0

        let request = try XCTUnwrap(client.request(
            messages: [Message(text: "What is the weather?", role: .user)],
            model: .gemini(geminiModel),
            tools: [tool],
            toolChoice: .required,
            toolEventHandler: { _ in receivedEventCount += 1 }
        ) as? OpenAI.ChatCompletionRequest)
        let encoded = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let encodedTools = try XCTUnwrap(object["tools"] as? [[String: Any]])
        let encodedFunction = try XCTUnwrap(encodedTools.first?["function"] as? [String: Any])

        XCTAssertEqual(encodedFunction["name"] as? String, "lookup_weather")
        XCTAssertEqual(object["tool_choice"] as? String, "required")
        request.toolEventHandler?(event)
        XCTAssertEqual(receivedEventCount, 1)
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

    func testCodexAccountRouteUsesAccountSessionEvenWhenOpenAIAPIKeyExists() async throws {
        keychainService.saveApiKey(apiKey: "sk-platform", for: .openAI)
        try sessionStore.save(AccountSession(
            provider: .openAI,
            accountIdentifier: "openai-user",
            accessToken: "account-access-token",
            accessibleModelIDs: ["gpt-5.5"]
        ))
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

    func testEmptyAuthoritativeAccountModelListFailsClosed() async throws {
        try sessionStore.save(AccountSession(
            provider: .openAI,
            accountIdentifier: "openai-user",
            accessToken: "account-access-token",
            accessibleModelIDs: []
        ))
        accessManager.refresh()
        let client = NetworkClient(
            keychainService: keychainService,
            accountLoginService: StubAccountLoginService(),
            accountProxyTransport: TestAccountProxyTransport(),
            openAIAccountChatBridge: TestOpenAIAccountChatBridge(),
            providerAccessManager: accessManager
        )

        do {
            _ = try await client.performChatCompletionRequest(
                messages: [Message(text: "Hello", role: .user)],
                model: .codex(.gpt5_5),
                tools: nil,
                toolChoice: nil
            )
            XCTFail("Expected empty model access list to deny the request")
        } catch let error as NetworkClient.NetworkError {
            XCTAssertEqual(error, .modelAccessUnavailable("codex/gpt-5.5"))
        }
    }

    func testCodexHelperConnectAndDisconnectPersistOnlyMarkerSession() async throws {
        let loginService = TestHelperAccountLoginService()
        let client = NetworkClient(
            keychainService: keychainService,
            accountLoginService: loginService,
            accountProxyTransport: TestAccountProxyTransport(),
            providerAccessManager: accessManager
        )

        try await client.connectCodexHelper()
        let stored = try XCTUnwrap(accessManager.session(for: .openAI))
        XCTAssertEqual(stored.accessToken, CodexSessionMarker.value)
        XCTAssertEqual(stored.accessibleModelIDs, ["gpt-5.5"])

        try await client.disconnectCodexHelper()
        XCTAssertTrue(loginService.didLogoutHelper)
        XCTAssertNil(accessManager.session(for: .openAI))
    }

    func testDisconnectDoesNotRemoveSessionConnectedWhileLogoutIsInFlight() async throws {
        let original = AccountSession(
            provider: .openAI,
            accountIdentifier: "original",
            accessToken: "original-token",
            accessibleModelIDs: ["gpt-5.5"]
        )
        try sessionStore.save(original)
        accessManager.refresh()
        let loginService = BlockingLogoutAccountLoginService()
        let client = NetworkClient(
            keychainService: keychainService,
            accountLoginService: loginService,
            accountProxyTransport: TestAccountProxyTransport(),
            providerAccessManager: accessManager
        )

        let disconnect = Task { try await client.disconnectAccount(.openAI) }
        await loginService.waitUntilLogoutStarted()
        let replacement = AccountSession(
            provider: .openAI,
            accountIdentifier: "replacement",
            accessToken: CodexSessionMarker.value,
            accessibleModelIDs: ["gpt-5.5"]
        )
        try accessManager.saveAccountSession(replacement)
        await loginService.finishLogout()
        try await disconnect.value

        XCTAssertEqual(accessManager.session(for: .openAI)?.id, replacement.id)
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
            XCTAssertNil(object["max_tokens"])
            XCTAssertNil(object["max_completion_tokens"])
            XCTAssertNil(object["temperature"])
            XCTAssertNil(object["options"])
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

    func testTransportReadsUpdatedHelperConfigurationForEachRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccountProxyURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        var port = 9999
        var token = "first-token"
        var requestCount = 0
        AccountProxyURLProtocol.requestHandler = { request in
            requestCount += 1
            XCTAssertEqual(request.url?.port, port)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 204, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        defer { AccountProxyURLProtocol.requestHandler = nil }
        let transport = AccountProxyTransport(configurationProvider: {
            AccountBackendConfiguration(
                codexHelperBaseURL: URL(string: "http://127.0.0.1:\(port)")!,
                codexHelperToken: token
            )
        }, urlSession: urlSession)

        await transport.endConversation(id: UUID())
        port = 8765
        token = "paired-token"
        await transport.endConversation(id: UUID())
        XCTAssertEqual(requestCount, 2)
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
        await MainActor.run { accessManager.refresh() }

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

@MainActor
final class NetworkClientGenerationSettingsTests: XCTestCase {
    private var keychain: Keychain!
    private var keychainService: KeychainService!
    private var sessionStore: AuthSessionStore!
    private var accessManager: ProviderAccessManager!

    override func setUp() {
        super.setUp()
        keychain = Keychain(service: "NetworkClientGenerationSettingsTests.\(UUID().uuidString)")
        keychainService = KeychainService(keychain: keychain)
        sessionStore = AuthSessionStore(keychain: keychain)
        accessManager = ProviderAccessManager(keychainService: keychainService, sessionStore: sessionStore)
    }

    override func tearDown() {
        try? keychain.removeAll()
        super.tearDown()
    }

    func testOpenAIFieldTranslationAndAutomaticOmission() throws {
        let client = makeClient()
        let automatic = try encodedRequest(client.request(
            messages: testMessages,
            model: .openAI(.gpt4o_mini),
            generationSettings: .automatic
        ))
        XCTAssertNil(automatic["max_tokens"])
        XCTAssertNil(automatic["max_completion_tokens"])
        XCTAssertNil(automatic["temperature"])

        let settings = try ChatGenerationSettings(maxOutputTokens: 2_048, temperature: 0.35)
        let ordinary = try encodedRequest(client.request(
            messages: testMessages,
            model: .openAI(.gpt4o_mini),
            generationSettings: settings
        ))
        XCTAssertEqual(ordinary["max_tokens"] as? Int, 2_048)
        XCTAssertNil(ordinary["max_completion_tokens"])
        XCTAssertEqual(ordinary["temperature"] as? Double, 0.35)

        let reasoning = try encodedRequest(client.request(
            messages: testMessages,
            model: .openAI(.gpt5),
            generationSettings: settings
        ))
        XCTAssertNil(reasoning["max_tokens"])
        XCTAssertEqual(reasoning["max_completion_tokens"] as? Int, 2_048)
        XCTAssertNil(reasoning["temperature"])
    }

    func testOpenAIOverboundTokensAreOmittedWithoutDroppingTemperature() throws {
        let client = makeClient()
        let object = try encodedRequest(client.request(
            messages: testMessages,
            model: .openAI(.gpt4),
            generationSettings: try ChatGenerationSettings(maxOutputTokens: 8_192, temperature: 0.35)
        ))

        XCTAssertNil(object["max_tokens"])
        XCTAssertNil(object["max_completion_tokens"])
        XCTAssertEqual(object["temperature"] as? Double, 0.35)
    }

    func testOpenAIOutputBoundsAtBoundaryAndOneAbove() throws {
        let client = makeClient()
        let cases: [(String, Int, String, Bool)] = [
            ("gpt-4", 4_096, "max_tokens", true),
            ("gpt-4o-2024-05-13", 4_096, "max_tokens", true),
            ("gpt-4o-2024-11-20", 16_384, "max_tokens", true),
            ("gpt-4.1", 32_768, "max_tokens", true),
            ("o1-mini", 65_536, "max_completion_tokens", false),
            ("o1", 100_000, "max_completion_tokens", false),
            ("o3", 100_000, "max_completion_tokens", false),
            ("gpt-5", 128_000, "max_completion_tokens", false),
            ("gpt-5-pro", 272_000, "max_completion_tokens", false),
            ("gpt-5.3", 32_768, "max_completion_tokens", false),
        ]
        for (modelID, bound, field, supportsTemperature) in cases {
            let model = Model.openAI(OpenAI.Model(customModelID: modelID))
            let atBound = try encodedRequest(client.request(
                messages: testMessages,
                model: model,
                generationSettings: try ChatGenerationSettings(maxOutputTokens: bound, temperature: 0.35)
            ))
            XCTAssertEqual(atBound[field] as? Int, bound, modelID)
            XCTAssertEqual(atBound["temperature"] as? Double, supportsTemperature ? 0.35 : nil, modelID)
            if bound < ChatGenerationSettings.tokenRange.upperBound {
                let aboveBound = try encodedRequest(client.request(
                    messages: testMessages,
                    model: model,
                    generationSettings: try ChatGenerationSettings(maxOutputTokens: bound + 1, temperature: 0.35)
                ))
                XCTAssertNil(aboveBound[field], modelID)
                XCTAssertEqual(aboveBound["temperature"] as? Double, supportsTemperature ? 0.35 : nil, modelID)
            }
        }
    }

    func testUnsupportedOpenAIModelsOmitBothOverrides() throws {
        let client = makeClient()
        for modelID in ["gpt-3.5-turbo-instruct", "gpt-5.3-codex-spark", "chatgpt-4o-latest", "future-chat-model"] {
            let object = try encodedRequest(client.request(
                messages: testMessages,
                model: .openAI(OpenAI.Model(customModelID: modelID)),
                generationSettings: try ChatGenerationSettings(maxOutputTokens: 1_024, temperature: 0.5)
            ))
            XCTAssertNil(object["max_tokens"], modelID)
            XCTAssertNil(object["max_completion_tokens"], modelID)
            XCTAssertNil(object["temperature"], modelID)
        }
    }

    func testAnthropicTranslationKeepsRequiredDefaultAndExplicitZero() throws {
        let providerModel = try XCTUnwrap(Anthropic.Model.allCases.first)
        let client = makeClient()
        let automatic = try encodedRequest(client.request(
            messages: testMessages,
            model: .anthropic(providerModel),
            generationSettings: .automatic
        ))
        XCTAssertEqual(automatic["max_tokens"] as? Int, 4_096)
        XCTAssertNil(automatic["temperature"])

        let overridden = try encodedRequest(client.request(
            messages: testMessages,
            model: .anthropic(providerModel),
            generationSettings: try ChatGenerationSettings(maxOutputTokens: 2_048, temperature: 0)
        ))
        XCTAssertEqual(overridden["max_tokens"] as? Int, 2_048)
        XCTAssertEqual(overridden["temperature"] as? Double, 0)
    }

    func testAnthropicOverboundOverrideFallsBackToRequiredDefaultWithoutDroppingTemperature() throws {
        let providerModel = try XCTUnwrap(Anthropic.Model(rawValue: "claude-sonnet-4-6"))
        let client = makeClient()
        let object = try encodedRequest(client.request(
            messages: testMessages,
            model: .anthropic(providerModel),
            generationSettings: try ChatGenerationSettings(maxOutputTokens: 128_001, temperature: 0.45)
        ))

        XCTAssertEqual(object["max_tokens"] as? Int, 4_096)
        XCTAssertEqual(object["temperature"] as? Double, 0.45)
    }

    func testAnthropicBoundaryAndOneAboveRetainsTemperature() throws {
        let providerModel = try XCTUnwrap(Anthropic.Model(rawValue: "claude-sonnet-4-6"))
        let client = makeClient()
        for (tokens, expected) in [(128_000, 128_000), (128_001, 4_096)] {
            let object = try encodedRequest(client.request(
                messages: testMessages,
                model: .anthropic(providerModel),
                generationSettings: try ChatGenerationSettings(maxOutputTokens: tokens, temperature: 0.45)
            ))
            XCTAssertEqual(object["max_tokens"] as? Int, expected)
            XCTAssertEqual(object["temperature"] as? Double, 0.45)
        }
    }

    func testXAIAndGeminiTranslationAndUnsupportedXAIFields() throws {
        let xAIModel = try XCTUnwrap(XAI.Model(rawValue: "grok-3"))
        let unsupportedXAIModel = try XCTUnwrap(XAI.Model(rawValue: "grok-imagine-video"))
        let geminiModel = try XCTUnwrap(Gemini.Model(rawValue: "gemini-3-flash"))
        let client = makeClient()
        let settings = try ChatGenerationSettings(maxOutputTokens: 1_024, temperature: 0.5)

        for model in [Model.xAI(xAIModel), .gemini(geminiModel)] {
            let object = try encodedRequest(client.request(
                messages: testMessages,
                model: model,
                generationSettings: settings
            ))
            XCTAssertEqual(object["max_tokens"] as? Int, 1_024)
            XCTAssertEqual(object["temperature"] as? Double, 0.5)
            XCTAssertNil(object["max_completion_tokens"])
        }

        let unsupported = try encodedRequest(client.request(
            messages: testMessages,
            model: .xAI(unsupportedXAIModel),
            generationSettings: settings
        ))
        XCTAssertNil(unsupported["max_tokens"])
        XCTAssertNil(unsupported["max_completion_tokens"])
        XCTAssertNil(unsupported["temperature"])
    }

    func testXAIUsesAppGuardAndGeminiUsesDocumentedBoundary() throws {
        let xAIModel = try XCTUnwrap(XAI.Model(rawValue: "grok-3"))
        let geminiModel = try XCTUnwrap(Gemini.Model(rawValue: "gemini-3-flash-preview"))
        let client = makeClient()

        let xAI = try encodedRequest(client.request(
            messages: testMessages,
            model: .xAI(xAIModel),
            generationSettings: try ChatGenerationSettings(maxOutputTokens: 1_000_000, temperature: 0.55)
        ))
        XCTAssertEqual(xAI["max_tokens"] as? Int, 1_000_000)
        XCTAssertEqual(xAI["temperature"] as? Double, 0.55)

        for (tokens, expected) in [(65_536, 65_536), (65_537, nil)] as [(Int, Int?)] {
            let object = try encodedRequest(client.request(
                messages: testMessages,
                model: .gemini(geminiModel),
                generationSettings: try ChatGenerationSettings(maxOutputTokens: tokens, temperature: 0.55)
            ))
            XCTAssertEqual(object["max_tokens"] as? Int, expected)
            XCTAssertEqual(object["temperature"] as? Double, 0.55)
        }
    }

    func testXAIAndGeminiOverboundTokensAreOmittedWithoutDroppingTemperature() throws {
        let xAIModel = try XCTUnwrap(XAI.Model(rawValue: "grok-3"))
        let geminiModel = try XCTUnwrap(Gemini.Model(rawValue: "gemini-3-flash"))
        let client = makeClient()
        let settings = try ChatGenerationSettings(maxOutputTokens: 8_192, temperature: 0.55)

        let xAI = try encodedRequest(client.request(
            messages: testMessages,
            model: .xAI(xAIModel),
            generationSettings: settings
        ))
        XCTAssertEqual(xAI["max_tokens"] as? Int, 8_192)
        XCTAssertEqual(xAI["temperature"] as? Double, 0.55)

        let gemini = try encodedRequest(client.request(
            messages: testMessages,
            model: .gemini(geminiModel),
            generationSettings: settings
        ))
        XCTAssertNil(gemini["max_tokens"])
        XCTAssertNil(gemini["max_completion_tokens"])
        XCTAssertEqual(gemini["temperature"] as? Double, 0.55)
    }

    func testOllamaOptionsAreOmittedOrTranslated() throws {
        let providerModel = try XCTUnwrap(Ollama.Model(rawValue: "llama3.2"))
        let client = makeClient()
        let automatic = try encodedRequest(client.request(
            messages: testMessages,
            model: .ollama(providerModel),
            generationSettings: .automatic
        ))
        XCTAssertNil(automatic["options"])

        let tokenOnly = try encodedRequest(client.request(
            messages: testMessages,
            model: .ollama(providerModel),
            generationSettings: try ChatGenerationSettings(maxOutputTokens: 4_096)
        ))
        XCTAssertEqual((tokenOnly["options"] as? [String: Any])?["num_predict"] as? Int, 4_096)
        XCTAssertNil((tokenOnly["options"] as? [String: Any])?["temperature"])

        let temperatureOnly = try encodedRequest(client.request(
            messages: testMessages,
            model: .ollama(providerModel),
            generationSettings: try ChatGenerationSettings(temperature: 0.6)
        ))
        let temperatureOptions = try XCTUnwrap(temperatureOnly["options"] as? [String: Any])
        XCTAssertNil(temperatureOptions["num_predict"])
        XCTAssertEqual(temperatureOptions["temperature"] as? Double, 0.6)

        let combined = try encodedRequest(client.request(
            messages: testMessages,
            model: .ollama(providerModel),
            generationSettings: try ChatGenerationSettings(maxOutputTokens: 8_192, temperature: 0)
        ))
        let options = try XCTUnwrap(combined["options"] as? [String: Any])
        XCTAssertEqual(options["num_predict"] as? Int, 8_192)
        XCTAssertEqual(options["temperature"] as? Double, 0)
    }

    func testOllamaAppGuardIsEncodedAndLargerValuesFailValidation() throws {
        let providerModel = try XCTUnwrap(Ollama.Model(rawValue: "llama3.2"))
        let client = makeClient()
        let object = try encodedRequest(client.request(
            messages: testMessages,
            model: .ollama(providerModel),
            generationSettings: try ChatGenerationSettings(maxOutputTokens: 1_000_000, temperature: 0.6)
        ))
        let options = try XCTUnwrap(object["options"] as? [String: Any])

        XCTAssertEqual(options["num_predict"] as? Int, 1_000_000)
        XCTAssertEqual(options["temperature"] as? Double, 0.6)
        XCTAssertThrowsError(try ChatGenerationSettings(maxOutputTokens: 1_000_001, temperature: 0.6))
    }

    func testDirectRequestReadsProviderOnceAndUsesSnapshot() throws {
        let first = try ChatGenerationSettings(maxOutputTokens: 1_024, temperature: 0.2)
        let second = try ChatGenerationSettings(maxOutputTokens: 8_192, temperature: 0.8)
        let provider = CountingGenerationSettingsProvider(settings: first)
        let client = makeClient(provider: { provider.next(replacement: second) })

        let request = client.directRequest(messages: testMessages, model: .openAI(.gpt4o_mini))
        provider.settings = second
        let object = try encodedRequest(request)

        XCTAssertEqual(provider.count, 1)
        XCTAssertEqual(object["max_tokens"] as? Int, 1_024)
        XCTAssertEqual(object["temperature"] as? Double, 0.2)
    }

    func testAccountRoutesDoNotReadGenerationSettingsProvider() async throws {
        let anthropicModel = try XCTUnwrap(Anthropic.Model.allCases.first)
        let counter = CountingGenerationSettingsProvider(settings: try ChatGenerationSettings(maxOutputTokens: 8_192, temperature: 0.7))
        try sessionStore.save(AccountSession(
            provider: .claudeCode,
            accountIdentifier: "claude-user",
            accessToken: "token",
            accessibleModelIDs: [anthropicModel.rawValue]
        ))
        accessManager.refresh()
        let proxy = TestAccountProxyTransport()
        let client = makeClient(proxy: proxy, provider: { counter.next() })

        _ = try await client.performChatCompletionRequest(
            messages: testMessages,
            model: .claudeCode(anthropicModel),
            tools: nil,
            toolChoice: nil
        )
        XCTAssertEqual(counter.count, 0)
        XCTAssertEqual(proxy.lastModel, .claudeCode(anthropicModel))
    }

    func testCodexAccountRouteDoesNotReadGenerationSettingsProvider() async throws {
        let counter = CountingGenerationSettingsProvider(settings: try ChatGenerationSettings(maxOutputTokens: 8_192, temperature: 0.7))
        try sessionStore.save(AccountSession(
            provider: .openAI,
            accountIdentifier: "openai-user",
            accessToken: "token",
            accessibleModelIDs: [OpenAI.Model.gpt5_5.rawValue]
        ))
        accessManager.refresh()
        let bridge = TestOpenAIAccountChatBridge()
        let client = NetworkClient(
            keychainService: keychainService,
            accountLoginService: StubAccountLoginService(),
            accountProxyTransport: TestAccountProxyTransport(),
            openAIAccountChatBridge: bridge,
            providerAccessManager: accessManager,
            generationSettingsProvider: { counter.next() }
        )

        _ = try await client.performChatCompletionRequest(
            messages: testMessages,
            model: .codex(.gpt5_5),
            tools: nil,
            toolChoice: nil
        )
        XCTAssertEqual(counter.count, 0)
        XCTAssertEqual(bridge.lastModel, .codex(.gpt5_5))
    }

    func testAgentContextDoesNotReadGenerationSettingsProvider() throws {
        let providerModel = try XCTUnwrap(Ollama.Model(rawValue: "llama3.2"))
        let counter = CountingGenerationSettingsProvider(settings: try ChatGenerationSettings(maxOutputTokens: 1_024))
        let client = makeClient(provider: { counter.next() })

        _ = try client.agentContext(messages: testMessages, model: .ollama(providerModel), eventHandler: { _ in })

        XCTAssertEqual(counter.count, 0)
    }

    private var testMessages: [Message] {
        [Message(text: "Hello", role: .user)]
    }

    private func makeClient(
        proxy: AccountProxyTransportProtocol = TestAccountProxyTransport(),
        provider: @escaping @Sendable () -> ChatGenerationSettings = { .automatic }
    ) -> NetworkClient {
        NetworkClient(
            keychainService: keychainService,
            accountLoginService: StubAccountLoginService(),
            accountProxyTransport: proxy,
            providerAccessManager: accessManager,
            generationSettingsProvider: provider
        )
    }

    private func encodedRequest(
        _ request: any LangToolsChatRequest & LangToolsStreamableRequest
    ) throws -> [String: Any] {
        let data = try JSONEncoder().encode(request)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private final class CountingGenerationSettingsProvider: @unchecked Sendable {
    var settings: ChatGenerationSettings
    private(set) var count = 0

    init(settings: ChatGenerationSettings) {
        self.settings = settings
    }

    func next(replacement: ChatGenerationSettings? = nil) -> ChatGenerationSettings {
        count += 1
        let current = settings
        if let replacement { settings = replacement }
        return current
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

private actor TestAsyncSignal {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isSignaled = false

    func wait() async {
        if isSignaled { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func signal() {
        isSignaled = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class BlockingLogoutAccountLoginService: AccountLoginService {
    private let started = TestAsyncSignal()
    private let finish = TestAsyncSignal()

    func beginLogin(for provider: AccountLoginProvider) async throws -> AccountSession {
        throw AccountLoginError.sessionExchangeFailed("Unexpected login")
    }

    func handleRedirect(_ url: URL) async throws -> AccountSession {
        throw AccountLoginError.invalidCallbackURL
    }

    func refreshSession(_ session: AccountSession) async throws -> AccountSession { session }

    func logout(provider: AccountLoginProvider) async throws {
        await started.signal()
        await finish.wait()
    }

    func fetchAccessibleModels(for provider: AccountLoginProvider) async throws -> [String] { [] }

    func waitUntilLogoutStarted() async {
        await started.wait()
    }

    func finishLogout() async {
        await finish.signal()
    }
}

@MainActor
private final class TestHelperAccountLoginService: AccountLoginService {
    private(set) var didLogoutHelper = false

    func beginLogin(for provider: AccountLoginProvider) async throws -> AccountSession {
        throw AccountLoginError.sessionExchangeFailed("Unexpected direct login")
    }

    func beginCodexHelperLogin() async throws -> AccountSession {
        AccountSession(
            provider: .openAI,
            accountIdentifier: "helper-user",
            accessToken: "must-not-be-persisted",
            refreshToken: "must-not-be-persisted",
            accessibleModelIDs: ["gpt-5.5"]
        )
    }

    func handleRedirect(_ url: URL) async throws -> AccountSession {
        throw AccountLoginError.invalidCallbackURL
    }

    func refreshSession(_ session: AccountSession) async throws -> AccountSession { session }
    func logout(provider: AccountLoginProvider) async throws {}

    func logoutCodexHelper() async throws {
        didLogoutHelper = true
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
