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

    func testServeOptionsRejectInvalidPort() {
        XCTAssertThrowsError(try ServeOptions(arguments: ["--port", "not-a-port"]))
        XCTAssertThrowsError(try ServeOptions(arguments: ["--port", "0"]))
        XCTAssertThrowsError(try ServeOptions(arguments: ["--port", "70000"]))
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

        let malformed = Data(#"{"provider":"openAI","model":"gpt","messages":[{"role":"user","content":"hi"}],"stream":false,"conversationID":"not-a-uuid"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(HelperChatRequest.self, from: malformed))

        let additiveLegacy = Data(#"{"provider":"openAI","model":"gpt","messages":[{"role":"user","content":"hi"}],"stream":false,"tools":[{"name":"ignored"}],"toolChoice":"auto","futureMetadata":{"value":1}}"#.utf8)
        let decoded = try JSONDecoder().decode(HelperChatRequest.self, from: additiveLegacy)
        XCTAssertEqual(decoded.model, "gpt")

        let securityFields = [
            "cwd", "current-working-directory", "sandbox", "sandboxPolicy",
            "permissions", "approval_policy", "networkAccess", "writableRoots",
            "workspaceRoots", "runtimeWorkspaceRoots", "selectedCapabilityRoots",
            "dynamicTools", "config", "developerInstructions", "baseInstructions",
            "environment", "environments", "multiAgentMode", "modelProvider",
            "ephemeral", "personality", "collaborationMode"
        ]
        for field in securityFields {
            let object: [String: Any] = [
                "provider": "openAI", "model": "gpt", "messages": [["role": "user", "content": "hi"]],
                "stream": false, field: field == "networkAccess" ? false : "/tmp"
            ]
            let data = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(try JSONDecoder().decode(HelperChatRequest.self, from: data), "Expected rejection for \(field)")
        }
    }

    func testCleanupPathRequiresOneUUIDAndIsIdempotentlyAddressable() {
        let id = UUID()
        XCTAssertEqual(
            LocalHelperServer.conversationID(fromCleanupPath: "/v1/account/conversations/\(id.uuidString)"),
            id
        )
        XCTAssertNil(LocalHelperServer.conversationID(fromCleanupPath: "/v1/account/conversations/not-a-uuid"))
        XCTAssertNil(LocalHelperServer.conversationID(fromCleanupPath: "/v1/account/conversations/\(id)/extra"))
    }

    func testHTTPErrorMappingCoversWireStatuses() {
        XCTAssertEqual(LocalHelperServer.httpStatus(for: CodexRuntimeError.badRequest("bad")), "400 Bad Request")
        XCTAssertEqual(LocalHelperServer.httpStatus(for: CancellationError()), "400 Bad Request")
        XCTAssertEqual(LocalHelperServer.httpStatus(for: CodexRuntimeError.authentication("auth")), "401 Unauthorized")
        XCTAssertEqual(LocalHelperServer.httpStatus(for: CodexRuntimeError.accountConflict("conflict")), "409 Conflict")
        XCTAssertEqual(LocalHelperServer.httpStatus(for: CodexAppServerError.timeout("request")), "504 Gateway Timeout")
        XCTAssertEqual(LocalHelperServer.httpStatus(for: CodexRuntimeError.timeout("turn")), "504 Gateway Timeout")
        XCTAssertEqual(LocalHelperServer.httpStatus(for: CodexRuntimeError.runtime("failed")), "500 Internal Server Error")
    }
}
