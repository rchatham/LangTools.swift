import Foundation
import XCTest
@testable import Chat

final class AccountLoginServiceTests: XCTestCase {
    func testParseRedirectAcceptsValidOpenAICallback() throws {
        let url = URL(string: "langtools-example-auth://auth/callback/openAI?code=test-code&state=test-state")!

        let payload = try BrowserAccountLoginService.parseRedirect(
            url,
            expectedProvider: .openAI,
            expectedState: "test-state"
        )

        XCTAssertEqual(payload.provider, .openAI)
        XCTAssertEqual(payload.code, "test-code")
        XCTAssertEqual(payload.state, "test-state")
    }

    func testParseRedirectRejectsStateMismatch() {
        let url = URL(string: "langtools-example-auth://auth/callback/openAI?code=test-code&state=wrong-state")!

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

    func testBackendClientExchangeDecodesSessionPayload() async throws {
        let session = makeURLSession { request in
            XCTAssertEqual(request.url?.path, "/auth/openai/exchange")
            XCTAssertEqual(request.httpMethod, "POST")

            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = """
            {
              "accountIdentifier": "openai-user",
              "accessToken": "access-token",
              "refreshToken": "refresh-token",
              "expiresAt": null,
              "accessibleModelIDs": ["gpt-5.1-codex"]
            }
            """.data(using: .utf8)!
            return (response, body)
        }

        let client = AccountLoginBackendClient(
            configuration: AccountBackendConfiguration(baseURL: URL(string: "http://localhost:8080")!),
            urlSession: session
        )

        let accountSession = try await client.exchange(
            provider: .openAI,
            payload: AuthRedirectPayload(provider: .openAI, code: "code", state: "state")
        )

        XCTAssertEqual(accountSession.provider, .openAI)
        XCTAssertEqual(accountSession.accountIdentifier, "openai-user")
        XCTAssertEqual(accountSession.accessToken, "access-token")
        XCTAssertEqual(accountSession.accessibleModelIDs, ["gpt-5.1-codex"])
    }

    @MainActor
    func testBeginLoginReturnsSessionAfterBrowserCallback() async throws {
        let coordinator = TestAccountLoginCoordinator()
        let backendClient = TestAccountLoginBackendClient(
            exchangeSession: AccountSession(
                provider: .openAI,
                accountIdentifier: "openai-user",
                accessToken: "access-token",
                accessibleModelIDs: ["gpt-5.1-codex"]
            )
        )

        let service = BrowserAccountLoginService(
            coordinator: coordinator,
            backendClient: backendClient,
            sessionStore: AuthSessionStore(keychain: .init(service: "AccountLoginServiceTests.\(UUID().uuidString)")),
            configuration: AccountBackendConfiguration(baseURL: URL(string: "http://localhost:8080")!)
        )

        let session = try await service.beginLogin(for: .openAI)

        XCTAssertEqual(session.accountIdentifier, "openai-user")
        XCTAssertEqual(backendClient.lastExchangePayload?.code, "test-code")
        XCTAssertEqual(backendClient.lastLoginProvider, .openAI)
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
    private(set) var lastLoginProvider: AccountLoginProvider?

    init(exchangeSession: AccountSession) {
        self.exchangeSession = exchangeSession
    }

    func loginStartURL(for provider: AccountLoginProvider, state: String) -> URL {
        lastLoginProvider = provider
        return URL(string: "http://localhost:8080/auth/\(provider.startPathComponent)/start?state=\(state)")!
    }

    func exchange(provider: AccountLoginProvider, payload: AuthRedirectPayload) async throws -> AccountSession {
        lastLoginProvider = provider
        lastExchangePayload = payload
        return exchangeSession
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
