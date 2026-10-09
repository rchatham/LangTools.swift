import XCTest
import Foundation
import Security
import Network
import HelperLink
@testable import HelperCore

final class MobileHelperTests: XCTestCase {
    func testTLSIdentityPersistsAndPinRejectsMismatch() async throws {
        let service = "langtools.tests.identity.\(UUID().uuidString)"
        defer { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary) }
        let identity = try MobileTLSIdentity.loadOrCreate(service: service)
        let again = try MobileTLSIdentity.loadOrCreate(service: service)
        XCTAssertEqual(identity.helperID, again.helperID)
        XCTAssertEqual(identity.fingerprint, again.fingerprint)
        let harness = try await MobileHarness(identity: identity)
        defer { harness.stop() }
        let response = try await harness.request("/v1/mobile/health")
        XCTAssertEqual(response.0, 401, "Exact pinned certificate completes real TLS before HTTP auth.")
        let wrong = harness.client(fingerprint: String(repeating: "0", count: 64))
        defer { wrong.invalidateAndCancel() }
        do {
            _ = try await wrong.data(for: URLRequest(url: harness.url("/v1/mobile/health")))
            XCTFail("Wrong pin must fail TLS, not return an HTTP response.")
        } catch { XCTAssertTrue(error is URLError) }
    }

    func testCodesAreSingleUseExpiringCancellableAndTokensPersistOnlyAsHashes() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("devices.json")
        let clock = MobileTestClock()
        let identity = UUID().uuidString
        let store = try MobileDeviceStore(helperID: identity, fileURL: url, now: { clock.now })
        let first = try await store.generatePairingCode()
        await store.cancelPairing()
        await assertAsyncThrows { _ = try await store.redeem(.init(code: first.code, name: "Phone")) }
        let expired = try await store.generatePairingCode()
        clock.advance(301)
        await assertAsyncThrows { _ = try await store.redeem(.init(code: expired.code, name: "Phone")) }
        let code = try await store.generatePairingCode()
        await assertAsyncThrows { _ = try await store.redeem(.init(code: code.code, name: "\ninvalid")) }
        let pair = try await store.redeem(.init(code: code.code, name: "Phone"))
        await assertAsyncThrows { _ = try await store.redeem(.init(code: code.code, name: "Phone")) }
        XCTAssertEqual(pair.capabilities, ["ollama"])
        let storedData = try Data(contentsOf: url)
        XCTAssertFalse(String(decoding: storedData, as: UTF8.self).contains(pair.token))
        XCTAssertFalse(String(decoding: storedData, as: UTF8.self).contains(code.code))
        let reload = try MobileDeviceStore(helperID: identity, fileURL: url)
        let authenticated = await reload.authenticate(pair.token)
        XCTAssertEqual(authenticated?.id, pair.deviceID)
        let invalid = await reload.authenticate(String(repeating: "0", count: 64))
        XCTAssertNil(invalid)
        try await reload.revoke(pair.deviceID)
        let revoked = await reload.authenticate(pair.token)
        XCTAssertNil(revoked)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testStoreRejectsInvalidCapabilitySetsAndMintsTheEnabledSet() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("devices.json")
        let identity = UUID().uuidString
        for invalid in [[String](), ["ollama", "ollama"], ["ollama", "claude"], ["ollama", "account"]] {
            XCTAssertThrowsError(try MobileDeviceStore(helperID: identity, capabilities: invalid, fileURL: url), "\(invalid)")
        }
        let enabled = ["claude", "codex", "ollama"]
        let store = try MobileDeviceStore(helperID: identity, capabilities: enabled, fileURL: url)
        let storeCapabilities = await store.capabilities
        XCTAssertEqual(storeCapabilities, enabled)
        let code = try await store.generatePairingCode()
        let pair = try await store.redeem(.init(code: code.code, name: "Phone"))
        XCTAssertEqual(pair.capabilities, enabled)
        let authenticated = await store.authenticate(pair.token)
        XCTAssertEqual(authenticated?.id, pair.deviceID)
        XCTAssertEqual(authenticated?.capabilities, enabled)
        // Reload applies the same validity rule, not equality with the enabled set:
        // persisted devices keep the capabilities they were granted.
        let reload = try MobileDeviceStore(helperID: identity, fileURL: url)
        let reloadCapabilities = await reload.capabilities
        XCTAssertEqual(reloadCapabilities, ["ollama"])
        let restored = await reload.authenticate(pair.token)
        XCTAssertEqual(restored?.capabilities, enabled)
        // A persisted invalid set is rejected at load instead of silently accepted.
        let data = try Data(contentsOf: url)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var devices = try XCTUnwrap(object["devices"] as? [[String: Any]])
        devices[0]["capabilities"] = ["ollama", "account"]
        object["devices"] = devices
        try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        XCTAssertThrowsError(try MobileDeviceStore(helperID: identity, fileURL: url))
    }

    func testPrivateListenerAuthExactAllowlistAndNoTokenForwarding() async throws {
        let fixture = try await MobileUpstreamFixture()
        defer { fixture.stop() }
        let harness = try await MobileHarness(upstream: fixture.origin)
        defer { harness.stop() }
        let pair = try await harness.pair()
        let unauthenticated = try await harness.request("/v1/mobile/health")
        XCTAssertEqual(unauthenticated.0, 401)
        let health = try await harness.request("/v1/mobile/health", token: pair.token)
        XCTAssertEqual(health.0, 200)
        XCTAssertEqual(try JSONDecoder().decode(MobileHelperHealthResponse.self, from: health.1).helperID, pair.helperID)
        for route in ["/v1/auth/login", "/v1/auth/logout",
                      "/v1/ollama/api/delete", "/v1/ollama/api/tags/../chat", "/v1/ollama/api/tags?upstream=evil"] {
            let response = try await harness.request(route, token: pair.token)
            XCTAssertTrue([400, 404].contains(response.0), route)
        }
        let disabledCodex = try await harness.request("/v1/models/codex", token: pair.token)
        XCTAssertEqual(disabledCodex.0, 401, "Optional providers fail closed by default.")
        let disabledChat = try await harness.request("/v1/account/chat/completions", method: "POST", token: pair.token, body: "{}")
        XCTAssertEqual(disabledChat.0, 401)
        let wrongMethod = try await harness.request("/v1/ollama/api/tags", method: "POST", token: pair.token, body: "{}")
        XCTAssertEqual(wrongMethod.0, 405)
        let tags = try await harness.request("/v1/ollama/api/tags", token: pair.token)
        XCTAssertEqual(tags.0, 200)
        XCTAssertEqual(String(decoding: tags.1, as: UTF8.self), "{\"models\":[]}")
        XCTAssertNil(fixture.lastAuthorization)
        XCTAssertEqual(fixture.lastPath, "/api/tags")
        let chat = try await harness.request("/v1/ollama/api/chat", method: "POST", token: pair.token, body: #"{"model":"local","stream":false}"#)
        XCTAssertEqual(chat.0, 200)
        XCTAssertEqual(String(decoding: chat.1, as: UTF8.self), "{\"message\":{\"content\":\"hello\"}}")
        try await harness.server.revokeDevice(pair.deviceID)
        let revoked = try await harness.request("/v1/ollama/api/tags", token: pair.token)
        XCTAssertEqual(revoked.0, 401)
    }

    func testNDJSONArrivesIncrementallyAndCancellationClosesUpstream() async throws {
        let fixture = try await MobileUpstreamFixture()
        defer { fixture.stop() }
        let harness = try await MobileHarness(upstream: fixture.origin)
        defer { harness.stop() }
        let pair = try await harness.pair()
        let pin = MobileTestPin(fingerprint: harness.identity.fingerprint)
        let session = harness.client()
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: harness.url("/v1/ollama/api/generate"))
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(pair.token)", forHTTPHeaderField: "Authorization")
        let start = Date()
        let (bytes, _) = try await session.bytes(for: request, delegate: pin)
        var lines = bytes.lines.makeAsyncIterator()
        let first = try await lines.next()
        XCTAssertEqual(first, "{\"response\":\"first\"}")
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.9, "First chunk must not wait for upstream completion.")
        let second = try await lines.next()
        XCTAssertEqual(second, "{\"done\":true}")
        XCTAssertGreaterThan(Date().timeIntervalSince(start), 0.9)
        request.url = harness.url("/v1/ollama/api/pull")
        let (quietBytes, _) = try await session.bytes(for: request, delegate: pin)
        var quietLines = quietBytes.lines.makeAsyncIterator()
        let progress = try await quietLines.next()
        XCTAssertEqual(progress, "{\"status\":\"pulling\"}")
        try await harness.server.revokeDevice(pair.deviceID)
        await fixture.waitForDisconnect()
        XCTAssertTrue(fixture.quietDisconnected, "Revocation cancels an active quiet upstream, not merely the next token check.")
        do {
            let afterRevocation = try await quietLines.next()
            XCTAssertNil(afterRevocation, "Revoked stream must emit no fabricated completion line.")
        } catch { /* Foundation may report interruption as either EOF or a transport error. */ }
    }

    func testNonreadingPinnedTLSClientCannotRetainConnectionSlotPastTotalLifetime() async throws {
        let fixture = try await MobileUpstreamFixture()
        defer { fixture.stop() }
        let harness = try await MobileHarness(upstream: fixture.origin, relayLifetime: .seconds(2), sendTimeout: .milliseconds(100))
        defer { harness.stop() }
        let pair = try await harness.pair()
        let connection = try await mobileRawPinnedConnection(harness)
        defer { connection.cancel() }
        let body = "{}"
        let request = "POST /v1/ollama/api/pull HTTP/1.1\r\nHost: \(harness.host):\(harness.port)\r\nAuthorization: Bearer \(pair.token)\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        try await mobileRawSend(connection, Data(request.utf8))
        // Intentionally never receive from this TLS peer. A quiet stream cannot retain its slot indefinitely.
        let start = Date()
        while fixture.requestCount == 0, Date().timeIntervalSince(start) < 1 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(fixture.requestCount, 1)
        await fixture.waitForDisconnect(timeout: 4)
        XCTAssertTrue(fixture.quietDisconnected)
        XCTAssertEqual(harness.server.activeConnectionCount, 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        let next = try await harness.request("/v1/mobile/health", token: pair.token)
        XCTAssertEqual(next.0, 200, "A new request can use the slot after the nonreading client's hard deadline.")
    }

    func testBackpressuredPinnedTLSClientHitsSendDeadlineBeforeTotalLifetime() async throws {
        let fixture = try await MobileUpstreamFixture()
        defer { fixture.stop() }
        // Keep the total lifetime far outside the assertion window; only the send deadline can expire here.
        let harness = try await MobileHarness(upstream: fixture.origin, relayLifetime: .seconds(60), sendTimeout: .seconds(1))
        defer { harness.stop() }
        let pair = try await harness.pair()
        let connection = try await mobileRawPinnedConnection(harness)
        defer { connection.cancel() }
        let body = #"{"flood":true}"#
        let request = "POST /v1/ollama/api/pull HTTP/1.1\r\nHost: \(harness.host):\(harness.port)\r\nAuthorization: Bearer \(pair.token)\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let start = Date()
        try await mobileRawSend(connection, Data(request.utf8))
        // Never read the TLS response. Reused valid NDJSON records fill the peer's bounded receive buffers.
        await fixture.waitForDisconnect(timeout: 12)
        XCTAssertEqual(fixture.requestCount, 1)
        XCTAssertTrue(fixture.quietDisconnected, "The send deadline must cancel the upstream while the total lifetime is still pending.")
        XCTAssertGreaterThan(fixture.floodBytesSent, 64 * 1024, "A tiny single record would not exercise backpressure.")
        XCTAssertLessThan(fixture.floodBytesSent, MobileUpstreamFixture.maximumFloodBytes, "The producer must be interrupted, not finish or hit the stream size limit.")
        XCTAssertEqual(harness.server.activeConnectionCount, 0)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(elapsed, 1, "A send must remain blocked until the injected one-second deadline.")
        XCTAssertLessThan(elapsed, 12)
        print("Send-deadline evidence: upstream bytes=\(fixture.floodBytesSent), elapsed=\(elapsed)s, injected send=1s, total lifetime=60s, active slots=\(harness.server.activeConnectionCount)")
        let next = try await harness.request("/v1/mobile/health", token: pair.token)
        XCTAssertEqual(next.0, 200, "The timed-out sender releases its connection slot.")
    }

    func testDownstreamDisconnectCancelsQuietUpstream() async throws {
        let fixture = try await MobileUpstreamFixture()
        defer { fixture.stop() }
        let harness = try await MobileHarness(upstream: fixture.origin)
        defer { harness.stop() }
        let pair = try await harness.pair()
        let connection = try await mobileRawPinnedConnection(harness)
        let request = "POST /v1/ollama/api/pull HTTP/1.1\r\nHost: \(harness.host):\(harness.port)\r\nAuthorization: Bearer \(pair.token)\r\nContent-Length: 2\r\n\r\n{}"
        try await mobileRawSend(connection, Data(request.utf8))
        let deadline = Date().addingTimeInterval(2)
        while fixture.requestCount == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(fixture.requestCount, 1)
        connection.cancel()
        await fixture.waitForDisconnect()
        XCTAssertTrue(fixture.quietDisconnected)
        XCTAssertEqual(harness.server.activeConnectionCount, 0)
    }

    func testOversizedNDJSONLineAbortsWithoutCompletion() async throws {
        let fixture = try await MobileUpstreamFixture()
        defer { fixture.stop() }
        let harness = try await MobileHarness(upstream: fixture.origin)
        defer { harness.stop() }
        let pair = try await harness.pair()
        let client = harness.client()
        defer { client.invalidateAndCancel() }
        var request = URLRequest(url: harness.url("/v1/ollama/api/generate"))
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"oversized":true}"#.utf8)
        request.setValue("Bearer \(pair.token)", forHTTPHeaderField: "Authorization")
        let pin = MobileTestPin(fingerprint: harness.identity.fingerprint)
        let (bytes, _) = try await client.bytes(for: request, delegate: pin)
        var received = 0
        var sawNewline = false
        do {
            for try await byte in bytes {
                received += 1
                sawNewline = sawNewline || byte == 10
            }
        } catch { /* Truncation can be reported as EOF or an error by Foundation. */ }
        XCTAssertGreaterThan(received, 0)
        XCTAssertFalse(sawNewline, "The oversized line never receives a fabricated newline/completion event.")
        XCTAssertLessThanOrEqual(received, MobileOllamaServer.maximumNDJSONLineBytes)
    }

    func testRelayProductionByteLimitsRemainUnchanged() {
        XCTAssertEqual(MobileOllamaServer.maximumJSONBytes, 16 * 1_048_576)
        XCTAssertEqual(MobileOllamaServer.maximumStreamBytes, 256 * 1_048_576)
        XCTAssertEqual(MobileOllamaServer.maximumNDJSONLineBytes, 1_048_576)
        XCTAssertEqual(MobileOllamaServer.ResponseByteLimits.production.jsonBytes, 16 * 1_048_576)
        XCTAssertEqual(MobileOllamaServer.ResponseByteLimits.production.streamBytes, 256 * 1_048_576)
    }

    func testJSONAggregateByteLimitBelowExactAndOneOver() async throws {
        let limit = 4200
        // The smaller stream ceiling proves JSON selects its own aggregate policy.
        let limits = MobileOllamaServer.ResponseByteLimits(jsonBytes: limit, streamBytes: 1024)
        for count in [limit - 1, limit, limit + 1] {
            let payload = mobileBoundaryJSON(byteCount: count)
            XCTAssertEqual(payload.count, count)
            let completes = count <= limit
            var chunks = [Data(payload.prefix(4096))]
            if completes { chunks.append(Data(payload.dropFirst(4096))) }
            try await assertBoundaryRelay(payload: payload, ndjson: false, limits: limits,
                                          expectedChunks: chunks, completes: completes)
        }
    }

    func testNDJSONAggregateByteLimitIncludesNewlinesAndDoneRecord() async throws {
        let limit = 4200
        // Each line is far below the unchanged 1 MiB line ceiling. The JSON ceiling must not apply.
        let limits = MobileOllamaServer.ResponseByteLimits(jsonBytes: 1024, streamBytes: limit)
        let done = Data("{\"done\":true}\n".utf8)
        XCTAssertEqual(done.count, 14)
        for count in [limit - 1, limit, limit + 1] {
            let record = mobileBoundaryJSON(byteCount: count - done.count, trailingNewline: true)
            let payload = record + done
            XCTAssertEqual(payload.count, count, "Both newlines and the terminal NDJSON record count toward the ceiling.")
            let completes = count <= limit
            var chunks = [Data(record.prefix(4096)), Data(record.dropFirst(4096))]
            if completes { chunks.append(done) }
            // One-over crosses the ceiling on the done record's newline: that record must not flush.
            try await assertBoundaryRelay(payload: payload, ndjson: true, limits: limits,
                                          expectedChunks: chunks, completes: completes)
        }
    }

    func testJSONRelayFlushAndTailAt4095Through4097Bytes() async throws {
        for count in [4095, 4096, 4097] {
            let payload = mobileBoundaryJSON(byteCount: count)
            let chunks = count <= 4096 ? [payload] : [Data(payload.prefix(4096)), Data(payload.suffix(1))]
            try await assertBoundaryRelay(payload: payload, ndjson: false, limits: .production,
                                          expectedChunks: chunks, completes: true)
        }
    }

    func testNDJSONRelayNewlineFlushAndUnterminatedTailAt4095Through4097Bytes() async throws {
        for trailingNewline in [false, true] {
            for count in [4095, 4096, 4097] {
                let payload = mobileBoundaryJSON(byteCount: count, trailingNewline: trailingNewline)
                let chunks = count <= 4096 ? [payload] : [Data(payload.prefix(4096)), Data(payload.suffix(1))]
                try await assertBoundaryRelay(payload: payload, ndjson: true, limits: .production,
                                              expectedChunks: chunks, completes: true)
            }
        }
    }

    private func assertBoundaryRelay(payload: Data, ndjson: Bool, limits: MobileOllamaServer.ResponseByteLimits,
                                     expectedChunks: [Data], completes: Bool,
                                     file: StaticString = #filePath, line: UInt = #line) async throws {
        let fixture = try await MobileBoundaryFixture(payload: payload, ndjson: ndjson)
        defer { fixture.stop() }
        let harness = try await MobileHarness(upstream: fixture.origin, responseByteLimits: limits)
        defer { harness.stop() }
        let pair = try await harness.pair()
        let connection = try await mobileRawPinnedConnection(harness)
        defer { connection.cancel() }
        let response = Task { await mobileBoundaryRawResponse(connection) }
        defer { response.cancel() }
        let request = "POST /v1/ollama/api/generate HTTP/1.1\r\nHost: \(harness.host):\(harness.port)\r\nAuthorization: Bearer \(pair.token)\r\nContent-Length: 2\r\n\r\n{}"
        try await mobileRawSend(connection, Data(request.utf8))
        await fulfillment(of: [fixture.payloadProduced], timeout: 5)
        XCTAssertFalse(fixture.terminalAttempted, "The producer's completion is explicitly gated.", file: file, line: line)
        if completes {
            fixture.complete()
        } else {
            // Leave the upstream open. Only relay cancellation can satisfy this expectation.
            await fulfillment(of: [fixture.upstreamDisconnected], timeout: 5)
            XCTAssertFalse(fixture.completionReleased, "Disconnect is observed before releasing the terminal gate.", file: file, line: line)
            XCTAssertFalse(fixture.terminalAttempted, "The aggregate ceiling cancels a still-open upstream.", file: file, line: line)
        }
        let wire = await response.value
        XCTAssertFalse(wire.timedOut, "Relay must close without the test's read deadline.", file: file, line: line)
        guard let separator = wire.data.range(of: Data("\r\n\r\n".utf8)) else {
            XCTFail("Missing response headers", file: file, line: line); return
        }
        let header = String(decoding: wire.data[..<separator.lowerBound], as: UTF8.self)
        XCTAssertTrue(header.hasPrefix("HTTP/1.1 200 "), file: file, line: line)
        XCTAssertTrue(header.contains("Transfer-Encoding: chunked"), file: file, line: line)
        XCTAssertTrue(header.contains("Content-Type: \(ndjson ? "application/x-ndjson" : "application/json")"), file: file, line: line)
        let body = Data(wire.data[separator.upperBound...])
        let terminal = Data("0\r\n\r\n".utf8)
        var expected = Data()
        for chunk in expectedChunks {
            // Independent wire oracle, not the production HTTPResponseEncoder.
            expected.append(Data("\(String(chunk.count, radix: 16))\r\n".utf8))
            expected.append(chunk)
            expected.append(Data("\r\n".utf8))
        }
        if completes { expected.append(terminal) }
        XCTAssertEqual(body, expected, "Exact chunk sizes, payload bytes and tail must match.", file: file, line: line)
        XCTAssertEqual(body.suffix(terminal.count) == terminal, completes, file: file, line: line)
        if completes {
            XCTAssertEqual(expectedChunks.reduce(into: Data()) { $0.append($1) }, payload, file: file, line: line)
            XCTAssertTrue(fixture.terminalAttempted, file: file, line: line)
        } else if ndjson {
            XCTAssertFalse(body.range(of: Data("{\"done\":true}".utf8)) != nil, file: file, line: line)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while harness.server.activeConnectionCount != 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(harness.server.activeConnectionCount, 0, "Completed and aborted relays release their slot.", file: file, line: line)
        let next = try await harness.request("/v1/ollama/api/tags", token: pair.token)
        XCTAssertEqual(next.0, 200, "A subsequent authenticated Ollama relay can use the released slot.", file: file, line: line)
        XCTAssertEqual(next.1, Data("{\"models\":[]}".utf8), file: file, line: line)
    }

    func testUpstreamStatusRedirectAndUnavailable() async throws {
        let fixture = try await MobileUpstreamFixture()
        defer { fixture.stop() }
        let harness = try await MobileHarness(upstream: fixture.origin)
        defer { harness.stop() }
        let pair = try await harness.pair()
        let missing = try await harness.request("/v1/ollama/api/ps", token: pair.token)
        XCTAssertEqual(missing.0, 418)
        XCTAssertEqual(String(decoding: missing.1, as: UTF8.self), "{\"error\":\"fixture\"}")
        let redirect = try await harness.request("/v1/ollama/api/version", token: pair.token)
        XCTAssertEqual(redirect.0, 503)
        XCTAssertEqual(fixture.requestCount, 2, "Redirect must not cause a second upstream request.")
        fixture.stop()
        let unavailable = try await harness.request("/v1/ollama/api/tags", token: pair.token)
        XCTAssertEqual(unavailable.0, 503)
    }

    func testLANParserRejectsHostChangesQueriesAndPipelining() {
        for raw in ["GET /v1/mobile/health HTTP/1.1\r\nHost: evil.example\r\n\r\n",
                    "GET /v1/mobile/health?x=y HTTP/1.1\r\nHost: 192.168.1.2:8086\r\n\r\n",
                    "GET /v1/mobile/%68ealth HTTP/1.1\r\nHost: 192.168.1.2:8086\r\n\r\n",
                    "GET /v1/mobile/health HTTP/1.1\r\nHost: 192.168.1.2:8086\r\nHost: localhost\r\n\r\n",
                    "GET /v1/mobile/health HTTP/1.1\r\nHost: 192.168.1.2:8086\r\n\r\nextra"] {
            guard case .failure = MobileHTTPParser.parse(Data(raw.utf8), authority: "192.168.1.2:8086") else {
                XCTFail("Unsafe request accepted"); continue
            }
        }
    }

    private func assertAsyncThrows(_ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected failure") } catch { /* Expected validation failure. */ }
    }
}

