import Anthropic
import Foundation
import KeychainAccess
import LangTools
import OpenAI
import XCTest
@testable import Chat

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

    func testOpenAIAccountSessionUsesProxyTransport() async throws {
        let session = AccountSession(
            provider: .openAI,
            accountIdentifier: "openai-user",
            accessToken: "access-token",
            accessibleModelIDs: ["gpt-5.5"]
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
            model: .codex(.gpt5_5),
            tools: nil,
            toolChoice: nil
        )

        XCTAssertEqual(message.text, "proxied response")
        XCTAssertEqual(proxyTransport.lastModel, .codex(.gpt5_5))
        XCTAssertEqual(proxyTransport.lastSession?.accountIdentifier, "openai-user")
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

    func testCodexAccountProxyErrorsPropagate() async throws {
        let session = AccountSession(
            provider: .openAI,
            accountIdentifier: "openai-user",
            accessToken: "access-token",
            accessibleModelIDs: ["gpt-5.5"]
        )
        try sessionStore.save(session)
        accessManager.refresh()

        let expectedError = NetworkClient.NetworkError.accountProxyTransportFailed("OpenAI helper failed")
        let client = NetworkClient(
            keychainService: keychainService,
            accountLoginService: StubAccountLoginService(),
            accountProxyTransport: TestAccountProxyTransport(error: expectedError),
            providerAccessManager: accessManager
        )

        do {
            _ = try await client.performChatCompletionRequest(
                messages: [Message(text: "Hello", role: .user)],
                model: .codex(.gpt5_5),
                tools: nil,
                toolChoice: nil
            )
            XCTFail("Expected transport error")
        } catch let error as NetworkClient.NetworkError {
            XCTAssertEqual(error, expectedError)
        }
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

private final class TestAccountProxyTransport: AccountProxyTransportProtocol {
    private(set) var lastSession: AccountSession?
    private(set) var lastModel: Model?
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
}
