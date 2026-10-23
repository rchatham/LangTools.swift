//
//  OpenAICompatibleHeaderTests.swift
//  OpenAICompatibleProvidersTests
//

import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LangTools
import OpenAICompatible

/// A minimal provider with configurable extra headers.
private final class HeaderProvider: OpenAICompatibleProvider {
    typealias Model = OpenAICompatibleModel<HeaderProvider>
    typealias ErrorResponse = OpenAICompatibleErrorResponse
    static let providerID = LangToolsProviderID(rawValue: "test.headers")
    static let displayName = "Header Provider"
    static let defaultBaseURL = URL(string: "https://example.invalid/v1/")!
    static let apiKeyEnvironmentVariable = "HEADER_PROVIDER_API_KEY"

    let openAI: OpenAI
    let additionalHeaders: [String: String]

    init(headers: [String: String]) {
        openAI = Self.makeClient(baseURL: Self.defaultBaseURL, apiKey: "k", session: .shared, logger: nil)
        additionalHeaders = headers
    }
}

final class OpenAICompatibleHeaderTests: XCTestCase {
    private func request() -> OpenAI.ChatCompletionRequest {
        OpenAI.ChatCompletionRequest(model: "m" as HeaderProvider.Model, messages: [.init(role: .user, content: "Hi")])
    }

    private func assertInvalidArgument(_ expression: @autoclosure () throws -> Any, containing fragment: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard case LangToolsError.invalidArgument(let message) = error else {
                return XCTFail("Expected invalidArgument, got \(error)", file: file, line: line)
            }
            XCTAssertTrue(message.contains(fragment), "\(message) should mention \(fragment)", file: file, line: line)
        }
    }

    func testAdditionalHeadersAreSentAlongsideAuthorization() throws {
        let urlRequest = try HeaderProvider(headers: ["HTTP-Referer": "https://example.com", "X-Title": "LangTools"]).prepare(request: request())

        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "HTTP-Referer"), "https://example.com")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "X-Title"), "LangTools")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer k")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(urlRequest.url?.absoluteString, "https://example.invalid/v1/chat/completions")
    }

    func testReservedHeadersAreRejectedCaseInsensitively() {
        for name in ["authorization", "AUTHORIZATION", "Content-Length", "x-api-key", "Transfer-Encoding", "Host"] {
            assertInvalidArgument(try HeaderProvider(headers: [name: "value"]).prepare(request: request()), containing: name)
        }
    }

    func testHeaderValuesWithControlCharactersAreRejected() throws {
        for value in ["LangTools\r\nX-Injected: 1", "LangTools\nX-Injected: 1", "Lang\u{0}Tools", "Lang\u{7F}Tools"] {
            assertInvalidArgument(try HeaderProvider(headers: ["X-Title": value]).prepare(request: request()), containing: "control character")
        }
        XCTAssertEqual(try HeaderProvider(headers: ["X-Title": "Lang\tTools"]).prepare(request: request()).value(forHTTPHeaderField: "X-Title"), "Lang\tTools")
    }

    func testHeaderNamesMustBeTokens() {
        for name in ["X-Title\r\nX-Injected", "X Title", "X-Title:", "", "Tïtle"] {
            assertInvalidArgument(try HeaderProvider(headers: [name: "value"]).prepare(request: request()), containing: "not a valid header name")
        }
        XCTAssertNoThrow(try HeaderProvider(headers: ["X-Title": "ok", "HTTP-Referer": "https://example.com"]).prepare(request: request()))
    }
}
