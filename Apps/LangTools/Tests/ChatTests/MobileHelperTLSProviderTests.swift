#if os(macOS)
import CryptoKit
import Foundation
import LangTools
import Network
import Ollama
import OpenAI
import Security
import XCTest
@testable import Chat

/// Real socket/TLS tests. No fixed ports or actual helper/Ollama daemon required.
@MainActor
final class MobileHelperTLSProviderTests: XCTestCase {
    func testActualOllamaProviderStreamsPinnedTLSIncrementally() async throws {
        let fixture = try HelperTLSFixture(mode: .stream)
        let endpoint = try await fixture.start()
        defer { fixture.stop() }
        let session = MobileHelperSessionDelegate.session(endpoint: endpoint, fingerprint: fixture.fingerprint)
        defer { session.invalidateAndCancel() }
        let snapshot = makeSnapshot(endpoint: endpoint, session: session, pin: fixture.fingerprint)
        let provider = try snapshot.provider(directSession: .shared)
        let model = try XCTUnwrap(Ollama.Model(rawValue: "fixture-model"))
        let started = Date()
        var content = ""
        var firstOutputAt: TimeInterval?
        var terminalReceived = false
        for try await response in provider.streamChat(model: model, messages: [.init(role: .user, content: "hello")]) {
            if let text = response.message?.content.text, !text.isEmpty {
                if firstOutputAt == nil { firstOutputAt = Date().timeIntervalSince(started) }
                content += text
            }
            terminalReceived = terminalReceived || response.done
        }
        XCTAssertEqual(content, "hello")
        XCTAssertTrue(terminalReceived)
        XCTAssertLessThan(try XCTUnwrap(firstOutputAt), 0.9)
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 1.0)
        XCTAssertTrue(fixture.requests.allSatisfy { $0.hasPrefix("POST /v1/ollama/api/chat ") })
        XCTAssertTrue(fixture.requests.allSatisfy { $0.contains("Authorization: Bearer " + String(repeating: "c", count: 64)) })
    }

    func testActualProviderCleanEOFFailsAfterYieldingPinnedTLSPartialOutput() async throws {
        try await assertCleanEOFIsIncomplete(mode: .cleanEOF)
    }

    func testActualProviderCleanEOFDoesNotExecutePartialToolCall() async throws {
        try await assertCleanEOFIsIncomplete(mode: .cleanEOFToolCall)
    }

    private func assertCleanEOFIsIncomplete(mode: HelperTLSFixture.Mode,
                                            file: StaticString = #filePath, line: UInt = #line) async throws {
        let fixture = try HelperTLSFixture(mode: mode)
        let endpoint = try await fixture.start()
        defer { fixture.stop() }
        let session = MobileHelperSessionDelegate.session(endpoint: endpoint, fingerprint: fixture.fingerprint)
        defer { session.invalidateAndCancel() }
        let provider = try makeSnapshot(endpoint: endpoint, session: session, pin: fixture.fingerprint).provider(directSession: .shared)
        let calls = TLSFixtureToolTracker()
        let tool = OpenAI.Tool(name: "fixture_tool", description: nil, tool_schema: .init(), callback: { _, _ in
            await calls.called()
            return "must not execute"
        })
        let started = Date()
        var firstOutputAt: TimeInterval?
        var contents: [String] = []
        var terminalReceived = false
        do {
            for try await response in provider.streamChat(model: .init(rawValue: "fixture-model")!, messages: [], tools: [tool]) {
                if let text = response.message?.content.text, !text.isEmpty {
                    if firstOutputAt == nil { firstOutputAt = Date().timeIntervalSince(started) }
                    contents.append(text)
                }
                terminalReceived = terminalReceived || response.done
            }
            XCTFail("Clean HTTP/TLS EOF without done:true must not complete chat", file: file, line: line)
        } catch let error as LangToolsError {
            guard case .incompleteStream = error else {
                XCTFail("Expected incompleteStream, got \(error)", file: file, line: line)
                return
            }
        } catch {
            XCTFail("Expected incompleteStream, got \(error)", file: file, line: line)
            return
        }
        XCTAssertEqual(contents, ["hel"], "Retain the partial response", file: file, line: line)
        XCTAssertFalse(terminalReceived, file: file, line: line)
        XCTAssertLessThan(try XCTUnwrap(firstOutputAt, file: file, line: line), 0.9, file: file, line: line)
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 1.0, file: file, line: line)
        let callCount = await calls.count
        XCTAssertEqual(callCount, 0, "Incomplete streams must not invoke tools", file: file, line: line)
        XCTAssertEqual(fixture.requests.count, 1, "No recursive tool completion request", file: file, line: line)
        XCTAssertTrue(fixture.requests.allSatisfy { $0.hasPrefix("POST /v1/ollama/api/chat ") }, file: file, line: line)
        XCTAssertTrue(fixture.requests.allSatisfy { $0.contains("Authorization: Bearer " + String(repeating: "c", count: 64)) }, file: file, line: line)
    }

    func testActualProviderStreamingRejectsWrongCertificateBeforeSendingBearer() async throws {
        let fixture = try HelperTLSFixture(mode: .stream)
        let endpoint = try await fixture.start()
        defer { fixture.stop() }
        let pin = String(repeating: "0", count: 64)
        let session = MobileHelperSessionDelegate.session(endpoint: endpoint, fingerprint: pin)
        defer { session.invalidateAndCancel() }
        let provider = try makeSnapshot(endpoint: endpoint, session: session, pin: pin).provider(directSession: .shared)
        do {
            for try await _ in provider.streamChat(model: .init(rawValue: "fixture-model")!, messages: []) {}
            XCTFail("Wrong pin must fail")
        } catch {
            XCTAssertEqual(MobileHelperError.actionable(error, session: session) as? MobileHelperError, .trustChanged,
                "TLS rejection error code: \((error as NSError).code)")
        }
        XCTAssertTrue(fixture.requests.isEmpty, "No HTTP credential may be sent before pinned trust succeeds")
    }

    func testActualProviderStreamingRejectsRedirectWithoutSecondAuthenticatedRequest() async throws {
        let fixture = try HelperTLSFixture(mode: .redirect)
        let endpoint = try await fixture.start()
        defer { fixture.stop() }
        let session = MobileHelperSessionDelegate.session(endpoint: endpoint, fingerprint: fixture.fingerprint)
        defer { session.invalidateAndCancel() }
        let provider = try makeSnapshot(endpoint: endpoint, session: session, pin: fixture.fingerprint).provider(directSession: .shared)
        do {
            for try await _ in provider.streamChat(model: .init(rawValue: "fixture-model")!, messages: []) {}
            XCTFail("Redirect must fail")
        } catch {
            XCTAssertEqual(MobileHelperError.actionable(error, session: session) as? MobileHelperError, .redirectRejected)
        }
        XCTAssertEqual(fixture.requests.count, 1)
        XCTAssertFalse(fixture.requests.contains { $0.hasPrefix("POST /redirected") })
    }

    private func makeSnapshot(endpoint: URL, session: URLSession, pin: String) -> OllamaEndpointConfiguration.Snapshot {
        // Loopback is only used in this isolated TLS fixture. Production pairing
        // and Keychain validation reject it; no configuration is persisted here.
        let credential = MobileHelperCredential(endpoint: endpoint, helperID: UUID().uuidString,
            fingerprint: pin, name: "TLS fixture", deviceID: UUID().uuidString,
            token: String(repeating: "c", count: 64), capabilities: ["ollama"])
        return .init(baseURL: endpoint.appendingPathComponent("v1/ollama"), revision: 1,
            helperID: credential.helperID, helperName: credential.name,
            helper: MobileHelperConnection(credential: credential, session: session), helperError: nil)
    }
}

