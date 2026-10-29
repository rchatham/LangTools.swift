import Agents
import Foundation
import HelperLink
import KeychainAccess
import LangTools
import Ollama
import XCTest
@testable import Chat

/// Synthetic helper credentials and URLProtocol-gated responses make helper
/// release and selection races deterministic. The NetworkClient integration
/// test additionally constructs UUID-scoped Keychain readers and requires the
/// guarded host harness; a unique service name alone does not provide isolation.
@MainActor
final class MobileHelperSessionLifetimeTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var store: LifetimeCredentialStore!
    private var configuration: OllamaEndpointConfiguration!
    private let helperID = "11111111-1111-4111-8111-111111111111"

    override func setUp() {
        super.setUp()
        suite = "MobileHelperSessionLifetimeTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        store = LifetimeCredentialStore()
        configuration = OllamaEndpointConfiguration(userDefaults: defaults, credentialStore: store)
        LifetimeURLProtocol.reset()
    }

    override func tearDown() {
        configuration = nil
        defaults.removePersistentDomain(forName: suite)
        LifetimeURLProtocol.reset()
        super.tearDown()
    }

    func testStaleSuccessfulPairingRetiresSessionAndDelegateWithoutPersisting() async throws {
        let probe = RetirementProbe()
        let coordinator = coordinator(probe: probe)
        try confirm(coordinator)
        try await waitUntil { LifetimeURLProtocol.hasPendingResponse }
        _ = try configuration.update("https://new.local:11434")
        LifetimeURLProtocol.releaseResponse()
        try await waitUntil { !coordinator.isPairing }
        XCTAssertNil(coordinator.errorMessage)
        XCTAssertEqual(store.saveCount, 0)
        XCTAssertFalse(configuration.snapshot().isHelper)
        try await assertRetired(probe)
    }

    func testFailedPersistenceOfSuccessfulPairingRetiresSessionAndDelegate() async throws {
        store.failSave = true
        let probe = RetirementProbe()
        let coordinator = coordinator(probe: probe)
        try confirm(coordinator)
        try await waitUntil { LifetimeURLProtocol.hasPendingResponse }
        LifetimeURLProtocol.releaseResponse()
        try await waitUntil { !coordinator.isPairing }
        XCTAssertEqual(store.saveCount, 1)
        XCTAssertNotNil(coordinator.errorMessage)
        XCTAssertFalse(configuration.snapshot().isHelper)
        try await assertRetired(probe)
    }

    func testRepeatedSuccessfulPairingReplacementAndDisconnectRetireEverySession() async throws {
        var previous: RetirementProbe?
        for _ in 0..<4 {
            let probe = RetirementProbe()
            let coordinator = coordinator(probe: probe)
            try confirm(coordinator)
            try await waitUntil { LifetimeURLProtocol.hasPendingResponse }
            LifetimeURLProtocol.releaseResponse()
            try await waitUntil { !coordinator.isPairing }
            XCTAssertNil(coordinator.errorMessage)
            XCTAssertNotNil(probe.session)
            XCTAssertNotNil(probe.delegate)
            if let previous { try await assertRetired(previous) }
            previous = probe
        }
        XCTAssertEqual(store.saveCount, 4)
        try configuration.disconnectHelper()
        try await assertRetired(try XCTUnwrap(previous))
        XCTAssertTrue(configuration.snapshot().isHelper, "Disconnect stays fail-closed")
    }

    func testCapturedSnapshotProviderAndAgentRetainSessionAcrossReplacementAndDisconnect() async throws {
        let probe = RetirementProbe()
        try selectConnection(probe: probe)
        var snapshot: OllamaEndpointConfiguration.Snapshot? = configuration.snapshot()
        var provider: Ollama? = try snapshot?.provider(directSession: .shared)
        var context: AgentContext? = try snapshot?.makeAgentContext(
            model: .init(rawValue: "fixture-model")!, messages: [], eventHandler: { _ in })
        let replacement = RetirementProbe()
        try selectConnection(probe: replacement)
        try configuration.disconnectHelper()
        try await assertRetired(replacement)
        XCTAssertNotNil(probe.session)
        snapshot = nil
        provider = nil
        XCTAssertNil(context?.langTool as? Ollama)
        XCTAssertTrue(context?.langTool.session === probe.session)
        let capturedRequest = try context?.langTool.prepare(request: Ollama.ChatRequest(model: .init(rawValue: "fixture-model")!, messages: []))
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer \(credential().token)")
        context = nil
        try await assertRetired(probe)
    }

    // NetworkClient initialization reads credentials. Run this regression only
    // under the guarded host harness, like NetworkClientAuthTests.
    func testNetworkClientAgentRetainsCapturedHelperUntilContextRelease() async throws {
        let probe = RetirementProbe()
        try selectConnection(probe: probe)
        // Read-only fixture: do not seed credentials or add a real-store cleanup
        // mutation. Future credential-writing setup requires a memory-store seam
        // or a separately reviewed guarded lifecycle, not UUID-only isolation.
        let keychain = Keychain(service: "MobileHelperSessionLifetimeTests.\(UUID().uuidString)")
        let keychainService = KeychainService(keychain: keychain)
        let access = ProviderAccessManager(
            keychainService: keychainService,
            sessionStore: AuthSessionStore(keychain: keychain),
            ollamaEndpointConfiguration: configuration,
            ollamaCloudModelStore: OllamaCloudModelStore(userDefaults: defaults),
            ollamaCloudAccessEligibility: { false }
        )
        var client: NetworkClient? = NetworkClient(
            keychainService: keychainService,
            providerAccessManager: access,
            ollamaEndpointConfiguration: configuration
        )
        let model = try XCTUnwrap(Ollama.Model(rawValue: "fixture-model"))
        var context: AgentContext? = try client?.agentContext(
            messages: [], model: .ollama(model), eventHandler: { _ in })
        XCTAssertNotNil(context)
        client = nil
        let replacement = RetirementProbe()
        try selectConnection(probe: replacement)
        try configuration.disconnectHelper()
        try await assertRetired(replacement)

        XCTAssertNil(context?.langTool as? Ollama)
        XCTAssertNotNil(probe.session)
        XCTAssertTrue(context?.langTool.session === probe.session)
        let request = try context?.langTool.prepare(request: Ollama.ChatRequest(model: model, messages: []))
        XCTAssertEqual(request?.url?.path, "/v1/ollama/api/chat")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer \(credential().token)")
        context = nil
        try await assertRetired(probe)
    }

    func testCapturedToolchainRetainsHelperLeaseUntilCapabilityReleased() async throws {
        let probe = RetirementProbe()
        try selectConnection(probe: probe)
        var toolchain: LangToolchain? = try configuration.snapshot().makeToolchain()
        try configuration.disconnectHelper()
        XCTAssertNotNil(probe.session)
        XCTAssertNotNil(probe.delegate)
        let request = try toolchain?.prepare(request: Ollama.ChatRequest(model: .init(rawValue: "fixture-model")!, messages: [], stream: false))
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer \(credential().token)")
        XCTAssertEqual(request?.url?.path, "/v1/ollama/api/chat")
        toolchain = nil
        try await assertRetired(probe)
    }

    func testCapturedToolchainDataOperationSurvivesDisconnectAndCapabilityRelease() async throws {
        let probe = RetirementProbe()
        try selectConnection(probe: probe)
        var toolchain: LangToolchain? = try configuration.snapshot().makeToolchain()
        let task = Task { [captured = try XCTUnwrap(toolchain)] in
            try await captured.perform(request: Ollama.ChatRequest(model: .init(rawValue: "fixture-model")!, messages: [], stream: false))
        }
        try await waitUntil { LifetimeURLProtocol.hasPendingResponse }
        try configuration.disconnectHelper()
        toolchain = nil
        XCTAssertNotNil(probe.session)
        XCTAssertNotNil(probe.delegate)
        LifetimeURLProtocol.releaseResponse()
        let response = try await task.value
        XCTAssertEqual(response.message?.content.text, "hello")
        try await assertRetired(probe)
    }

    func testCapturedProviderRemainsUsableThenRetiresAfterFinalRelease() async throws {
        let probe = RetirementProbe()
        try selectConnection(probe: probe)
        var provider: Ollama? = try configuration.snapshot().provider(directSession: .shared)
        configuration.useDirect()
        XCTAssertNotNil(probe.delegate)
        let task = Task { [captured = provider!] in try await captured.listModels() }
        try await waitUntil { LifetimeURLProtocol.hasPendingResponse }
        LifetimeURLProtocol.releaseResponse()
        let result = try await task.value
        XCTAssertTrue(result.models.isEmpty)
        XCTAssertNotNil(probe.session)
        provider = nil
        try await assertRetired(probe)
    }

    func testUnconsumedNonstreamingStreamRetainsSessionBeforeFirstIteration() async throws {
        let probe = RetirementProbe()
        try selectConnection(probe: probe)
        var provider: Ollama? = try configuration.snapshot().provider(directSession: .shared)
        let stream = provider!.stream(request: Ollama.ChatRequest(model: .init(rawValue: "fixture-model")!, messages: [], stream: false))
        // LangTools.stream starts its producer Task immediately. Leave the
        // stream unconsumed while suspending until its request reaches the gate.
        await Task.yield()
        try await waitUntil { LifetimeURLProtocol.hasPendingResponse }
        provider = nil
        try configuration.disconnectHelper()
        XCTAssertNotNil(probe.session)
        XCTAssertNotNil(probe.delegate)
        let consuming = Task { () throws -> String in
            var content = ""
            for try await response in stream { content += response.message?.content.text ?? "" }
            return content
        }
        try await waitUntil { LifetimeURLProtocol.hasPendingResponse }
        LifetimeURLProtocol.releaseResponse()
        let content = try await consuming.value
        XCTAssertEqual(content, "hello")
        // Producer completion releases the captured provider, even while this
        // completed stream value remains in scope.
        try await assertRetired(probe)
    }

    func testActiveDataRequestSurvivesDisconnectAndProviderRelease() async throws {
        let probe = RetirementProbe()
        try selectConnection(probe: probe)
        var provider: Ollama? = try configuration.snapshot().provider(directSession: .shared)
        let request = Task { [captured = provider!] in try await captured.listModels() }
        try await waitUntil { LifetimeURLProtocol.hasPendingResponse }
        try configuration.disconnectHelper()
        provider = nil
        XCTAssertNotNil(probe.session)
        XCTAssertNotNil(probe.delegate)
        LifetimeURLProtocol.releaseResponse()
        let result = try await request.value
        XCTAssertTrue(result.models.isEmpty)
        try await assertRetired(probe)
    }

    private func coordinator(probe: RetirementProbe) -> MobileHelperPairingCoordinator {
        let client = MobileHelperPairingClient(sessionFactory: { _, _ in probe.makeSession() })
        return MobileHelperPairingCoordinator(configuration: configuration, client: client, didSelect: {})
    }

    private func confirm(_ coordinator: MobileHelperPairingCoordinator) throws {
        let payload = MobileHelperPairingPayload(version: 1, endpoint: credential().endpoint,
            helperID: helperID, fingerprint: credential().fingerprint,
            code: String(repeating: "b", count: 64), name: "Fixture Mac")
        coordinator.handle(try payload.pairingURL())
        coordinator.confirm(payload, generation: coordinator.pendingGeneration, deviceName: "Fixture Phone")
    }

    private func credential() -> MobileHelperCredential {
        MobileHelperCredential(endpoint: URL(string: "https://192.168.1.10:8086")!, helperID: helperID,
            fingerprint: String(repeating: "a", count: 64), name: "Fixture Mac",
            deviceID: "22222222-2222-4222-8222-222222222222", token: String(repeating: "c", count: 64), capabilities: ["ollama"])
    }

    private func selectConnection(probe: RetirementProbe) throws {
        try configuration.selectHelper(MobileHelperConnection(credential: credential(), session: probe.makeSession()))
    }

    private func assertRetired(_ probe: RetirementProbe, file: StaticString = #filePath, line: UInt = #line) async throws {
        await fulfillment(of: [probe.invalidated], timeout: 3)
        try await waitUntil { probe.session == nil && probe.delegate == nil }
        XCTAssertNil(probe.session, file: file, line: line)
        XCTAssertNil(probe.delegate, file: file, line: line)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            if Date() >= deadline { throw URLError(.timedOut) }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

private final class LifetimeCredentialStore: MobileHelperCredentialStoring, @unchecked Sendable {
    var failSave = false
    var saveCount = 0
    func load(helperID: String) throws -> MobileHelperCredential? { nil }
    func save(_ credential: MobileHelperCredential) throws {
        saveCount += 1
        if failSave { throw MobileHelperError.persistence("fixture save failure") }
    }
    func remove(helperID: String) throws {}
}

private final class RetirementProbe {
    weak var session: URLSession?
    weak var delegate: RetirementDelegate?
    let invalidated = XCTestExpectation(description: "Session invalidated")

    func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LifetimeURLProtocol.self]
        let delegate = RetirementDelegate(invalidated: invalidated)
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        self.session = session
        self.delegate = delegate
        return session
    }
}

