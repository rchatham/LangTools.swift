import Foundation
import XCTest
import HelperLink
@testable import HelperCore

final class MobileProviderTests: XCTestCase {
    private let chatBody = #"{"provider":"openAI","model":"codex-test","messages":[{"role":"user","content":"hello"}],"stream":true}"#

    func testClaudeOriginRejectsSSRFAndAmbiguousOrigins() throws {
        for text in ["http://127.0.0.1:8080", "http://[::1]:8080/"] {
            XCTAssertEqual(try MobileClaudeRelay.validatedOrigin(URL(string: text)!).absoluteString, text)
        }
        for text in ["https://127.0.0.1:8080", "http://localhost:8080", "http://127.0.0.2:8080",
                     "http://192.168.1.1:8080", "http://example.com:8080", "http://127.0.0.1",
                     "http://127.0.0.1:0", "http://127.0.0.1:8080/path", "http://127.0.0.1:8080?",
                     "http://127.0.0.1:8080#", "http://user@127.0.0.1:8080", "http://user:pass@127.0.0.1:8080",
                     "http://127.1:8080", "http://2130706433:8080", "http://[::ffff:127.0.0.1]:8080"] {
            XCTAssertThrowsError(try MobileClaudeRelay.validatedOrigin(URL(string: text)!), text)
        }
    }

    func testOptionalConfigurationFailsClosedAndIsImmutableWhileListening() async throws {
        let harness = try await MobileHarness()
        defer { harness.stop() }
        for values in [["claude", "ollama"], ["codex", "ollama"], ["unknown"]] {
            do {
                try await harness.server.configure(capabilities: values)
                XCTFail("Invalid or live configuration accepted: \(values)")
            } catch { /* Expected fixed failure, never fallback to another provider. */ }
        }
        let pair = try await harness.pair()
        XCTAssertEqual(pair.capabilities, ["ollama"])
        for path in ["/v1/models/codex", "/v1/account/status", "/v1/claude/models"] {
            let response = try await harness.request(path, token: pair.token)
            XCTAssertEqual(response.0, 401, path)
        }
    }

    func testOldOllamaGrantsStayUnchangedAcrossNewServerScopes() async throws {
        let fixture = try await MobileUpstreamFixture()
        defer { fixture.stop() }
        let runtime = try MobileCodexFixture()
        defer { runtime.stop() }
        let scope = ["claude", "codex", "ollama"]
        let harness = try await MobileHarness(upstream: fixture.origin, capabilities: scope,
            claudeBackendURL: fixture.origin, accountRoutes: AccountRouteHandlers(runtime: runtime.runtime), seedOllamaDevice: true)
        defer { harness.stop() }
        let old = try XCTUnwrap(harness.oldPair)
        for path in ["/v1/models/codex", "/v1/account/status", "/v1/claude/models"] {
            let denied = try await harness.request(path, token: old.token, accountToken: "account-secret")
            XCTAssertEqual(denied.0, 401, path)
        }
        let health = try await harness.request("/v1/mobile/health", token: old.token)
        XCTAssertEqual(try JSONDecoder().decode(MobileHelperHealthResponse.self, from: health.1).capabilities, ["ollama"])
        let ollama = try await harness.request("/v1/ollama/api/tags", token: old.token)
        XCTAssertEqual(ollama.0, 200)
        let upgraded = try await harness.pair()
        XCTAssertEqual(upgraded.capabilities, scope)
        let granted = await harness.store.authenticate(old.token)
        XCTAssertEqual(granted?.capabilities, ["ollama"])
        let models = try await harness.request("/v1/models/codex", token: upgraded.token)
        XCTAssertEqual(models.0, 200)
        XCTAssertEqual(try JSONDecoder().decode(HelperModelsResponse.self, from: models.1).models, ["codex-test"])
        await runtime.runtime.shutdown()
    }