private actor TLSFixtureToolTracker {
    private(set) var count = 0
    func called() { count += 1 }
}

private final class HelperTLSFixture: @unchecked Sendable {
    enum Mode { case stream, redirect, cleanEOF, cleanEOFToolCall }
    let fingerprint: String
    private let listener: NWListener
    private let mode: Mode
    private let queue = DispatchQueue(label: "app.helper.tls.fixture")
    private let lock = NSLock()
    private var recordedRequests: [String] = []
    private var connections: [NWConnection] = []
    var requests: [String] { lock.lock(); defer { lock.unlock() }; return recordedRequests }

    init(mode: Mode) throws {
        self.mode = mode
        let url = try XCTUnwrap(Bundle.module.url(forResource: "fixture-identity", withExtension: "p12", subdirectory: "HelperCertificates"))
        let pkcs12 = try Data(contentsOf: url)
        var imported: CFArray?
        let options = [kSecImportExportPassphrase as String: "fixture-only"] as CFDictionary
        guard SecPKCS12Import(pkcs12 as CFData, options, &imported) == errSecSuccess,
              let entry = (imported as? [[String: Any]])?.first,
              let rawIdentity = entry[kSecImportItemIdentity as String] else { throw FixtureError.identity }
        let identity = rawIdentity as! SecIdentity
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate,
              let networkIdentity = sec_identity_create(identity) else { throw FixtureError.identity }
        let der = SecCertificateCopyData(certificate) as Data
        fingerprint = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, networkIdentity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        let parameters = NWParameters(tls: tls)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.listener.stateUpdateHandler = nil
                    guard let port = self.listener.port else { continuation.resume(throwing: FixtureError.listener); return }
                    continuation.resume(returning: URL(string: "https://127.0.0.1:\(port.rawValue)")!)
                case .failed(let error):
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.connections.append(connection)
                connection.start(queue: self.queue)
                self.receive(connection, data: Data())
            }
            listener.start(queue: queue)
        }
    }
    func stop() {
        queue.sync {
            listener.cancel()
            connections.forEach { $0.cancel() }
            connections = []
        }
    }
    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] chunk, _, done, error in
            guard let self else { return }
            var accumulated = data
            if let chunk { accumulated.append(chunk) }
            guard accumulated.count <= 65_536, error == nil else { connection.cancel(); return }
            if let headers = String(data: accumulated, encoding: .utf8), headers.contains("\r\n\r\n") {
                self.lock.lock(); self.recordedRequests.append(headers); self.lock.unlock()
                self.respond(connection)
            } else if !done {
                self.receive(connection, data: accumulated)
            } else { connection.cancel() }
        }
    }
    private func respond(_ connection: NWConnection) {
        if mode == .redirect {
            let response = "HTTP/1.1 302 Found\r\nLocation: /redirected\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(response.utf8), contentContext: .finalMessage, isComplete: true,
                completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        let toolCalls = mode == .cleanEOFToolCall
            ? #", "tool_calls":[{"function":{"name":"fixture_tool","arguments":{}}}]"# : ""
        let first = #"{"model":"fixture-model","created_at":"2026-10-07T00:00:00Z","message":{"role":"assistant","content":"hel"\#(toolCalls)},"done":false}"# + "\n"
        let last = #"{"model":"fixture-model","created_at":"2026-10-07T00:00:00Z","message":{"role":"assistant","content":"lo"},"done":true}"# + "\n"
        let headers = "HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
        let start = headers + chunk(first)
        connection.send(content: Data(start.utf8), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { connection.cancel(); return }
            self.queue.asyncAfter(deadline: .now() + 1.2) {
                // A valid HTTP terminating chunk produces clean transport EOF, not
                // a socket/reset error. The provider's terminal record is omitted.
                let final = (self.mode == .cleanEOF || self.mode == .cleanEOFToolCall)
                    ? "0\r\n\r\n" : self.chunk(last) + "0\r\n\r\n"
                connection.send(content: Data(final.utf8), contentContext: .finalMessage, isComplete: true,
                    completion: .contentProcessed { _ in connection.cancel() })
            }
        })
    }
    private func chunk(_ value: String) -> String { String(value.utf8.count, radix: 16) + "\r\n" + value + "\r\n" }
    private enum FixtureError: Error { case identity, listener }
}
#endif