private final class RetirementDelegate: NSObject, URLSessionDelegate {
    let invalidated: XCTestExpectation
    init(invalidated: XCTestExpectation) { self.invalidated = invalidated }
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) { invalidated.fulfill() }
}

private final class LifetimeURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var pendingResponse: (() -> Void)?
    static var hasPendingResponse: Bool {
        lock.lock(); defer { lock.unlock() }; return pendingResponse != nil
    }
    static func reset() { lock.lock(); defer { lock.unlock() }; pendingResponse = nil }
    static func releaseResponse() {
        lock.lock(); let response = pendingResponse; pendingResponse = nil; lock.unlock()
        response?()
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body: String
        switch request.url?.path {
        case "/v1/mobile/pair":
            body = #"{"version":1,"helperID":"11111111-1111-4111-8111-111111111111","deviceID":"22222222-2222-4222-8222-222222222222","token":"\#(String(repeating: "c", count: 64))","capabilities":["ollama"]}"#
        case "/v1/mobile/health":
            body = #"{"version":1,"helperID":"11111111-1111-4111-8111-111111111111","capabilities":["ollama"]}"#
        case "/v1/ollama/api/tags": body = #"{"models":[]}"#
        case "/v1/ollama/api/chat":
            body = #"{"model":"fixture-model","created_at":"2026-10-07T00:00:00Z","message":{"role":"assistant","content":"hello"},"done":true}"#
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let respond = { [self] in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        if request.url?.path == "/v1/mobile/pair" { respond() }
        else { Self.lock.lock(); Self.pendingResponse = respond; Self.lock.unlock() }
    }
    override func stopLoading() {}
}
