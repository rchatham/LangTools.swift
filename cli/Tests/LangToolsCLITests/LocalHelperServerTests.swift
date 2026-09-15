#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import XCTest
@testable import CLI

final class LocalHelperServerTests: XCTestCase {
    func testParserWaitsForCompleteBodyAndAcceptsFragmentedRequest() throws {
        let head = requestHead(method: "POST", contentLength: 11)
        assertIncomplete(HTTPRequest.parse(from: Data((head + "hello").utf8)))

        let request = try unwrapRequest(HTTPRequest.parse(from: Data((head + "hello world").utf8)))
        XCTAssertEqual(request.path, "/v1/account/chat/completions")
        XCTAssertEqual(request.authorizationBearerToken, "token")
        XCTAssertEqual(String(data: request.body, encoding: .utf8), "hello world")
    }

    func testParserUsesSeparateHeaderAndBodyLimits() throws {
        XCTAssertEqual(LocalHelperServer.maximumHeaderBytes, 32 * 1_024)
        XCTAssertEqual(LocalHelperServer.maximumBodyBytes, 4 * 1_048_576)

        let body = String(repeating: "a", count: 1_500_000)
        let request = try unwrapRequest(HTTPRequest.parse(from: Data((requestHead(contentLength: body.utf8.count) + body).utf8)))
        XCTAssertEqual(request.body.count, body.utf8.count)

        assertFailure(
            HTTPRequest.parse(from: Data(String(repeating: "x", count: LocalHelperServer.maximumHeaderBytes + 1).utf8)),
            status: .requestHeaderFieldsTooLarge
        )
        assertFailure(
            HTTPRequest.parse(from: Data(requestHead(contentLength: LocalHelperServer.maximumBodyBytes + 1).utf8)),
            status: .payloadTooLarge
        )
    }

