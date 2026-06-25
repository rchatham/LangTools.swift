import Foundation
import XCTest
@testable import Chat

final class AccountLoginServiceTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testParseRedirectAcceptsValidOpenAILocalhostCallback() throws {
        let url = URL(string: "http://127.0.0.1:1455/auth/callback?code=test-code&state=test-state")!

        let payload = try BrowserAccountLoginService.parseRedirect(
            url,
            expectedProvider: .openAI,
            expectedState: "test-state"
        )

        XCTAssertEqual(payload.provider, .openAI)
        XCTAssertEqual(payload.code, "test-code")
        XCTAssertEqual(payload.state, "test-state")
    }

    func testParseRedirectRejectsOpenAIStateMismatch() {
        let url = URL(string: "http://127.0.0.1:1455/auth/callback?code=test-code&state=wrong-state")!

        XCTAssertThrowsError(
            try BrowserAccountLoginService.parseRedirect(
                url,
                expectedProvider: .openAI,
                expectedState: "expected-state"
            )
        ) { error in
            XCTAssertEqual(error as? AccountLoginError, .stateMismatch)
        }
    }

    func testParseRedirectAcceptsValidClaudeCodeCustomSchemeCallback() throws {
        let url = URL(string: "langtools-example-auth://auth/callback/claudeCode?code=test-code&state=test-state")!

        let payload = try BrowserAccountLoginService.parseRedirect(
            url,
            expectedProvider: .claudeCode,
            expectedState: "test-state"
        )

        XCTAssertEqual(payload.provider, .claudeCode)
        XCTAssertEqual(payload.code, "test-code")
        XCTAssertEqual(payload.state, "test-state")
    }

    func testOpenAILoginStartURLUsesDirectOAuthAuthorizeEndpoint() {
        let client = AccountLoginBackendClient(
            configuration: AccountBackendConfiguration(baseURL: URL(string: "http://localhost:8080")!)
        )

        let url = client.loginStartURL(for: .openAI, state: "test-state", codeChallenge: "test-challenge", redirectURI: "http://127.0.0.1:1455/auth/callback")
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "auth.openai.com")
        XCTAssertEqual(url.path, "/oauth/authorize")
        XCTAssertEqual(queryItems["client_id"], "app_EMoamEEZ73f0CkXaXp7hrann")
        XCTAssertEqual(queryItems["response_type"], "code")
        XCTAssertEqual(queryItems["redirect_uri"], "http://127.0.0.1:1455/auth/callback")
        XCTAssertEqual(queryItems["scope"], "openid openai profile email offline_access")
        XCTAssertEqual(queryItems["code_challenge"], "test-challenge")
        XCTAssertEqual(queryItems["code_challenge_method"], "S256")
        XCTAssertEqual(queryItems["state"], "test-state")
        XCTAssertEqual(queryItems["codex_cli_simplified_flow"], "true")
        XCTAssertEqual(queryItems["id_token_add_organizations"], "true")
    }

    func testOpenAIExchangePostsDirectTokenRequest() async throws {
        let session = makeURLSession { request in
            XCTAssertEqual(request.url?.absoluteString, "https://auth.openai.com/oauth/token")
            XCTAssertEqual(request.httpMethod, "POST")

            let body = try XCTUnwrap(request.bodyData)
            let json = try JSONSerialization.jsonObject(with: body) as? [String: String]
            XCTAssertEqual(json?["grant_type"], "authorization_code")
            XCTAssertEqual(json?["client_id"], "app_EMoamEEZ73f0CkXaXp7hrann")
            XCTAssertEqual(json?["code"], "code")
            XCTAssertEqual(json?["code_verifier"], "verifier")
            XCTAssertEqual(json?["redirect_uri"], "http://127.0.0.1:1455/auth/callback")

            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let responseBody = """
            {
              "access_token": "access-token",
              "refresh_token": "refresh-token",
              "id_token": "id-token",
              "token_type": "Bearer",
              "expires_in": 3600
            }
            """.data(using: .utf8)!
            return (response, responseBody)
        }

        let client = AccountLoginBackendClient(
            configuration: AccountBackendConfiguration(baseURL: URL(string: "http://localhost:8080")!),
            urlSession: session
        )

        let accountSession = try await client.exchange(
            provider: .openAI,
            payload: AuthRedirectPayload(provider: .openAI, code: "code", state: "state"),
            codeVerifier: "verifier",
            redirectURI: "http://127.0.0.1:1455/auth/callback"
        )

        XCTAssertEqual(accountSession.provider, .openAI)
        XCTAssertEqual(accountSession.accountIdentifier, "OpenAI Account")
        XCTAssertEqual(accountSession.accessToken, "access-token")
        XCTAssertEqual(accountSession.refreshToken, "refresh-token")
        XCTAssertEqual(accountSession.idToken, "id-token")
        XCTAssertEqual(accountSession.tokenType, "Bearer")
    }

    func testOpenAIRefreshPostsRefreshGrantRequest() async throws {
        let session = makeURLSession { request in
            XCTAssertEqual(request.url?.absoluteString, "https://auth.openai.com/oauth/token")
            XCTAssertEqual(request.httpMethod, "POST")

            let body = try XCTUnwrap(request.bodyData)
            let json = try JSONSerialization.jsonObject(with: body) as? [String: String]
            XCTAssertEqual(json?["grant_type"], "refresh_token")
            XCTAssertEqual(json?["client_id"], "app_EMoamEEZ73f0CkXaXp7hrann")
            XCTAssertEqual(json?["refresh_token"], "refresh-token")

            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let responseBody = """
            {
              "access_token": "new-access-token",
              "refresh_token": "new-refresh-token",
              "token_type": "Bearer",
              "expires_in": 7200
            }
            """.data(using: .utf8)!
            return (response, responseBody)
        }

        let client = AccountLoginBackendClient(
            configuration: AccountBackendConfiguration(baseURL: URL(string: "http://localhost:8080")!),
            urlSession: session
        )

        let refreshedSession = try await client.refresh(
            session: AccountSession(
                provider: .openAI,
                accountIdentifier: "OpenAI Account",
                accessToken: "old-access-token",
                refreshToken: "refresh-token",
                idToken: "old-id-token",
                tokenType: "Bearer"
            )
        )

        XCTAssertEqual(refreshedSession.accessToken, "new-access-token")
        XCTAssertEqual(refreshedSession.refreshToken, "new-refresh-token")
        XCTAssertEqual(refreshedSession.tokenType, "Bearer")
        XCTAssertEqual(refreshedSession.idToken, "old-id-token")
    }

    func testCLIAccountSessionBridgeExportsOpenAISession() async throws {
        let runner = TestCommandRunner(results: [
            CommandResult(status: 0, stdout: """
            {
              "provider": "openAI",
              "accountIdentifier": "chatgpt-account",
              "accessToken": "access-token",
              "refreshToken": "refresh-token",
              "idToken": "id-token",
              "tokenType": "Bearer",
              "expiresAt": "2026-04-28T17:00:00Z",
              "accessibleModelIDs": ["gpt-5.1-codex"],
              "createdAt": "2026-04-28T16:00:00Z",
              "id": "00000000-0000-0000-0000-000000000001"
            }
            """, stderr: "")
        ])
        let bridge = CLIAccountSessionBridge(runner: runner)

        let session = try await bridge.exportOpenAISession()

        XCTAssertEqual(session.provider, .openAI)
        XCTAssertEqual(session.accountIdentifier, "chatgpt-account")
        XCTAssertEqual(session.accessToken, "access-token")
    }

    @MainActor
    func testBeginLoginUsesCLIBridgeForOpenAI() async throws {
        let bridge = CLIAccountSessionBridge(runner: TestCommandRunner(results: [
            CommandResult(status: 0, stdout: "Logged in\n", stderr: ""),
            CommandResult(status: 0, stdout: """
            {
              "provider": "openAI",
              "accountIdentifier": "chatgpt-account",
              "accessToken": "access-token",
              "refreshToken": "refresh-token",
              "idToken": null,
              "tokenType": "Bearer",
              "expiresAt": null,
              "accessibleModelIDs": [],
              "createdAt": "2026-04-28T16:00:00Z",
              "id": "00000000-0000-0000-0000-000000000001"
            }
            """, stderr: "")
        ]))
        let service = BrowserAccountLoginService(
            coordinator: TestAccountLoginCoordinator(),
            backendClient: TestAccountLoginBackendClient(
                exchangeSession: AccountSession(provider: .claudeCode, accountIdentifier: "unused", accessToken: "unused")
            ),
            sessionStore: AuthSessionStore(keychain: .init(service: "AccountLoginServiceTests.\(UUID().uuidString)")),
            configuration: AccountBackendConfiguration(baseURL: URL(string: "http://localhost:8080")!),
            cliBridge: bridge
        )

        let session = try await service.beginLogin(for: .openAI)

        XCTAssertEqual(session.provider, .openAI)
        XCTAssertEqual(session.accountIdentifier, "chatgpt-account")
    }

    @MainActor
    func testBeginLoginReturnsSessionAfterBrowserCallbackForClaudeCode() async throws {
        let coordinator = TestAccountLoginCoordinator()
        let backendClient = TestAccountLoginBackendClient(
            exchangeSession: AccountSession(
                provider: .claudeCode,
                accountIdentifier: "claude-user",
                accessToken: "access-token",
                accessibleModelIDs: ["claude-model"]
            )
        )

        let service = BrowserAccountLoginService(
            coordinator: coordinator,
            backendClient: backendClient,
            sessionStore: AuthSessionStore(keychain: .init(service: "AccountLoginServiceTests.\(UUID().uuidString)")),
            configuration: AccountBackendConfiguration(baseURL: URL(string: "http://localhost:8080")!)
        )

        let session = try await service.beginLogin(for: .claudeCode)

        XCTAssertEqual(session.accountIdentifier, "claude-user")
        XCTAssertEqual(backendClient.lastExchangePayload?.code, "test-code")
        XCTAssertEqual(backendClient.lastLoginProvider, .claudeCode)
        XCTAssertNil(backendClient.lastExchangeCodeVerifier)
        XCTAssertNil(backendClient.lastCodeChallenge)
    }

    private func makeURLSession(handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> URLSession {
        MockURLProtocol.requestHandler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class TestAccountLoginCoordinator: AccountLoginCoordinating {
    let callbackURL: URL?

    init(callbackURL: URL? = nil) {
        self.callbackURL = callbackURL
    }

    func startLogin(at url: URL, callbackScheme: String, provider: AccountLoginProvider) async throws -> URL {
        _ = callbackScheme
        if let callbackURL {
            return callbackURL
        }

        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "state" })?
            .value ?? ""
        return URL(string: "langtools-example-auth://auth/callback/\(provider.rawValue)?code=test-code&state=\(state)")!
    }

    func handleRedirect(_ url: URL) {
        _ = url
    }
}

