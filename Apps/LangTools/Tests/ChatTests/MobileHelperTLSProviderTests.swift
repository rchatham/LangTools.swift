#if os(macOS)
import CryptoKit
import Darwin
import Foundation
import HelperLink
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
        XCTAssertEqual(fixture.receivedHTTPByteCount, 0, "Not even partial HTTP headers/body may arrive")
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

    func testActualProviderNonstreamingTagsAndChatUsePinnedTLS() async throws {
        for operation in DataOperation.allCases {
            let fixture = try HelperTLSFixture(mode: .http, response: { _ in operation.response })
            let endpoint = try await fixture.start()
            defer { fixture.stop() }
            let session = MobileHelperSessionDelegate.session(endpoint: endpoint, fingerprint: fixture.fingerprint)
            defer { session.invalidateAndCancel() }
            let provider = try makeSnapshot(endpoint: endpoint, session: session, pin: fixture.fingerprint).provider(directSession: .shared)
            try await operation.perform(provider)
            XCTAssertEqual(fixture.requests.count, 1)
            XCTAssertTrue(try XCTUnwrap(fixture.requests.first).hasPrefix(operation.requestLine))
            XCTAssertTrue(try XCTUnwrap(fixture.requests.first).contains("Authorization: Bearer " + HelperTLSFixture.token))
        }
    }

    func testActualProviderNonstreamingWrongPinNeverSendsBearer() async throws {
        for operation in DataOperation.allCases {
            let fixture = try HelperTLSFixture(mode: .http, response: { _ in operation.response })
            let endpoint = try await fixture.start()
            defer { fixture.stop() }
            let pin = String(repeating: "0", count: 64)
            let session = MobileHelperSessionDelegate.session(endpoint: endpoint, fingerprint: pin)
            defer { session.invalidateAndCancel() }
            let snapshot = makeSnapshot(endpoint: endpoint, session: session, pin: pin)
            do {
                try await operation.perform(snapshot.provider(directSession: .shared))
                XCTFail("Wrong pin must fail for \(operation)")
            } catch {
                XCTAssertEqual(snapshot.actionableError(error) as? MobileHelperError, .trustChanged)
            }
            XCTAssertTrue(fixture.requests.isEmpty, "TLS must reject before any bearer HTTP request")
            XCTAssertEqual(fixture.receivedHTTPByteCount, 0, "Not even partial bearer HTTP headers may arrive")
        }
    }

    func testActualProviderNonstreamingRedirectNeverSendsSecondAuthenticatedRequest() async throws {
        for operation in DataOperation.allCases {
            let fixture = try HelperTLSFixture(mode: .http, response: { _ in .redirect(to: "/redirected") })
            let endpoint = try await fixture.start()
            defer { fixture.stop() }
            let session = MobileHelperSessionDelegate.session(endpoint: endpoint, fingerprint: fixture.fingerprint)
            defer { session.invalidateAndCancel() }
            let snapshot = makeSnapshot(endpoint: endpoint, session: session, pin: fixture.fingerprint)
            do {
                try await operation.perform(snapshot.provider(directSession: .shared))
                XCTFail("Redirect must fail for \(operation)")
            } catch {
                XCTAssertEqual(snapshot.actionableError(error) as? MobileHelperError, .redirectRejected)
            }
            XCTAssertEqual(fixture.requests.count, 1)
            XCTAssertTrue(try XCTUnwrap(fixture.requests.first).hasPrefix(operation.requestLine))
            XCTAssertTrue(try XCTUnwrap(fixture.requests.first).contains("Authorization: Bearer " + HelperTLSFixture.token))
            XCTAssertFalse(fixture.requests.contains { $0.contains(" /redirected ") })
        }
    }

    private enum DataOperation: CaseIterable {
        case tags, chat
        var requestLine: String {
            self == .tags ? "GET /v1/ollama/api/tags " : "POST /v1/ollama/api/chat "
        }
        var response: HelperTLSFixture.Response {
            .init(body: self == .tags ? #"{"models":[]}"# :
                #"{"model":"fixture-model","created_at":"2026-10-07T00:00:00Z","message":{"role":"assistant","content":"hello"},"done":true}"#)
        }
        func perform(_ provider: Ollama) async throws {
            switch self {
            case .tags:
                let result = try await provider.listModels()
                XCTAssertTrue(result.models.isEmpty)
            case .chat:
                let result = try await provider.chat(model: .init(rawValue: "fixture-model")!, messages: [.init(role: .user, content: "hello")])
                XCTAssertEqual(result.message?.content.text, "hello")
                XCTAssertTrue(result.done)
            }
        }
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

/// The production pairing validator rejects loopback. These tests bind only a
/// selected local private IPv4 (never a wildcard), using synthetic credentials
/// and the same TEST-ONLY certificate as the loopback provider fixture.
@MainActor
final class MobileHelperTLSPairingTests: XCTestCase {
    func testActualPairingPersistsOnlyAfterMatchingAuthenticatedHealth() async throws {
        let host = try privateIPv4()
        let fixture = try HelperTLSFixture(mode: .http, host: host, response: { request in
            request.hasPrefix("POST /v1/mobile/pair ") ? HelperTLSFixture.pairingResponse : HelperTLSFixture.healthResponse(held: true)
        })
        let endpoint = try await fixture.start()
        defer { fixture.stop() }
        let state = PairingState()
        defer { state.cleanUp() }
        let original = state.configuration.snapshot()
        let payload = makePayload(endpoint: endpoint, fingerprint: fixture.fingerprint)
        let coordinator = state.coordinator
        coordinator.handle(try payload.pairingURL())
        XCTAssertEqual(state.configuration.snapshot(), original)
        XCTAssertTrue(state.store.records.isEmpty)
        XCTAssertTrue(fixture.requests.isEmpty, "Receiving QR is not consent to redeem")
        coordinator.confirm(payload, generation: coordinator.pendingGeneration, deviceName: "Fixture Phone")
        try await waitUntil { fixture.requests.count == 2 }
        XCTAssertTrue(coordinator.isPairing)
        XCTAssertEqual(state.configuration.snapshot(), original)
        XCTAssertTrue(state.store.records.isEmpty, "No credential may persist while health is unverified")
        XCTAssertNil(state.defaults.string(forKey: OllamaEndpointConfiguration.helperSelectionKey))
        XCTAssertEqual(state.selectionCount, 0)
        assertPairAndHealthRequests(fixture.requests)
        fixture.releaseResponses()
        try await waitUntil { !coordinator.isPairing }
        XCTAssertNil(coordinator.errorMessage)
        XCTAssertEqual(state.selectionCount, 1)
        let credential = try XCTUnwrap(state.store.records[HelperTLSFixture.helperID])
        XCTAssertEqual(credential.endpoint, endpoint)
        XCTAssertEqual(credential.fingerprint, fixture.fingerprint)
        XCTAssertEqual(credential.deviceID, HelperTLSFixture.deviceID)
        XCTAssertEqual(credential.token, HelperTLSFixture.token)
        XCTAssertEqual(credential.capabilities, ["ollama"])
        XCTAssertEqual(state.configuration.snapshot().helperID, HelperTLSFixture.helperID)
        XCTAssertEqual(state.defaults.string(forKey: OllamaEndpointConfiguration.helperSelectionKey), HelperTLSFixture.helperID)
        let session = try XCTUnwrap(state.configuration.snapshot().helper?.session)
        defer { session.invalidateAndCancel() }
        XCTAssertTrue(session.delegate is MobileHelperSessionDelegate)
        let persistedDefaults = String(describing: state.defaults.dictionaryRepresentation())
        XCTAssertFalse(persistedDefaults.contains(HelperTLSFixture.code))
        XCTAssertFalse(persistedDefaults.contains(HelperTLSFixture.token))
    }

    func testActualPairingWrongPinNeverSendsRedemptionCodeOrPersists() async throws {
        let fixture = try HelperTLSFixture(mode: .http, host: privateIPv4(), response: { _ in HelperTLSFixture.pairingResponse })
        let endpoint = try await fixture.start()
        defer { fixture.stop() }
        let state = PairingState()
        defer { state.cleanUp() }
        let original = state.configuration.snapshot()
        try confirm(state.coordinator, endpoint: endpoint, fingerprint: String(repeating: "0", count: 64))
        try await waitUntil { !state.coordinator.isPairing }
        XCTAssertEqual(state.coordinator.errorMessage, MobileHelperError.trustChanged.localizedDescription,
                       "Record the pin rejection before invalidation releases the session delegate")
        XCTAssertTrue(fixture.requests.isEmpty, "No redemption code or HTTP headers before pinned trust")
        XCTAssertEqual(fixture.receivedHTTPByteCount, 0, "Not even partial redemption HTTP body may arrive")
        assertUnselected(state, original: original)
    }

    func testActualAuthenticatedHealthWrongPinNeverSendsBearer() async throws {
        let fixture = try HelperTLSFixture(mode: .http, response: { _ in HelperTLSFixture.healthResponse() })
        let endpoint = try await fixture.start()
        defer { fixture.stop() }
        let pin = String(repeating: "0", count: 64)
        let credential = MobileHelperCredential(endpoint: endpoint, helperID: HelperTLSFixture.helperID,
            fingerprint: pin, name: "TLS fixture", deviceID: HelperTLSFixture.deviceID,
            token: HelperTLSFixture.token, capabilities: ["ollama"])
        let session = MobileHelperSessionDelegate.session(endpoint: endpoint, fingerprint: pin)
        defer { session.invalidateAndCancel() }
        do {
            try await MobileHelperPairingClient.verifyHealth(credential: credential, session: session)
            XCTFail("Wrong pin must fail before authenticated health")
        } catch {
            XCTAssertEqual(MobileHelperError.actionable(error, session: session) as? MobileHelperError, .trustChanged)
        }
        XCTAssertTrue(fixture.requests.isEmpty, "No authenticated HTTP request before pinned trust")
        XCTAssertEqual(fixture.receivedHTTPByteCount, 0, "Not even partial bearer HTTP headers may arrive")
    }

    func testActualPairingMismatchedHealthIdentityOrCapabilityNeverPersists() async throws {
        let host = try privateIPv4()
        for health in [HelperTLSFixture.healthResponse(helperID: UUID().uuidString),
                       HelperTLSFixture.healthResponse(capabilities: ["ollama", "account"])] {
            let fixture = try HelperTLSFixture(mode: .http, host: host, response: { request in
                request.hasPrefix("POST /v1/mobile/pair ") ? HelperTLSFixture.pairingResponse : health
            })
            let endpoint = try await fixture.start()
            defer { fixture.stop() }
            let state = PairingState()
            defer { state.cleanUp() }
            let original = state.configuration.snapshot()
            try confirm(state.coordinator, endpoint: endpoint, fingerprint: fixture.fingerprint)
            try await waitUntil { !state.coordinator.isPairing }
            XCTAssertNotNil(state.coordinator.errorMessage)
            assertPairAndHealthRequests(fixture.requests)
            assertUnselected(state, original: original)
        }
    }

    func testActualPairingAndHealthRedirectsNeverFollowOrPersist() async throws {
        let host = try privateIPv4()
        let target = try HelperTLSFixture(mode: .http, host: host, response: { _ in HelperTLSFixture.healthResponse() })
        let targetEndpoint = try await target.start()
        defer { target.stop() }
        // Include redemption -> health on the same origin and a second real TLS
        // listener. Neither an unverified redirect nor a second bearer is allowed.
        for redirectPair in [true, false] {
            for location in ["/v1/mobile/health", targetEndpoint.appendingPathComponent("v1/mobile/health").absoluteString] {
                let fixture = try HelperTLSFixture(mode: .http, host: host, response: { request in
                    if !redirectPair && request.hasPrefix("POST /v1/mobile/pair ") { return HelperTLSFixture.pairingResponse }
                    return .redirect(to: location)
                })
                let endpoint = try await fixture.start()
                defer { fixture.stop() }
                let state = PairingState()
                defer { state.cleanUp() }
                let original = state.configuration.snapshot()
                try confirm(state.coordinator, endpoint: endpoint, fingerprint: fixture.fingerprint)
                try await waitUntil { !state.coordinator.isPairing }
                XCTAssertEqual(state.coordinator.errorMessage, MobileHelperError.redirectRejected.localizedDescription)
                if redirectPair {
                    XCTAssertEqual(fixture.requests.count, 1, "Redemption redirect must not trigger health")
                    XCTAssertFalse(try XCTUnwrap(fixture.requests.first).contains("Authorization:"))
                } else {
                    assertPairAndHealthRequests(fixture.requests)
                }
                XCTAssertTrue(target.requests.isEmpty, "Cross-origin redirect must not reach second TLS listener")
                assertUnselected(state, original: original)
            }
        }
    }

    private func makePayload(endpoint: URL, fingerprint: String) -> MobileHelperPairingPayload {
        .init(endpoint: endpoint, helperID: HelperTLSFixture.helperID, fingerprint: fingerprint,
            code: HelperTLSFixture.code, name: "TLS fixture")
    }
    private func confirm(_ coordinator: MobileHelperPairingCoordinator, endpoint: URL, fingerprint: String) throws {
        let payload = makePayload(endpoint: endpoint, fingerprint: fingerprint)
        coordinator.handle(try payload.pairingURL())
        coordinator.confirm(payload, generation: coordinator.pendingGeneration, deviceName: "Fixture Phone")
    }
    private func assertPairAndHealthRequests(_ requests: [String], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(requests.count, 2, file: file, line: line)
        guard requests.count == 2 else { return }
        XCTAssertTrue(requests[0].hasPrefix("POST /v1/mobile/pair "), file: file, line: line)
        XCTAssertFalse(requests[0].contains("Authorization:"), file: file, line: line)
        let body = requests[0].components(separatedBy: "\r\n\r\n").last ?? ""
        do {
            let redemption = try JSONDecoder().decode(MobileHelperPairingRequest.self, from: Data(body.utf8))
            XCTAssertEqual(redemption.code, HelperTLSFixture.code, file: file, line: line)
            XCTAssertEqual(redemption.name, "Fixture Phone", file: file, line: line)
        } catch { XCTFail("Invalid redemption body: \(error)", file: file, line: line) }
        XCTAssertTrue(requests[1].hasPrefix("GET /v1/mobile/health "), file: file, line: line)
        XCTAssertTrue(requests[1].contains("Authorization: Bearer " + HelperTLSFixture.token), file: file, line: line)
        XCTAssertFalse(requests[1].contains(HelperTLSFixture.code), file: file, line: line)
    }
    private func assertUnselected(_ state: PairingState, original: OllamaEndpointConfiguration.Snapshot,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(state.store.records.isEmpty, file: file, line: line)
        XCTAssertEqual(state.configuration.snapshot(), original, file: file, line: line)
        XCTAssertNil(state.defaults.string(forKey: OllamaEndpointConfiguration.helperSelectionKey), file: file, line: line)
        XCTAssertEqual(state.selectionCount, 0, file: file, line: line)
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            if Date() >= deadline { throw URLError(.timedOut) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    private func privateIPv4() throws -> String {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { throw POSIXError(.ENXIO) }
        defer { freeifaddrs(interfaces) }
        var cursor = interfaces
        while let interface = cursor {
            defer { cursor = interface.pointee.ifa_next }
            guard let address = interface.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  interface.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  interface.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let host = String(cString: buffer)
            if MobileHelperPairingPayload.isPrivateIPv4(host) { return host }
        }
        throw XCTSkip("Real pairing TLS requires a local private IPv4; production validation is not bypassed")
    }

    @MainActor
    private final class PairingState {
        let suite = "MobileHelperTLSPairingTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let store = TLSFixtureCredentialStore()
        let configuration: OllamaEndpointConfiguration
        private(set) var selectionCount = 0
        lazy var coordinator = MobileHelperPairingCoordinator(configuration: configuration,
            client: MobileHelperPairingClient(), didSelect: { [weak self] in self?.selectionCount += 1 })
        init() {
            defaults = UserDefaults(suiteName: suite)!
            configuration = OllamaEndpointConfiguration(userDefaults: defaults, credentialStore: store)
        }
        func cleanUp() {
            coordinator.cancel()
            configuration.snapshot().helper?.session.invalidateAndCancel()
            defaults.removePersistentDomain(forName: suite)
        }
    }
}

/// In-memory persistence spy only; networking uses the unmodified production
/// client/delegate. No Keychain reads/writes or trust installation in these tests.
private final class TLSFixtureCredentialStore: MobileHelperCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var credentials: [String: MobileHelperCredential] = [:]
    var records: [String: MobileHelperCredential] { lock.lock(); defer { lock.unlock() }; return credentials }
    func load(helperID: String) throws -> MobileHelperCredential? {
        lock.lock(); defer { lock.unlock() }; return credentials[helperID]
    }
    func save(_ credential: MobileHelperCredential) throws {
        try credential.validate()
        lock.lock(); defer { lock.unlock() }; credentials[credential.helperID] = credential
    }
    func remove(helperID: String) throws {
        lock.lock(); defer { lock.unlock() }; credentials.removeValue(forKey: helperID)
    }
}

private actor TLSFixtureToolTracker {
    private(set) var count = 0
    func called() { count += 1 }
}

private final class HelperTLSFixture: @unchecked Sendable {
    enum Mode { case stream, redirect, cleanEOF, cleanEOFToolCall, http }
    struct Response {
        var status = 200
        var body: String
        var location: String? = nil
        var held = false
        static func redirect(to location: String) -> Self { .init(status: 307, body: "", location: location) }
    }
    static let helperID = "11111111-1111-4111-8111-111111111111"
    static let deviceID = "22222222-2222-4222-8222-222222222222"
    static let code = String(repeating: "b", count: 64)
    static let token = String(repeating: "c", count: 64)
    static var pairingResponse: Response {
        .init(body: #"{"version":1,"helperID":"\#(helperID)","deviceID":"\#(deviceID)","token":"\#(token)","capabilities":["ollama"]}"#)
    }
    static func healthResponse(helperID: String = helperID, capabilities: [String] = ["ollama"], held: Bool = false) -> Response {
        let capabilitiesJSON = capabilities.map { "\"\($0)\"" }.joined(separator: ",")
        return .init(body: #"{"version":1,"helperID":"\#(helperID)","capabilities":[\#(capabilitiesJSON)]}"#, held: held)
    }
    let fingerprint: String
    private let listener: NWListener
    private let mode: Mode
    private let host: String
    private let response: ((String) -> Response)?
    private var heldResponses: [(NWConnection, Response)] = []
    private let queue = DispatchQueue(label: "app.helper.tls.fixture")
    private let lock = NSLock()
    private var recordedRequests: [String] = []
    private var httpByteCount = 0
    private var connections: [NWConnection] = []
    var requests: [String] { lock.lock(); defer { lock.unlock() }; return recordedRequests }
    var receivedHTTPByteCount: Int { lock.lock(); defer { lock.unlock() }; return httpByteCount }

    init(mode: Mode, host: String = "127.0.0.1", response: ((String) -> Response)? = nil) throws {
        self.mode = mode
        self.host = host
        self.response = response
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
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: .any)
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
                    continuation.resume(returning: URL(string: "https://\(self.host):\(port.rawValue)")!)
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
            heldResponses = []
        }
    }
    func releaseResponses() {
        queue.sync {
            for (connection, response) in heldResponses { send(response, on: connection) }
            heldResponses = []
        }
    }
    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] chunk, _, done, error in
            guard let self else { return }
            var accumulated = data
            if let chunk {
                accumulated.append(chunk)
                self.lock.lock(); self.httpByteCount += chunk.count; self.lock.unlock()
            }
            guard accumulated.count <= 65_536, error == nil else { connection.cancel(); return }
            if let boundary = accumulated.range(of: Data("\r\n\r\n".utf8)),
               let headers = String(data: accumulated[..<boundary.lowerBound], encoding: .utf8) {
                // Read the entire HTTP body so wrong-pin assertions cover the
                // redemption code, not just receipt of the request headers.
                let length = headers.components(separatedBy: "\r\n").first {
                    $0.lowercased().hasPrefix("content-length:")
                }.flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                guard accumulated.count >= boundary.upperBound + length else {
                    if !done { self.receive(connection, data: accumulated) } else { connection.cancel() }
                    return
                }
                let request = String(decoding: accumulated, as: UTF8.self)
                self.lock.lock(); self.recordedRequests.append(request); self.lock.unlock()
                self.respond(connection, request: request)
            } else if !done {
                self.receive(connection, data: accumulated)
            } else { connection.cancel() }
        }
    }
    private func send(_ response: Response, on connection: NWConnection) {
        let location = response.location.map { "Location: \($0)\r\n" } ?? ""
        let message = "HTTP/1.1 \(response.status) Fixture\r\n\(location)Content-Type: application/json\r\nContent-Length: \(response.body.utf8.count)\r\nConnection: close\r\n\r\n\(response.body)"
        connection.send(content: Data(message.utf8), contentContext: .finalMessage, isComplete: true,
            completion: .contentProcessed { _ in connection.cancel() })
    }
    private func respond(_ connection: NWConnection, request: String) {
        if mode == .http, let response {
            let result = response(request)
            if result.held { heldResponses.append((connection, result)) }
            else { send(result, on: connection) }
            return
        }
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