final class MobileHarness: @unchecked Sendable {
    let identity: MobileTLSIdentity
    let store: MobileDeviceStore
    let server: MobileOllamaServer
    let host: String
    let port: UInt16
    private let directory: URL
    private let task: Task<Void, Error>
    let oldPair: MobileHelperPairingResponse?

    init(identity: MobileTLSIdentity? = nil, upstream: URL = URL(string: "http://127.0.0.1:11434")!,
         relayLifetime: Duration = MobileOllamaServer.relayLifetime, sendTimeout: Duration = MobileOllamaServer.sendTimeout,
         responseByteLimits: MobileOllamaServer.ResponseByteLimits = .production,
         capabilities: [String] = ["ollama"], claudeBackendURL: URL? = nil,
         accountRoutes: AccountRouteHandlers = AccountRouteHandlers(), seedOllamaDevice: Bool = false) async throws {
        guard let interface = MobileLANInterface.available().first else { throw XCTSkip("No active private IPv4 interface available for a real LAN-bound TLS test.") }
        self.host = interface.address
        self.identity = try identity ?? MobileTLSIdentity.ephemeral()
        directory = try makeDirectory()
        store = try MobileDeviceStore(helperID: self.identity.helperID, fileURL: directory.appendingPathComponent("devices.json"))
        if seedOllamaDevice {
            let code = try await store.generatePairingCode()
            oldPair = try await store.redeem(.init(code: code.code, name: "Old Ollama Phone"))
        } else { oldPair = nil }
        let ready = MobileTestPort()
        server = MobileOllamaServer(host: host, port: 0, identity: self.identity, devices: store, upstream: upstream, relayLifetime: relayLifetime, sendTimeout: sendTimeout, responseByteLimits: responseByteLimits, accountRoutes: accountRoutes, onReady: { ready.resolve(.success($0)) })
        try await server.configure(capabilities: capabilities, claudeBackendURL: claudeBackendURL)
        let server = self.server
        task = Task { do { try await server.run() } catch { ready.resolve(.failure(error)); throw error } }
        port = try await ready.wait()
    }
    func stop() { task.cancel() }
    deinit { task.cancel(); try? FileManager.default.removeItem(at: directory) }
    func url(_ path: String) -> URL { URL(string: "https://\(host):\(port)\(path)")! }
    func client(fingerprint: String? = nil) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        return URLSession(configuration: config, delegate: MobileTestPin(fingerprint: fingerprint ?? identity.fingerprint), delegateQueue: nil)
    }
    func pair() async throws -> MobileHelperPairingResponse {
        let code = try await store.generatePairingCode()
        let response = try await request("/v1/mobile/pair", method: "POST", body: String(decoding: JSONEncoder().encode(MobileHelperPairingRequest(code: code.code, name: "Test Phone")), as: UTF8.self))
        XCTAssertEqual(response.0, 200)
        return try JSONDecoder().decode(MobileHelperPairingResponse.self, from: response.1)
    }
    func request(_ path: String, method: String = "GET", token: String? = nil, body: String? = nil,
                 accountToken: String? = nil) async throws -> (Int, Data) {
        let session = client()
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url(path))
        request.httpMethod = method
        request.httpBody = body.map { Data($0.utf8) }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let accountToken { request.setValue(accountToken, forHTTPHeaderField: "X-LangTools-Account-Token") }
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

