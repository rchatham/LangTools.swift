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

    func testOpenAILoginStartURLUsesDirectOAuthAuthorizeEndpoint() throws {
        let client = AccountLoginBackendClient(
            configuration: AccountBackendConfiguration(baseURL: URL(string: "http://localhost:8080")!)
        )

        let url = try client.loginStartURL(for: .openAI, state: "test-state", codeChallenge: "test-challenge", redirectURI: "http://127.0.0.1:1455/auth/callback")
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

    @MainActor
    func testBeginLoginUsesCodexHelperForOpenAI() async throws {
        let helperClient = TestCodexHelperClient(
            loginSession: AccountSession(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                provider: .openAI,
                accountIdentifier: "chatgpt-account",
                accessToken: CodexSessionMarker.value,
                refreshToken: nil,
                idToken: nil,
                tokenType: nil,
                expiresAt: nil,
                accessibleModelIDs: [],
                createdAt: Date(timeIntervalSince1970: 0)
            )
        )
        let service = BrowserAccountLoginService(
            coordinator: TestAccountLoginCoordinator(),
            backendClient: TestAccountLoginBackendClient(
                exchangeSession: AccountSession(provider: .claudeCode, accountIdentifier: "unused", accessToken: "unused")
            ),
            sessionStore: AuthSessionStore(keychain: .init(service: "AccountLoginServiceTests.\(UUID().uuidString)")),
            configuration: AccountBackendConfiguration(baseURL: URL(string: "http://localhost:8080")!),
            codexHelperClient: helperClient
        )

        let session = try await service.beginLogin(for: .openAI)

        XCTAssertEqual(session.provider, .openAI)
        XCTAssertEqual(session.accountIdentifier, "chatgpt-account")
        XCTAssertEqual(helperClient.loginCallCount, 1)
    }

    @MainActor
    func testOpenAIReconnectPreservesLocalIdentityAndAdoptsCanonicalHelperData() async throws {
        let localID = UUID()
        let localCreatedAt = Date(timeIntervalSince1970: 123)
        let sessionStore = AuthSessionStore(keychain: .init(service: "AccountLoginServiceTests.\(UUID().uuidString)"))
        try sessionStore.save(AccountSession(
            id: localID,
            provider: .openAI,
            accountIdentifier: "old-account",
            accessToken: CodexSessionMarker.value,
            accessibleModelIDs: ["old-model"],
            createdAt: localCreatedAt
        ))
        let helperClient = TestCodexHelperClient(loginSession: AccountSession(
            provider: .openAI,
            accountIdentifier: "new-account",
            accessToken: "unsafe-access",
            refreshToken: "unsafe-refresh",
            idToken: "unsafe-id",
            tokenType: "Bearer",
            expiresAt: Date(),
            accessibleModelIDs: [" gpt-5.5 ", "gpt-5.5"]
        ))
        let service = BrowserAccountLoginService(
            coordinator: TestAccountLoginCoordinator(),
            sessionStore: sessionStore,
            codexHelperClient: helperClient
        )

        let session = try await service.beginLogin(for: .openAI)

        XCTAssertEqual(session.id, localID)
        XCTAssertEqual(session.createdAt, localCreatedAt)
        XCTAssertEqual(session.accountIdentifier, "new-account")
        XCTAssertEqual(session.accessibleModelIDs, ["gpt-5.5"])
        XCTAssertEqual(session.accessToken, CodexSessionMarker.value)
        XCTAssertNil(session.refreshToken)
        XCTAssertNil(session.idToken)
        XCTAssertNil(session.tokenType)
        XCTAssertNil(session.expiresAt)
    }

    @MainActor
    func testOpenAIRefreshReconcilesStatusWithoutModelFallback() async throws {
        let originalID = UUID()
        let createdAt = Date(timeIntervalSince1970: 123)
        let helperClient = TestCodexHelperClient(
            loginSession: AccountSession(
                provider: .openAI,
                accountIdentifier: "helper-account",
                accessToken: "unsafe-helper-token",
                refreshToken: "unsafe-refresh",
                idToken: "unsafe-id",
                tokenType: "Bearer",
                expiresAt: Date(timeIntervalSince1970: 999),
                accessibleModelIDs: [" gpt-5.5 ", "gpt-5.5", "codex/future-model"]
            )
        )
        let service = BrowserAccountLoginService(
            coordinator: TestAccountLoginCoordinator(),
            sessionStore: AuthSessionStore(keychain: .init(service: "AccountLoginServiceTests.\(UUID().uuidString)")),
            codexHelperClient: helperClient
        )
        let stale = AccountSession(
            id: originalID,
            provider: .openAI,
            accountIdentifier: "stale-account",
            accessToken: "legacy-access",
            refreshToken: "legacy-refresh",
            idToken: "legacy-id",
            tokenType: "Bearer",
            expiresAt: Date(),
            accessibleModelIDs: ["stale-model"],
            createdAt: createdAt
        )

        let refreshed = try await service.refreshSession(stale)

        XCTAssertEqual(refreshed.id, originalID)
        XCTAssertEqual(refreshed.createdAt, createdAt)
        XCTAssertEqual(refreshed.accountIdentifier, "helper-account")
        XCTAssertEqual(refreshed.accessToken, CodexSessionMarker.value)
        XCTAssertNil(refreshed.refreshToken)
        XCTAssertNil(refreshed.idToken)
        XCTAssertNil(refreshed.tokenType)
        XCTAssertNil(refreshed.expiresAt)
        XCTAssertEqual(refreshed.accessibleModelIDs, ["gpt-5.5", "future-model"])
        XCTAssertEqual(helperClient.listCallCount, 0)
    }

    @MainActor
    func testOpenAIRefreshRejectsUnauthenticatedStatusWithStaleModels() async {
        let helperClient = TestCodexHelperClient(
            loginSession: AccountSession(provider: .openAI, accountIdentifier: "acct", accessToken: CodexSessionMarker.value),
            authenticated: false
        )
        let service = BrowserAccountLoginService(
            coordinator: TestAccountLoginCoordinator(),
            sessionStore: AuthSessionStore(keychain: .init(service: "AccountLoginServiceTests.\(UUID().uuidString)")),
            codexHelperClient: helperClient
        )

        do {
            _ = try await service.refreshSession(AccountSession(
                provider: .openAI,
                accountIdentifier: "stale",
                accessToken: CodexSessionMarker.value,
                accessibleModelIDs: ["stale-model"]
            ))
            XCTFail("Expected unauthenticated status to be rejected")
        } catch let error as AccountLoginError {
            XCTAssertEqual(error, .missingStoredSession(.openAI))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(helperClient.listCallCount, 0)
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

private final class TestCodexHelperClient: CodexHelperClientProtocol {
    let loginSession: AccountSession
    let authenticated: Bool
    private(set) var loginCallCount = 0
    private(set) var listCallCount = 0

    init(loginSession: AccountSession, authenticated: Bool = true) {
        self.loginSession = loginSession
        self.authenticated = authenticated
    }

    func loginOpenAI() async throws -> AccountSession {
        loginCallCount += 1
        return loginSession
    }

    func logoutOpenAI() async throws {}

    func statusOpenAI() async throws -> CodexHelperStatus {
        CodexHelperStatus(provider: "openAI", authenticated: authenticated, accountIdentifier: loginSession.accountIdentifier, expiresAt: nil, accessibleModelIDs: loginSession.accessibleModelIDs)
    }

    func listOpenAIModels() async throws -> [String] {
        listCallCount += 1
        return loginSession.accessibleModelIDs
    }

    func healthCheck() async throws -> HelperHealthStatus {
        HelperHealthStatus(status: "ok", version: 1)
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