    func testParserRejectsMalformedAndAmbiguousFraming() {
        let malformed = [
            "GET /health HTTP/1.0\r\nHost: localhost\r\n\r\n",
            "GET  /health HTTP/1.1\r\nHost: localhost\r\n\r\n",
            "GET /health HTTP/1.1\r\nHost localhost\r\n\r\n",
            "GET /health HTTP/1.1\r\n folded: value\r\nHost: localhost\r\n\r\n",
            "GET /health HTTP/1.1\r\nBad Header: value\r\nHost: localhost\r\n\r\n",
            "GET /health HTTP/1.1\r\n\r\n"
        ]
        for raw in malformed {
            assertFailure(HTTPRequest.parse(from: Data(raw.utf8)), status: .badRequest)
        }

        assertFailure(
            HTTPRequest.parse(from: Data("POST /x HTTP/1.1\r\nHost: localhost\r\nContent-Length: nope\r\n\r\n".utf8)),
            status: .badRequest
        )
        assertFailure(
            HTTPRequest.parse(from: Data("POST /x HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n".utf8)),
            status: .badRequest
        )
        assertFailure(
            HTTPRequest.parse(from: Data("POST /x HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)),
            status: .badRequest
        )
        assertFailure(
            HTTPRequest.parse(from: Data("POST /x HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)),
            status: .lengthRequired
        )
        assertFailure(
            HTTPRequest.parse(from: Data("GET /health HTTP/1.1\r\nHost: localhost\r\n\r\nGET /health HTTP/1.1\r\n\r\n".utf8)),
            status: .badRequest
        )
    }

    func testChunkedNDJSONFramingIsOrderedByteCorrectAndTerminated() throws {
        let delta = HelperChatStreamEvent.delta("Hello 👋")
        let complete = HelperChatStreamEvent.complete("Hello 👋 world")
        let error = HelperChatStreamEvent.failure("safe failure")
        let deltaChunk = try HTTPResponseEncoder.ndjsonChunk(delta)
        let completeChunk = try HTTPResponseEncoder.ndjsonChunk(complete)
        let errorChunk = try HTTPResponseEncoder.ndjsonChunk(error)
        let header = HTTPResponseEncoder.chunkedHeader(status: .ok)
        let headerText = String(decoding: header, as: UTF8.self)

        let deltaPayload = try chunkPayload(deltaChunk)
        XCTAssertEqual(try JSONDecoder().decode(HelperChatStreamEvent.self, from: deltaPayload.dropLast()), delta)
        XCTAssertEqual(deltaPayload.last, UInt8(ascii: "\n"))
        XCTAssertTrue(headerText.contains("Transfer-Encoding: chunked\r\n"))
        XCTAssertFalse(headerText.lowercased().contains("content-length"))

        let successfulStream = header + deltaChunk + completeChunk + HTTPResponseEncoder.terminalChunk
        XCTAssertEqual(successfulStream, header + deltaChunk + completeChunk + Data("0\r\n\r\n".utf8))
        let failedStream = header + deltaChunk + errorChunk + HTTPResponseEncoder.terminalChunk
        XCTAssertEqual(failedStream, header + deltaChunk + errorChunk + Data("0\r\n\r\n".utf8))
        XCTAssertEqual(try JSONDecoder().decode(HelperChatStreamEvent.self, from: chunkPayload(completeChunk).dropLast()), complete)
        XCTAssertEqual(try JSONDecoder().decode(HelperChatStreamEvent.self, from: chunkPayload(errorChunk).dropLast()), error)
    }

    func testConnectionLimiterAndDeadlineAreOneShot() {
        XCTAssertEqual(LocalHelperServer.maximumConcurrentConnections, 32)
        XCTAssertEqual(LocalHelperServer.requestReadTimeout, .seconds(10))
        XCTAssertEqual(HTTPStatus.requestTimeout.rawValue, "408 Request Timeout")

        let limiter = HelperConnectionLimiter(limit: 2)
        let first = limiter.acquire()
        let second = limiter.acquire()
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertNil(limiter.acquire())
        XCTAssertEqual(limiter.activeCount, 2)
        first?.release()
        first?.release()
        XCTAssertEqual(limiter.activeCount, 1)
        let replacement = limiter.acquire()
        XCTAssertNotNil(replacement)
        second?.release()
        replacement?.release()
        XCTAssertEqual(limiter.activeCount, 0)

        let fireCount = LockedCounter()
        let fired = HelperRequestDeadline { fireCount.increment() }
        fired.fire()
        fired.fire()
        XCTAssertEqual(fireCount.value, 1)
        let cancelled = HelperRequestDeadline { fireCount.increment() }
        cancelled.cancel()
        cancelled.fire()
        XCTAssertEqual(fireCount.value, 1)
    }

    func testBearerTokenComparisonHandlesEqualAndUnequalInputs() {
        XCTAssertTrue(SecureTokenComparison.matches(expected: "secret-👋", provided: "secret-👋"))
        XCTAssertFalse(SecureTokenComparison.matches(expected: "secret-one", provided: "secret-two"))
        XCTAssertFalse(SecureTokenComparison.matches(expected: "short", provided: "longer"))
        XCTAssertFalse(SecureTokenComparison.matches(expected: "secret", provided: nil))
    }

    func testStandaloneChatResponseIsExactlyOneAggregateJSONLine() throws {
        let output = try OpenAIAccountChatCommand.responseData(content: "first\nsecond 👋")
        XCTAssertEqual(output.last, UInt8(ascii: "\n"))
        XCTAssertEqual(output.filter { $0 == UInt8(ascii: "\n") }.count, 1)
        let decoded = try JSONDecoder().decode(HelperChatResponse.self, from: output.dropLast())
        XCTAssertEqual(decoded.content, "first\nsecond 👋")
    }

    func testServeRequiresTokenFileAndRejectsLegacyOrAmbiguousOptions() throws {
        let options = try ServeOptions(arguments: ["--host", "localhost", "--port", "9999", "--token-file", "/secret"])
        XCTAssertEqual(options.host, "localhost")
        XCTAssertEqual(options.port, 9999)
        XCTAssertEqual(options.tokenFile, "/secret")

        XCTAssertThrowsError(try ServeOptions(arguments: []))
        XCTAssertThrowsError(try ServeOptions(arguments: ["--token", "secret"]))
        XCTAssertThrowsError(try ServeOptions(arguments: ["--token-file", "/a", "--token-file", "/b"]))
        XCTAssertThrowsError(try ServeOptions(arguments: ["--token-file"]))
        XCTAssertThrowsError(try ServeOptions(arguments: ["--unknown", "value", "--token-file", "/a"]))
        XCTAssertThrowsError(try ServeOptions(arguments: ["--port", "0", "--token-file", "/a"]))
    }

    func testTokenLoaderAcceptsOnlySecureBoundedSingleLineRegularFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("langtools-token-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tokenURL = directory.appendingPathComponent("token")

        try Data("secret-value\n".utf8).write(to: tokenURL)
        XCTAssertEqual(chmod(tokenURL.path, 0o600), 0)
        XCTAssertEqual(try HelperTokenLoader.load(from: tokenURL.path), "secret-value")
        try Data("secret-value\r\n".utf8).write(to: tokenURL)
        XCTAssertEqual(try HelperTokenLoader.load(from: tokenURL.path), "secret-value")

        XCTAssertEqual(chmod(tokenURL.path, 0o640), 0)
        XCTAssertThrowsError(try HelperTokenLoader.load(from: tokenURL.path))
        XCTAssertEqual(chmod(tokenURL.path, 0o600), 0)

        let linkURL = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: tokenURL)
        XCTAssertThrowsError(try HelperTokenLoader.load(from: linkURL.path))

        for invalid in [Data(), Data("one\ntwo".utf8), Data("one\rtwo".utf8), Data("one\r".utf8), Data([0x61, 0, 0x62]), Data([0xff])] {
            try invalid.write(to: tokenURL)
            XCTAssertThrowsError(try HelperTokenLoader.load(from: tokenURL.path))
        }
        try Data(repeating: 0x61, count: HelperTokenLoader.maximumTokenBytes + 1).write(to: tokenURL)
        XCTAssertThrowsError(try HelperTokenLoader.load(from: tokenURL.path))
    }

    func testSessionUsesCanonicalOpaqueMarkerWithoutCredentials() throws {
        XCTAssertEqual(CodexRuntimeService.sessionMarker, "langtools-codex-app-server-session-v1")
        let session = StoredAccountSession(
            provider: "openAI",
            accountIdentifier: "person@example.com",
            accessToken: CodexRuntimeService.sessionMarker,
            refreshToken: nil,
            idToken: nil,
            tokenType: nil,
            expiresAt: nil,
            accessibleModelIDs: ["gpt-5.5"],
            createdAt: Date(timeIntervalSince1970: 0),
            id: UUID()
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        XCTAssertEqual(object["accessToken"] as? String, CodexRuntimeService.sessionMarker)
        XCTAssertNil(object["refreshToken"])
        XCTAssertNil(object["idToken"])
    }

    func testChatPayloadConversationIdentityAndUnsupportedPaths() throws {
        let id = UUID()
        let withID = Data(#"{"provider":"openAI","model":"gpt","messages":[{"role":"user","content":"hi"}],"stream":false,"conversationID":"\#(id.uuidString)"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(HelperChatRequest.self, from: withID).conversationID, id)

        let legacy = Data(#"{"provider":"openAI","model":"gpt","messages":[{"role":"user","content":"hi"}],"stream":false}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(HelperChatRequest.self, from: legacy).conversationID)

        let securityFields = [
            "cwd", "current-working-directory", "sandbox", "sandboxPolicy", "permissions",
            "approval_policy", "networkAccess", "writableRoots", "workspaceRoots", "runtimeWorkspaceRoots",
            "selectedCapabilityRoots", "dynamicTools", "config", "developerInstructions", "baseInstructions",
            "environment", "environments", "multiAgentMode", "modelProvider", "ephemeral", "personality",
            "collaborationMode"
        ]
        for field in securityFields {
            let object: [String: Any] = [
                "provider": "openAI", "model": "gpt", "messages": [["role": "user", "content": "hi"]],
                "stream": false, field: field == "networkAccess" ? false : "/tmp"
            ]
            XCTAssertThrowsError(try JSONDecoder().decode(HelperChatRequest.self, from: JSONSerialization.data(withJSONObject: object)))
        }
    }

    func testRoutingDistinguishesNotFoundAndMethodNotAllowed() {
        XCTAssertNil(LocalHelperServer.routeErrorStatus(method: "GET", path: "/health"))
        XCTAssertEqual(LocalHelperServer.routeErrorStatus(method: "POST", path: "/health"), .methodNotAllowed)
        XCTAssertEqual(LocalHelperServer.routeErrorStatus(method: "GET", path: "/unknown"), .notFound)
        XCTAssertNil(LocalHelperServer.routeErrorStatus(method: "DELETE", path: "/v1/account/conversations/id"))
        XCTAssertEqual(
            LocalHelperServer.routeErrorStatus(method: "POST", path: "/v1/account/conversations/id"),
            .methodNotAllowed
        )
    }

    func testCleanupPathRequiresOneUUIDAndHTTPErrorMappingsAreTyped() {
        let id = UUID()
        XCTAssertEqual(LocalHelperServer.conversationID(fromCleanupPath: "/v1/account/conversations/\(id)"), id)
        XCTAssertNil(LocalHelperServer.conversationID(fromCleanupPath: "/v1/account/conversations/not-a-uuid"))
        XCTAssertNil(LocalHelperServer.conversationID(fromCleanupPath: "/v1/account/conversations/\(id)/extra"))

        XCTAssertEqual(LocalHelperServer.httpStatus(for: CodexRuntimeError.badRequest("bad")), .badRequest)
        XCTAssertEqual(LocalHelperServer.httpStatus(for: CancellationError()), .badRequest)
        XCTAssertEqual(LocalHelperServer.httpStatus(for: CodexRuntimeError.authentication("auth")), .unauthorized)
        XCTAssertEqual(LocalHelperServer.httpStatus(for: CodexRuntimeError.accountConflict("conflict")), .conflict)
        XCTAssertEqual(LocalHelperServer.httpStatus(for: CodexRuntimeError.responseTooLarge), .payloadTooLarge)
        XCTAssertEqual(LocalHelperServer.httpStatus(for: CodexAppServerError.timeout("request")), .gatewayTimeout)
        XCTAssertEqual(LocalHelperServer.httpStatus(for: CodexRuntimeError.runtime("failed")), .internalServerError)
    }

    private func chunkPayload(_ framed: Data) throws -> Data {
        let firstCRLF = try XCTUnwrap(framed.range(of: Data("\r\n".utf8)))
        let countText = String(decoding: framed[..<firstCRLF.lowerBound], as: UTF8.self)
        let payload = framed.subdata(in: firstCRLF.upperBound..<(framed.count - 2))
        XCTAssertEqual(Int(countText, radix: 16), payload.count)
        return payload
    }

    private func requestHead(method: String = "POST", contentLength: Int) -> String {
        "\(method) /v1/account/chat/completions HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer token\r\nContent-Length: \(contentLength)\r\n\r\n"
    }

    private func unwrapRequest(_ result: HTTPRequestParseResult) throws -> HTTPRequest {
        guard case .request(let request) = result else {
            XCTFail("Expected parsed request, got \(result)")
            throw TestError.unexpectedResult
        }
        return request
    }

    private func assertIncomplete(_ result: HTTPRequestParseResult, file: StaticString = #filePath, line: UInt = #line) {
        guard case .incomplete = result else { return XCTFail("Expected incomplete request", file: file, line: line) }
    }

    private func assertFailure(
        _ result: HTTPRequestParseResult,
        status: HTTPStatus,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .failure(let actual, _) = result else {
            return XCTFail("Expected parser failure", file: file, line: line)
        }
        XCTAssertEqual(actual, status, file: file, line: line)
    }

    private enum TestError: Error { case unexpectedResult }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int { lock.withLock { storedValue } }

    func increment() {
        lock.withLock { storedValue += 1 }
    }
}