final class MobileTestPin: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    let fingerprint: String
    init(fingerprint: String) { self.fingerprint = fingerprint }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = certificates.first,
              digest(SecCertificateCopyData(leaf) as Data) == fingerprint,
              SecTrustSetPolicies(trust, SecPolicyCreateBasicX509()) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [leaf] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

final class MobileUpstreamFixture: @unchecked Sendable {
    private var port: UInt16 = 0
    var origin: URL { URL(string: "http://127.0.0.1:\(port)")! }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "MobileUpstreamFixture")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var tasks: [Task<Void, Never>] = []
    private var authorization: String?
    private var path: String?
    private var count = 0
    private var lastHeaders: [String: String] = [:]
    private let claudeMode: ClaudeMode
    enum ClaudeMode { case normal, redirect, error, errorEvent, successErrorBody, escapedSuccess, quiet, oversized }
    var receivedHeaders: [String: String] { lock.withLock { lastHeaders } }
    private var disconnected = false
    private var floodSent = 0
    static let maximumFloodBytes = 64 * 1024 * 1024
    var floodBytesSent: Int { lock.withLock { floodSent } }
    var lastAuthorization: String? { lock.withLock { authorization } }
    var lastPath: String? { lock.withLock { path } }
    var requestCount: Int { lock.withLock { count } }
    var quietDisconnected: Bool { lock.withLock { disconnected } }

    init(claudeMode: ClaudeMode = .normal) async throws {
        self.claudeMode = claudeMode
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = MobileTestPort()
        listener.stateUpdateHandler = { [listener] state in
            switch state {
            case .ready: ready.resolve(.success(listener.port!.rawValue))
            case .failed(let error): ready.resolve(.failure(error))
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        port = try await ready.wait()
    }
    func stop() {
        listener.cancel()
        let snapshot = lock.withLock { (connections, tasks) }
        snapshot.0.forEach { $0.cancel() }
        snapshot.1.forEach { $0.cancel() }
    }
    func waitForDisconnect(timeout: Double = 2) async {
        for _ in 0..<Int(timeout * 50) {
            if quietDisconnected { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
    private func accept(_ connection: NWConnection) {
        lock.withLock { connections.append(connection) }
        connection.start(queue: queue)
        receive(connection, data: Data())
    }
    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] part, _, _, error in
            guard let self, error == nil else { connection.cancel(); return }
            let accumulated = data + (part ?? Data())
            switch HTTPRequest.parse(from: accumulated) {
            case .incomplete: self.receive(connection, data: accumulated)
            case .failure: connection.cancel()
            case .request(let request):
                self.lock.withLock { self.authorization = request.authorizationBearerToken; self.path = request.path; self.lastHeaders = request.headers; self.count += 1 }
                let task = Task { await self.respond(connection, request: request) }
                self.lock.withLock { self.tasks.append(task) }
            }
        }
    }
    private func respond(_ connection: NWConnection, request: HTTPRequest) async {
        do {
            switch request.path {
            case "/auth/claude-code/models", "/account/chat/completions":
                switch claudeMode {
                case .redirect:
                    try await send(connection, Data("HTTP/1.1 302 Found\r\nLocation: \(origin)/redirect-target\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
                case .error:
                    let body = "echoed-secret: " + (request.authorizationBearerToken ?? "")
                    try await send(connection, HTTPResponseEncoder.fixed(status: .unauthorized, body: body))
                case .errorEvent:
                    try await send(connection, HTTPResponseEncoder.chunkedHeader(status: .ok))
                    let event = HelperChatStreamEvent.failure("echoed-secret: " + (request.authorizationBearerToken ?? ""))
                    try await send(connection, try HTTPResponseEncoder.ndjsonChunk(event))
                    try await send(connection, HTTPResponseEncoder.terminalChunk)
                case .escapedSuccess:
                    try await send(connection, HTTPResponseEncoder.fixed(status: .ok, body: #"{"content":"\u0061ccount-secret-do-not-echo"}"#))
                case .successErrorBody:
                    let body = "{\"error\":\"echoed-secret: " + (request.authorizationBearerToken ?? "") + "\"}"
                    try await send(connection, HTTPResponseEncoder.fixed(status: .ok, body: body))
                case .quiet:
                    try await send(connection, HTTPResponseEncoder.chunkedHeader(status: .ok))
                    try await send(connection, HTTPResponseEncoder.chunk(Data("{\"type\":\"delta\",\"delta\":\"first\"}\n".utf8)))
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, _, _ in
                        self?.lock.withLock { self?.disconnected = true }
                    }
                    return
                case .oversized:
                    try await send(connection, HTTPResponseEncoder.chunkedHeader(status: .ok))
                    try await send(connection, HTTPResponseEncoder.chunk(Data(("{\"type\":\"delta\",\"delta\":\"" + String(repeating: "x", count: 4096) + "\"}\n").utf8)))
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, _, _ in
                        self?.lock.withLock { self?.disconnected = true }
                    }
                    return
                case .normal:
                    try await send(connection, HTTPResponseEncoder.fixed(status: .ok, body: request.path.contains("models") ? "{\"models\":[]}" : "{\"content\":\"claude fixture\"}"))
                }
            case "/api/generate":
                try await send(connection, HTTPResponseEncoder.chunkedHeader(status: .ok))
                if String(decoding: request.body, as: UTF8.self).contains("oversized") {
                    let payload = Data(repeating: 97, count: 4096)
                    for _ in 0..<258 { try await send(connection, HTTPResponseEncoder.chunk(payload)) }
                    try await send(connection, HTTPResponseEncoder.terminalChunk)
                    connection.cancel()
                    return
                }
                try await send(connection, HTTPResponseEncoder.chunk(Data("{\"response\":\"first\"}\n".utf8)))
                try await Task.sleep(for: .seconds(1.2))
                try await send(connection, HTTPResponseEncoder.chunk(Data("{\"done\":true}\n".utf8)))
                try await send(connection, HTTPResponseEncoder.terminalChunk)
            case "/api/pull":
                try await send(connection, HTTPResponseEncoder.chunkedHeader(status: .ok))
                if String(decoding: request.body, as: UTF8.self).contains("flood") {
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, _, _ in
                        self?.lock.withLock { self?.disconnected = true }
                    }
                    // One reusable 64 KiB record and one awaited send at a time: no giant response allocation.
                    let record = Data(("{\"status\":\"" + String(repeating: "x", count: 64 * 1024 - 14) + "\"}\n").utf8)
                    let chunk = HTTPResponseEncoder.chunk(record)
                    for _ in 0..<(Self.maximumFloodBytes / record.count) {
                        try Task.checkCancellation()
                        try await send(connection, chunk)
                        lock.withLock { floodSent += record.count }
                    }
                    // Deliberately never send a terminal event, even if the bounded producer finishes.
                    return
                }
                try await send(connection, HTTPResponseEncoder.chunk(Data("{\"status\":\"pulling\"}\n".utf8)))
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, _, _ in
                    self?.lock.withLock { self?.disconnected = true }
                }
                return
            case "/api/version":
                try await send(connection, Data("HTTP/1.1 302 Found\r\nLocation: \(origin)/api/tags\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
            case "/api/ps":
                try await send(connection, Data("HTTP/1.1 418 Teapot\r\nContent-Type: application/json\r\nContent-Length: 19\r\nConnection: close\r\n\r\n{\"error\":\"fixture\"}".utf8))
            case "/api/chat":
                try await send(connection, HTTPResponseEncoder.fixed(status: .ok, body: "{\"message\":{\"content\":\"hello\"}}"))
            default:
                try await send(connection, HTTPResponseEncoder.fixed(status: .ok, body: "{\"models\":[]}"))
            }
            connection.cancel()
        } catch { connection.cancel() }
    }
    private func send(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
}

/// Small bodies exercise the production byte loop; producer EOF is controlled, never timed by a sleep.
private final class MobileBoundaryFixture: @unchecked Sendable {
    let payloadProduced = XCTestExpectation(description: "Boundary upstream sent its complete payload")
    let upstreamDisconnected = XCTestExpectation(description: "Relay cancelled the still-open boundary upstream")
    private let listener: NWListener
    private let queue = DispatchQueue(label: "MobileBoundaryFixture")
    private let lock = NSLock()
    private let completion = MobileBoundaryGate()
    private let payload: Data
    private let ndjson: Bool
    private var port: UInt16 = 0
    private var connections: [NWConnection] = []
    private var tasks: [Task<Void, Never>] = []
    private var disconnected = false
    private var attemptedTerminal = false
    var origin: URL { URL(string: "http://127.0.0.1:\(port)")! }
    var terminalAttempted: Bool { lock.withLock { attemptedTerminal } }
    var completionReleased: Bool { completion.isOpen }

    init(payload: Data, ndjson: Bool) async throws {
        self.payload = payload; self.ndjson = ndjson
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = MobileTestPort()
        listener.stateUpdateHandler = { [listener] state in
            switch state {
            case .ready: ready.resolve(.success(listener.port!.rawValue))
            case .failed(let error): ready.resolve(.failure(error))
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.lock.withLock { self.connections.append(connection) }
            connection.start(queue: self.queue)
            self.receive(connection, accumulated: Data())
        }
        listener.start(queue: queue)
        port = try await ready.wait()
    }

    func complete() { completion.open() }
    func stop() {
        listener.cancel()
        let snapshot = lock.withLock { (connections, tasks) }
        snapshot.1.forEach { $0.cancel() }
        snapshot.0.forEach { $0.cancel() }
        completion.open()
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self, error == nil, !complete else { connection.cancel(); return }
            let accumulated = accumulated + (data ?? Data())
            switch HTTPRequest.parse(from: accumulated) {
            case .incomplete: self.receive(connection, accumulated: accumulated)
            case .failure: connection.cancel()
            case .request(let request):
                let task = Task { await self.respond(connection, path: request.path) }
                self.lock.withLock { self.tasks.append(task) }
            }
        }
    }

    private func respond(_ connection: NWConnection, path: String) async {
        do {
            if path == "/api/tags" {
                try await mobileRawSend(connection, HTTPResponseEncoder.fixed(status: .ok, body: "{\"models\":[]}"))
                connection.cancel()
                return
            }
            // No fixture close/EOF occurs before the explicit completion gate or relay cancellation.
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, complete, error in
                guard let self, complete || error != nil else { return }
                let first = self.lock.withLock { () -> Bool in
                    guard !self.disconnected else { return false }
                    self.disconnected = true
                    return true
                }
                if first { self.upstreamDisconnected.fulfill() }
            }
            let type = ndjson ? "application/x-ndjson" : "application/json"
            let header = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
            try await mobileRawSend(connection, Data(header.utf8))
            try await mobileRawSend(connection, HTTPResponseEncoder.chunk(payload))
            payloadProduced.fulfill()
            await completion.wait()
            try Task.checkCancellation()
            let canComplete = lock.withLock { () -> Bool in
                guard !disconnected else { return false }
                attemptedTerminal = true
                return true
            }
            guard canComplete else { return }
            try await mobileRawSend(connection, HTTPResponseEncoder.terminalChunk)
            connection.cancel()
        } catch {
            // Retain unexpected producer failures as test failures; shutdown/cancellation is intentional.
            if !Task.isCancelled, !lock.withLock({ disconnected }) {
                XCTFail("Boundary fixture failed: \(error)")
            }
            connection.cancel()
        }
    }
}

private final class MobileBoundaryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    var isOpen: Bool { lock.withLock { opened } }
    func open() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            opened = true
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume()
    }
    func wait() async {
        await withCheckedContinuation { continuation in
            let alreadyOpen = lock.withLock {
                if opened { return true }
                self.continuation = continuation
                return false
            }
            if alreadyOpen { continuation.resume() }
        }
    }
}

private func mobileBoundaryJSON(byteCount: Int, trailingNewline: Bool = false) -> Data {
    // A multibyte scalar makes these byte boundaries, not String character-count boundaries.
    let prefix = Data("{\"response\":\"é".utf8)
    let suffix = Data(("\"}" + (trailingNewline ? "\n" : "")).utf8)
    return prefix + Data(repeating: 120, count: byteCount - prefix.count - suffix.count) + suffix
}

func mobileBoundaryRawResponse(_ connection: NWConnection) async -> (data: Data, timedOut: Bool) {
    let timeout = MobileBoundaryGate()
    let deadline = Task {
        do {
            try await Task.sleep(for: .seconds(5))
            timeout.open()
            connection.cancel()
        } catch { /* The bounded read completed before its safety deadline. */ }
    }
    defer { deadline.cancel() }
    var accumulated = Data()
    while true {
        let (data, complete, error) = await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { data, _, complete, error in
                continuation.resume(returning: (data, complete, error))
            }
        }
        if let data { accumulated.append(data) }
        // NWConnection may close with EOF or a transport error. Exact wire assertions distinguish success/abort.
        if complete || error != nil { return (accumulated, timeout.isOpen) }
        if accumulated.count > 32 * 1024 {
            XCTFail("Boundary response exceeded the small fixture's bounded wire budget.")
            connection.cancel()
            return (accumulated, timeout.isOpen)
        }
    }
}