private final class TestAccountLoginBackendClient: AccountLoginBackendClientProtocol {
    let exchangeSession: AccountSession
    private(set) var lastExchangePayload: AuthRedirectPayload?
    private(set) var lastExchangeCodeVerifier: String?
    private(set) var lastLoginProvider: AccountLoginProvider?
    private(set) var lastCodeChallenge: String?

    init(exchangeSession: AccountSession) {
        self.exchangeSession = exchangeSession
    }

    func loginStartURL(for provider: AccountLoginProvider, state: String, codeChallenge: String?, redirectURI: String?) -> URL {
        lastLoginProvider = provider
        lastCodeChallenge = codeChallenge
        if provider == .openAI {
            return URL(string: "https://auth.openai.com/oauth/authorize?state=\(state)&redirect_uri=\(redirectURI ?? "")")!
        }
        return URL(string: "http://localhost:8080/auth/\(provider.startPathComponent)/start?state=\(state)")!
    }

    func exchange(provider: AccountLoginProvider, payload: AuthRedirectPayload, codeVerifier: String?, redirectURI: String?) async throws -> AccountSession {
        _ = redirectURI
        lastLoginProvider = provider
        lastExchangePayload = payload
        lastExchangeCodeVerifier = codeVerifier
        return exchangeSession
    }

    func refresh(session: AccountSession) async throws -> AccountSession {
        session
    }

    func logout(provider: AccountLoginProvider, session: AccountSession?) async throws {
        _ = provider
        _ = session
    }

    func fetchAccessibleModels(for provider: AccountLoginProvider, session: AccountSession?) async throws -> [String] {
        _ = provider
        _ = session
        return exchangeSession.accessibleModelIDs
    }
}

private extension URLRequest {
    var bodyData: Data? {
        if let httpBody {
            return httpBody
        }

        guard let stream = httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var data = Data()
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }

        return data.isEmpty ? nil : data
    }
}

private final class TestCommandRunner: CommandRunning {
    private var results: [CommandResult]

    init(results: [CommandResult]) {
        self.results = results
    }

    func run(executable: String, arguments: [String]) async throws -> CommandResult {
        _ = executable
        _ = arguments
        return results.removeFirst()
    }
}

private final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