    func testPairingScopeChangeInvalidatesCodeWithoutChangingSavedGrants() async throws {
        let harness = try await MobileHarness()
        defer { harness.stop() }
        let old = try await harness.pair()
        let code = try await harness.store.generatePairingCode()
        try await harness.store.setPairingCapabilities(["codex", "ollama"])
        do {
            _ = try await harness.store.redeem(.init(code: code.code, name: "New Phone"))
            XCTFail("Scope change did not invalidate outstanding code")
        } catch { /* Old QR cannot mint a broader grant. */ }
        let oldDevice = await harness.store.authenticate(old.token)
        XCTAssertEqual(oldDevice?.capabilities, ["ollama"])
        let mismatchCode = try await harness.store.generatePairingCode()
        do {
            _ = try await harness.store.redeem(.init(code: mismatchCode.code, name: "New Phone"), capabilities: ["ollama"])
            XCTFail("Server/store scope mismatch accepted")
        } catch { /* Immutable server scope cannot be broadened by changing its store. */ }
        let independentlyGranted = try await harness.store.redeem(.init(code: mismatchCode.code, name: "Privileged Phone"))
        XCTAssertEqual(independentlyGranted.capabilities, ["codex", "ollama"])
        let serverDenied = try await harness.request("/v1/models/codex", token: independentlyGranted.token)
        XCTAssertEqual(serverDenied.0, 401, "A device grant alone cannot enable a disabled server capability")
    }

    func testCodexModelsStatusChatCleanupAndNoAdminRoutesUseInjectedActor() async throws {
        let fixture = try MobileCodexFixture()
        defer { fixture.stop() }
        let harness = try await MobileHarness(capabilities: ["codex", "ollama"], accountRoutes: AccountRouteHandlers(runtime: fixture.runtime))
        defer { harness.stop() }
        let pair = try await harness.pair()
        let noToken = try await harness.request("/v1/models/codex")
        XCTAssertEqual(noToken.0, 401)
        XCTAssertFalse(fixture.logExists)
        let models = try await harness.request("/v1/models/codex", token: pair.token)
        XCTAssertEqual(models.0, 200)
        XCTAssertEqual(try JSONDecoder().decode(HelperModelsResponse.self, from: models.1).models, ["codex-test"])
        let status = try await harness.request("/v1/account/status", token: pair.token)
        XCTAssertEqual(status.0, 200)
        XCTAssertFalse(try JSONDecoder().decode(HelperAuthStatusResponse.self, from: status.1).authenticated)
        for path in ["/v1/auth/login", "/v1/auth/logout", "/v1/auth/status", "/auth/claude-code/start", "/v1/pairing/exchange"] {
            let response = try await harness.request(path, method: "POST", token: pair.token, body: "{}")
            XCTAssertEqual(response.0, 404, path)
        }
        let id = UUID()
        let body = chatBody.dropLast() + ",\"conversationID\":\"\(id.uuidString)\"}"
        let stream = try await harness.request("/v1/account/chat/completions", method: "POST", token: pair.token, body: String(body))
        XCTAssertEqual(stream.0, 200)
        let events = try stream.1.split(separator: 10).map { try JSONDecoder().decode(HelperChatStreamEvent.self, from: Data($0)) }
        XCTAssertEqual(events, [.delta("first"), .complete("first")])
        let fixed = try await harness.request("/v1/account/chat/completions", method: "POST", token: pair.token,
            body: chatBody.replacingOccurrences(of: "true", with: "false"))
        XCTAssertEqual(fixed.0, 200)
        XCTAssertEqual(try JSONDecoder().decode(HelperChatResponse.self, from: fixed.1).content, "first")
        let cleaned = try await harness.request("/v1/account/conversations/\(id.uuidString)", method: "DELETE", token: pair.token)
        XCTAssertEqual(cleaned.0, 204)
        XCTAssertTrue(cleaned.1.isEmpty)
        let invalid = try await harness.request("/v1/account/conversations/not-a-uuid", method: "DELETE", token: pair.token)
        XCTAssertEqual(invalid.0, 404)
        let malformed = try await harness.request("/v1/account/chat/completions", method: "POST", token: pair.token, body: "{}")
        XCTAssertEqual(malformed.0, 400)
        let securityFields = try await harness.request("/v1/account/chat/completions", method: "POST", token: pair.token,
            body: chatBody.dropLast() + ",\"sandbox\":\"danger-full-access\"}")
        XCTAssertEqual(securityFields.0, 400)
        XCTAssertFalse(fixture.methods.contains(where: { $0.contains("login") || $0.contains("logout") }))
        await fixture.runtime.shutdown()
    }

