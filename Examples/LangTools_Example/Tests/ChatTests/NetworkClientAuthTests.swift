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

    func testAccountSessionUsesProxyTransport() async throws {
        let session = AccountSession(
            provider: .openAI,
            accountIdentifier: "openai-user",
            accessToken: "access-token",
            accessibleModelIDs: ["gpt-5.1-codex"]
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
            model: .openAI(.gpt51_codex),
            tools: nil,
            toolChoice: nil
        )

        XCTAssertEqual(message.text, "proxied response")
        XCTAssertEqual(proxyTransport.lastSession?.accountIdentifier, "openai-user")
        XCTAssertEqual(proxyTransport.lastModel?.rawValue, "gpt-5.1-codex")
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
}

private final class TestAccountProxyTransport: AccountProxyTransportProtocol {
    private(set) var lastSession: AccountSession?
    private(set) var lastModel: Model?

    func performChatCompletionRequest(messages: [Message], model: Model, session: AccountSession, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?) async throws -> Message {
        _ = messages
        _ = tools
        _ = toolChoice
        lastSession = session
        lastModel = model
        return Message(text: "proxied response", role: .assistant)
    }

    func streamChatCompletionRequest(messages: [Message], model: Model, session: AccountSession, stream: Bool, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?) throws -> AsyncThrowingStream<String, Error> {
        _ = messages
        _ = stream
        _ = tools
        _ = toolChoice
        lastSession = session
        lastModel = model
        return AsyncThrowingStream { continuation in
            continuation.yield("proxied response")
            continuation.finish()
        }
    }
}