private final class MobileTestPort: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<UInt16, Error>?
    private var continuation: CheckedContinuation<UInt16, Error>?
    func resolve(_ result: Result<UInt16, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<UInt16, Error>? in
            guard self.result == nil else { return nil }
            self.result = result
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }
    func wait() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            let result = lock.withLock { () -> Result<UInt16, Error>? in
                if let existing = self.result { return existing }
                self.continuation = continuation
                return nil
            }
            if let result { continuation.resume(with: result) }
        }
    }
}

private final class MobileTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date()
    var now: Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
}

func mobileRawPinnedConnection(_ harness: MobileHarness) async throws -> NWConnection {
    let tls = NWProtocolTLS.Options()
    let queue = DispatchQueue(label: "MobileRawPinnedTest")
    let fingerprint = harness.identity.fingerprint
    sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, securityTrust, complete in
        let trust = sec_trust_copy_ref(securityTrust).takeRetainedValue()
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
              digest(SecCertificateCopyData(leaf) as Data) == fingerprint,
              SecTrustSetPolicies(trust, SecPolicyCreateBasicX509()) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [leaf] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else { complete(false); return }
        complete(true)
    }, queue)
    let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    let connection = NWConnection(host: NWEndpoint.Host(harness.host), port: NWEndpoint.Port(rawValue: harness.port)!, using: parameters)
    connection.start(queue: queue)
    // A processed send waits for the TLS handshake; no response reads are registered.
    try await mobileRawSend(connection, Data())
    return connection
}

func mobileRawSend(_ connection: NWConnection, _ data: Data) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        connection.send(content: data, completion: .contentProcessed { error in
            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        })
    }
}

private func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("langtools-mobile-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return directory
}
