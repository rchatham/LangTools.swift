import Foundation
import XCTest
@testable import Chat

final class CodexHelperClientTests: XCTestCase {
    override func tearDown() {
        MockCodexHelperURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testStatusUsesConfiguredHelperURLAndToken() async throws {
        let session = makeURLSession { request in
            XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:9999/v1/auth/status")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer helper-token")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = """
            {
              "provider": "openAI",
              "authenticated": true,
              "accountIdentifier": "acct",
              "expiresAt": null,
              "accessibleModelIDs": ["gpt-5.5", "gpt-5.3-codex-spark"]
            }
            """.data(using: .utf8)!
            return (response, body)
        }

        let client = CodexHelperClient(
            configuration: AccountBackendConfiguration(
                baseURL: URL(string: "http://localhost:8080")!,
                codexHelperBaseURL: URL(string: "http://127.0.0.1:9999")!,
                codexHelperToken: "helper-token"
            ),
            urlSession: session
        )

        let status = try await client.statusOpenAI()
        XCTAssertTrue(status.authenticated)
        XCTAssertEqual(status.accessibleModelIDs, ["gpt-5.5", "gpt-5.3-codex-spark"])
    }

    func testLoginDecodesAccountSession() async throws {
        let session = makeURLSession { request in
            XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:9999/v1/auth/login")
            XCTAssertEqual(request.httpMethod, "POST")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = """
            {
              "id": "00000000-0000-0000-0000-000000000001",
              "provider": "openAI",
              "accountIdentifier": "acct",
              "accessToken": "token",
              "refreshToken": null,
              "idToken": null,
              "tokenType": "Bearer",
              "expiresAt": null,
              "accessibleModelIDs": ["gpt-5.5", "gpt-5.3-codex-spark"],
              "createdAt": "2026-04-28T16:00:00Z"
            }
            """.data(using: .utf8)!
            return (response, body)
        }

        let client = CodexHelperClient(
            configuration: AccountBackendConfiguration(
                baseURL: URL(string: "http://localhost:8080")!,
                codexHelperBaseURL: URL(string: "http://127.0.0.1:9999")!,
                codexHelperToken: "helper-token"
            ),
            urlSession: session
        )

        let accountSession = try await client.loginOpenAI()
        XCTAssertEqual(accountSession.provider, .openAI)
        XCTAssertEqual(accountSession.accountIdentifier, "acct")
    }

    func testUnauthorizedStatusReturnsHelpfulError() async {
        let session = makeURLSession { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data("unauthorized".utf8))
        }

        let client = CodexHelperClient(
            configuration: AccountBackendConfiguration(
                baseURL: URL(string: "http://localhost:8080")!,
                codexHelperBaseURL: URL(string: "http://127.0.0.1:9999")!,
                codexHelperToken: "wrong-token"
            ),
            urlSession: session
        )

        do {
            _ = try await client.statusOpenAI()
            XCTFail("Expected unauthorized error")
        } catch let error as AccountLoginError {
            XCTAssertEqual(error, .sessionExchangeFailed("Codex helper rejected the request. Check the helper token in Settings."))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeURLSession(handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> URLSession {
        MockCodexHelperURLProtocol.requestHandler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockCodexHelperURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class MockCodexHelperURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

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