    func testCodexQuietStreamRevocationJoinsActorBeforeReleasingSlot() async throws {
        let fixture = try MobileCodexFixture(quiet: true)
        defer { fixture.stop() }
        let harness = try await MobileHarness(capabilities: ["codex", "ollama"], accountRoutes: AccountRouteHandlers(runtime: fixture.runtime))
        defer { harness.stop() }
        let pair = try await harness.pair()
        let client = harness.client()
        defer { client.invalidateAndCancel() }
        var request = URLRequest(url: harness.url("/v1/account/chat/completions"))
        request.httpMethod = "POST"; request.httpBody = Data(chatBody.utf8)
        request.setValue("Bearer \(pair.token)", forHTTPHeaderField: "Authorization")
        let (bytes, response) = try await client.bytes(for: request, delegate: MobileTestPin(fingerprint: harness.identity.fingerprint))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        var lines = bytes.lines.makeAsyncIterator()
        let first = try await lines.next()
        XCTAssertEqual(first, "{\"delta\":\"first\",\"type\":\"delta\"}")
        try await harness.server.revokeDevice(pair.deviceID)
        try await fixture.waitForInterrupt()
        // Fake Codex holds the interrupt acknowledgement: revocation closes TLS promptly,
        // but actor cleanup must keep its slot until the acknowledgement is allowed.
        XCTAssertEqual(harness.server.activeConnectionCount, 1)
        fixture.releaseInterrupt()
        try await waitForSlotRelease(harness)
        do {
            let next = try await lines.next()
            XCTAssertNil(next, "No fabricated completion/error event after device revocation")
        } catch { /* TLS interruption can be EOF or an error. */ }
        XCTAssertEqual(harness.server.activeConnectionCount, 0)
        await fixture.runtime.shutdown()
    }

