import XCTest
@testable import LangToolsCLI

final class LocalHelperServerTests: XCTestCase {
    func testParserWaitsForCompleteBody() {
        let head = "POST /v1/account/chat/completions HTTP/1.1\r\nAuthorization: Bearer token\r\nContent-Length: 11\r\n\r\n"
        XCTAssertNil(HTTPRequest.parseComplete(from: Data((head + "hello").utf8)))

        let request = HTTPRequest.parseComplete(from: Data((head + "hello world").utf8))
        XCTAssertEqual(request?.path, "/v1/account/chat/completions")
        XCTAssertEqual(request?.authorizationBearerToken, "token")
        XCTAssertEqual(String(data: request?.body ?? Data(), encoding: .utf8), "hello world")
    }

    func testParserAcceptsLargeBodyWithinLimit() {
        let body = String(repeating: "a", count: 1_500_000)
        let head = "POST /v1/account/chat/completions HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n"
        let request = HTTPRequest.parseComplete(from: Data((head + body).utf8))
        XCTAssertEqual(request?.body.count, body.utf8.count)
    }

    func testRequestLimitIsBounded() {
        XCTAssertEqual(LocalHelperServer.maximumRequestBytes, 4 * 1_048_576)
    }
}