    func testCodexResponseBoundsAbortWithoutTerminalOrSuccessfulCompletion() async throws {
        let fixture = try MobileCodexFixture(quiet: true, delta: String(repeating: "x", count: 512))
        defer { fixture.stop() }
        let limits = MobileOllamaServer.ResponseByteLimits(jsonBytes: 16, streamBytes: 64)
        let harness = try await MobileHarness(responseByteLimits: limits, capabilities: ["codex", "ollama"],
            accountRoutes: AccountRouteHandlers(runtime: fixture.runtime))
        defer { harness.stop() }
        let pair = try await harness.pair()
        let models = try await harness.request("/v1/models/codex", token: pair.token)
        XCTAssertEqual(models.0, 503)
        let connection = try await mobileRawPinnedConnection(harness)
        defer { connection.cancel() }
        let read = Task { await mobileBoundaryRawResponse(connection) }
        try await mobileRawSend(connection, rawChat(harness, pair: pair))
        try await fixture.waitForInterrupt()
        fixture.releaseInterrupt()
        let wire = await read.value
        XCTAssertFalse(wire.timedOut)
        let text = String(decoding: wire.data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 "))
        XCTAssertFalse(text.contains("\"type\":\"complete\""))
        XCTAssertFalse(wire.data.suffix(5) == Data("0\r\n\r\n".utf8))
        try await waitForSlotRelease(harness)
        await fixture.runtime.shutdown()
    }

    func testClaudeHeaderSeparationExactPathsAndNoFallback() async throws {
        let fixture = try await MobileUpstreamFixture()
        defer { fixture.stop() }
        let harness = try await MobileHarness(capabilities: ["claude", "ollama"], claudeBackendURL: fixture.origin)
        defer { harness.stop() }
        let pair = try await harness.pair()
        let unauthenticated = try await harness.request("/v1/claude/models", accountToken: "account-secret")
        XCTAssertEqual(unauthenticated.0, 401)
        let missing = try await harness.request("/v1/claude/models", token: pair.token)
        XCTAssertEqual(missing.0, 401)
        let duplicateDevice = try await harness.request("/v1/claude/models", token: pair.token, accountToken: pair.token)
        XCTAssertEqual(duplicateDevice.0, 401)
        let otherDevice = try await harness.pair()
        let smuggledDevice = try await harness.request("/v1/claude/models", token: pair.token, accountToken: otherDevice.token)
        XCTAssertEqual(smuggledDevice.0, 401)
        XCTAssertEqual(fixture.requestCount, 0)
        let models = try await harness.request("/v1/claude/models", token: pair.token, accountToken: "account-secret")
        XCTAssertEqual(models.0, 200)
        XCTAssertEqual(fixture.lastPath, "/auth/claude-code/models")
        XCTAssertEqual(fixture.lastAuthorization, "account-secret")
        XCTAssertNil(fixture.receivedHeaders["x-langtools-account-token"])
        XCTAssertFalse(fixture.receivedHeaders.values.contains(where: { $0.contains(pair.token) }))
        let chat = try await harness.request("/v1/claude/chat/completions", method: "POST", token: pair.token,
            body: "{}", accountToken: "separate-account-secret")
        XCTAssertEqual(chat.0, 200)
        XCTAssertEqual(fixture.lastPath, "/account/chat/completions")
        XCTAssertEqual(fixture.lastAuthorization, "separate-account-secret")
        XCTAssertNil(fixture.receivedHeaders["x-langtools-account-token"])
        fixture.stop()
        let unavailable = try await harness.request("/v1/claude/models", token: pair.token, accountToken: "account-secret")
        XCTAssertEqual(unavailable.0, 503, "Selected Claude transport must not fall back to Codex or Ollama")
    }

    func testClaudeRedirectAndUpstreamErrorsCannotLeakAccountOrDeviceTokens() async throws {
        for mode in [MobileUpstreamFixture.ClaudeMode.redirect, .error] {
            let fixture = try await MobileUpstreamFixture(claudeMode: mode)
            defer { fixture.stop() }
            let harness = try await MobileHarness(capabilities: ["claude", "ollama"], claudeBackendURL: fixture.origin)
            defer { harness.stop() }
            let pair = try await harness.pair()
            let response = try await harness.request("/v1/claude/models", token: pair.token, accountToken: "account-secret-do-not-echo")
            XCTAssertEqual(response.0, 503)
            XCTAssertEqual(fixture.requestCount, 1, "Redirect must not create any second request")
            let text = String(decoding: response.1, as: UTF8.self)
            XCTAssertFalse(text.contains("account-secret"))
            XCTAssertFalse(text.contains(pair.token))
            XCTAssertFalse(text.contains("echoed-secret"))
            XCTAssertEqual(text, "{\"error\":\"The helper could not complete this request.\"}")
        }
    }

    func testClaudeHTTP200ErrorsAndNDJSONErrorsAreSanitized() async throws {
        for mode in [MobileUpstreamFixture.ClaudeMode.successErrorBody, .errorEvent, .escapedSuccess] {
            let fixture = try await MobileUpstreamFixture(claudeMode: mode)
            defer { fixture.stop() }
            let harness = try await MobileHarness(capabilities: ["claude", "ollama"], claudeBackendURL: fixture.origin)
            defer { harness.stop() }
            let pair = try await harness.pair()
            let response = try await harness.request("/v1/claude/chat/completions", method: "POST", token: pair.token,
                body: "{}", accountToken: "account-secret-do-not-echo")
            let text = String(decoding: response.1, as: UTF8.self)
            XCTAssertFalse(text.contains("account-secret"))
            XCTAssertFalse(text.contains(pair.token))
            XCTAssertFalse(text.contains("echoed-secret"))
            if mode == .errorEvent {
                XCTAssertEqual(response.0, 200)
                let event = try JSONDecoder().decode(HelperChatStreamEvent.self, from: response.1)
                XCTAssertEqual(event, .failure("The helper could not complete this request."))
            } else {
                XCTAssertEqual(response.0, 503)
            }
        }
    }

    func testClaudeSanitizerRejectsEscapedCredentialsInNestedSuccessValues() throws {
        for payload in [#"{"choices":[{"message":{"content":"\u0061ccount-secret"}}]}"#,
                        #"{"nested":{"\u0061ccount-secret":"value"}}"#,
                        #"{"nested":["device-\u0073ecret"]}"#] {
            XCTAssertThrowsError(try MobileClaudeRelay.sanitizedJSON(Data(payload.utf8),
                accountToken: "account-secret", deviceToken: "device-secret", event: false))
        }
    }

    func testClaudeQuietStreamRevocationCancelsUpstreamWithoutCompletion() async throws {
        let fixture = try await MobileUpstreamFixture(claudeMode: .quiet)
        defer { fixture.stop() }
        let harness = try await MobileHarness(capabilities: ["claude", "ollama"], claudeBackendURL: fixture.origin)
        defer { harness.stop() }
        let pair = try await harness.pair()
        let client = harness.client()
        defer { client.invalidateAndCancel() }
        var request = URLRequest(url: harness.url("/v1/claude/chat/completions"))
        request.httpMethod = "POST"; request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(pair.token)", forHTTPHeaderField: "Authorization")
        request.setValue("account-secret", forHTTPHeaderField: "X-LangTools-Account-Token")
        let (bytes, _) = try await client.bytes(for: request, delegate: MobileTestPin(fingerprint: harness.identity.fingerprint))
        var lines = bytes.lines.makeAsyncIterator()
        let first = try await lines.next()
        XCTAssertEqual(first, "{\"type\":\"delta\",\"delta\":\"first\"}")
        try await harness.server.revokeDevice(pair.deviceID)
        await fixture.waitForDisconnect()
        XCTAssertTrue(fixture.quietDisconnected)
        do { let next = try await lines.next(); XCTAssertNil(next) }
        catch { /* Expected transport interruption, never a manufactured terminal event. */ }
        try await waitForSlotRelease(harness)
    }

    func testClaudeAggregateLimitCancelsOpenUpstreamWithoutTerminal() async throws {
        let fixture = try await MobileUpstreamFixture(claudeMode: .oversized)
        defer { fixture.stop() }
        let harness = try await MobileHarness(responseByteLimits: .init(jsonBytes: 32, streamBytes: 64),
            capabilities: ["claude", "ollama"], claudeBackendURL: fixture.origin)
        defer { harness.stop() }
        let pair = try await harness.pair()
        let connection = try await mobileRawPinnedConnection(harness)
        defer { connection.cancel() }
        let read = Task { await mobileBoundaryRawResponse(connection) }
        let request = "POST /v1/claude/chat/completions HTTP/1.1\r\nHost: \(harness.host):\(harness.port)\r\nAuthorization: Bearer \(pair.token)\r\nX-LangTools-Account-Token: account-secret\r\nContent-Length: 2\r\n\r\n{}"
        try await mobileRawSend(connection, Data(request.utf8))
        await fixture.waitForDisconnect()
        XCTAssertTrue(fixture.quietDisconnected)
        let wire = await read.value
        XCTAssertFalse(wire.timedOut)
        XCTAssertFalse(wire.data.suffix(5) == Data("0\r\n\r\n".utf8))
        XCTAssertFalse(String(decoding: wire.data, as: UTF8.self).contains("\"complete\""))
        try await waitForSlotRelease(harness)
    }

    func testAccountRequestBoundsRejectBeforeUpstream() async throws {
        let fixture = try MobileCodexFixture()
        defer { fixture.stop() }
        let harness = try await MobileHarness(capabilities: ["codex", "ollama"], accountRoutes: .init(runtime: fixture.runtime))
        defer { harness.stop() }
        let pair = try await harness.pair()
        let connection = try await mobileRawPinnedConnection(harness)
        defer { connection.cancel() }
        let read = Task { await mobileBoundaryRawResponse(connection) }
        let request = "POST /v1/account/chat/completions HTTP/1.1\r\nHost: \(harness.host):\(harness.port)\r\nAuthorization: Bearer \(pair.token)\r\nContent-Length: \(LocalHelperServer.maximumBodyBytes + 1)\r\n\r\n"
        try await mobileRawSend(connection, Data(request.utf8))
        let response = await read.value
        XCTAssertTrue(String(decoding: response.data, as: UTF8.self).hasPrefix("HTTP/1.1 413 "))
        XCTAssertFalse(fixture.logExists)
        await fixture.runtime.shutdown()
    }

    private func rawChat(_ harness: MobileHarness, pair: MobileHelperPairingResponse) -> Data {
        Data("POST /v1/account/chat/completions HTTP/1.1\r\nHost: \(harness.host):\(harness.port)\r\nAuthorization: Bearer \(pair.token)\r\nContent-Length: \(chatBody.utf8.count)\r\n\r\n\(chatBody)".utf8)
    }

    private func waitForSlotRelease(_ harness: MobileHarness) async throws {
        for _ in 0..<250 {
            if harness.server.activeConnectionCount == 0 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Actor/relay cleanup did not release its active slot")
    }
}

/// Real in-process runtime + fake app-server protocol; no installed account or interactive login dependency.
private final class MobileCodexFixture: @unchecked Sendable {
    let runtime: CodexRuntimeService
    private let directory: URL
    private let log: URL
    var logExists: Bool { FileManager.default.fileExists(atPath: log.path) }
    var methods: [String] {
        guard let data = try? Data(contentsOf: log) else { return [] }
        return data.split(separator: 10).compactMap { line in
            ((try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any])?["method"] as? String
        }
    }
    init(quiet: Bool = false, delta: String = "first") throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("mobile-provider-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        log = directory.appendingPathComponent("requests.jsonl")
        let script = directory.appendingPathComponent("fake.py")
        try Data(Self.server.utf8).write(to: script)
        let environment = ProcessInfo.processInfo.environment.merging([
            "MOBILE_TEST_ROOT": directory.path, "QUIET": quiet ? "1" : "0", "DELTA": delta
        ]) { _, value in value }
        let client = CodexAppServerClient(commandResolver: {
            ResolvedCodexCommand(executable: "/usr/bin/python3", arguments: ["-u", script.path])
        }, environment: environment, defaultTimeout: .seconds(5), containmentMode: .disabledForTesting)
        runtime = CodexRuntimeService(client: client, browserOpener: { _ in XCTFail("LAN must not log in") },
            turnCompletionTimeout: .seconds(10), workspaces: CodexConversationWorkspace(cacheRoot: directory.appendingPathComponent("cache")))
    }
    func stop() {
        releaseInterrupt()
        let runtime = self.runtime
        Task { await runtime.shutdown() }
    }
    func releaseInterrupt() { FileManager.default.createFile(atPath: directory.appendingPathComponent("release-interrupt").path, contents: Data()) }
    func waitForInterrupt() async throws {
        for _ in 0..<250 {
            if methods.contains("turn/interrupt") { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Revocation did not interrupt the real Codex actor's quiet turn")
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
    private static let server = #"""
import json, os, sys, time
root = os.environ["MOBILE_TEST_ROOT"]
def write(value):
    print(json.dumps(value, separators=(",", ":")), flush=True)
thread = 0
for line in sys.stdin:
    request = json.loads(line)
    method = request["method"]
    with open(root + "/requests.jsonl", "a") as log:
        log.write(json.dumps(request) + "\n")
    if method == "initialize":
        write({"id":request["id"], "result":{"userAgent":"fake", "codexHome":"/tmp", "platformFamily":"unix", "platformOs":"macos"}})
    elif method == "initialized":
        continue
    elif method == "model/list":
        write({"id":request["id"], "result":{"data":[{"id":"codex-test", "model":"codex-test", "displayName":"Test", "description":"Fixture", "hidden":False, "isDefault":True}], "nextCursor":None}})
    elif method == "account/read":
        assert request["params"]["refreshToken"] == False
        write({"id":request["id"], "result":{"account":None, "requiresOpenaiAuth":True}})
    elif method == "thread/start":
        thread += 1
        write({"id":request["id"], "result":{"thread":{"id":"thread-" + str(thread)}, "model":"codex-test", "modelProvider":"openai"}})
    elif method == "turn/start":
        thread_id = request["params"]["threadId"]
        write({"id":request["id"], "result":{"turn":{"id":"turn-" + str(thread)}}})
        write({"method":"item/agentMessage/delta", "params":{"threadId":thread_id, "turnId":"turn-" + str(thread), "itemId":"agent", "delta":os.environ["DELTA"]}})
        if os.environ["QUIET"] != "1":
            write({"method":"turn/completed", "params":{"threadId":thread_id, "turn":{"id":"turn-" + str(thread), "status":"completed", "error":None}}})
    elif method == "turn/interrupt":
        deadline = time.monotonic() + 5
        while not os.path.exists(root + "/release-interrupt") and time.monotonic() < deadline:
            time.sleep(0.01)
        write({"id":request["id"], "result":{}})
    else:
        write({"id":request["id"], "error":{"code":-32601, "message":"unexpected " + method}})
"""#
}
