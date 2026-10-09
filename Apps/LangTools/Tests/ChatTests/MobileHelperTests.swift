import CryptoKit
import Foundation
import HelperLink
import KeychainAccess
import Security
import XCTest
@testable import Chat

@MainActor
final class MobileHelperTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var store: MemoryHelperStore!
    private var configuration: OllamaEndpointConfiguration!
    private var session: URLSession!
    private let helperID = "11111111-1111-4111-8111-111111111111"
    private let deviceID = "22222222-2222-4222-8222-222222222222"

    override func setUp() {
        super.setUp()
        suite = "MobileHelperTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        store = MemoryHelperStore()
        configuration = OllamaEndpointConfiguration(userDefaults: defaults, credentialStore: store)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HelperPairingTestProtocol.self]
        session = URLSession(configuration: config)
        HelperPairingTestProtocol.reset()
    }
    override func tearDown() {
        session.invalidateAndCancel()
        defaults.removePersistentDomain(forName: suite)
        HelperPairingTestProtocol.reset()
        super.tearDown()
    }

    func testNewPairingURLIsStrictAndSeparateFromLegacyCodex() throws {
        let url = try payload().pairingURL()
        XCTAssertTrue(MobileHelperPairingCoordinator.isPairingURL(url))
        XCTAssertFalse(CodexHelperPairingCoordinator.isPairingURL(url))
        XCTAssertEqual(try MobileHelperPairingPayload.parse(url), payload())
        for suffix in ["&code=duplicate", "&unknown=1"] {
            XCTAssertThrowsError(try MobileHelperPairingPayload.parse(URL(string: url.absoluteString + suffix)!))
        }
        for endpoint in ["http://192.168.1.10:8086", "https://127.0.0.1:8086", "https://8.8.8.8:8086", "https://mac.local:8086"] {
            let invalid = MobileHelperPairingPayload(version: 1, endpoint: URL(string: endpoint)!, helperID: helperID,
                fingerprint: String(repeating: "a", count: 64), code: String(repeating: "b", count: 64), name: "Mac")
            XCTAssertThrowsError(try invalid.pairingURL())
        }
    }

    func testConfirmationHealthThenPersistenceAndReconnect() async throws {
        installSuccessfulResponses()
        let coordinator = makeCoordinator()
        let original = configuration.snapshot()
        coordinator.handle(try payload().pairingURL())
        XCTAssertEqual(configuration.snapshot(), original)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertTrue(HelperPairingTestProtocol.requests.isEmpty)
        coordinator.confirm(deviceName: "Test Phone")
        try await waitUntil { !coordinator.isPairing }
        XCTAssertNil(coordinator.errorMessage)
        XCTAssertEqual(configuration.snapshot().helperID, helperID)
        XCTAssertEqual(configuration.snapshot().baseURL.path, "/v1/ollama")
        XCTAssertEqual(store.records.count, 1)
        let requests = HelperPairingTestProtocol.requests
        XCTAssertEqual(requests.map { $0.url!.path }, ["/v1/mobile/pair", "/v1/mobile/health"])
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer " + String(repeating: "c", count: 64))
        let encodedDefaults = String(describing: defaults.dictionaryRepresentation())
        XCTAssertFalse(encodedDefaults.contains(String(repeating: "b", count: 64)))
        XCTAssertFalse(encodedDefaults.contains(String(repeating: "c", count: 64)))
        let restored = OllamaEndpointConfiguration(userDefaults: defaults, credentialStore: store)
        XCTAssertEqual(restored.snapshot().helperID, helperID)
        XCTAssertEqual(try restored.snapshot().provider(directSession: .shared).configuration.apiKey, String(repeating: "c", count: 64))
        XCTAssertTrue(restored.snapshot().helper?.session.delegate is MobileHelperSessionDelegate)
    }

    func testWrongHealthIdentityNeverPersistsOrChangesTransport() async throws {
        installSuccessfulResponses(healthHelperID: UUID().uuidString)
        let original = configuration.snapshot()
        let coordinator = makeCoordinator()
        coordinator.handle(try payload().pairingURL())
        coordinator.confirm(deviceName: "Phone")
        try await waitUntil { !coordinator.isPairing }
        XCTAssertNotNil(coordinator.errorMessage)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertEqual(configuration.snapshot(), original)
    }

    func testWrongCapabilityMalformedTokenOrWrongExchangeIdentityNeverPersists() async throws {
        for response in [
            #"{"version":1,"helperID":"\#(helperID)","deviceID":"\#(deviceID)","token":"short","capabilities":["ollama"]}"#,
            #"{"version":1,"helperID":"\#(helperID)","deviceID":"\#(deviceID)","token":"\#(String(repeating: "c", count: 64))","capabilities":["ollama","account"]}"#,
            #"{"version":1,"helperID":"33333333-3333-4333-8333-333333333333","deviceID":"\#(deviceID)","token":"\#(String(repeating: "c", count: 64))","capabilities":["ollama"]}"#
        ] {
            HelperPairingTestProtocol.handler = { _ in (200, Data(response.utf8), 0) }
            let coordinator = makeCoordinator()
            coordinator.handle(try payload().pairingURL())
            coordinator.confirm(deviceName: "Phone")
            try await waitUntil { !coordinator.isPairing }
            XCTAssertNotNil(coordinator.errorMessage)
            XCTAssertTrue(store.records.isEmpty)
            XCTAssertFalse(configuration.snapshot().isHelper)
        }
    }

    func testRejectedHealthOrRedirectNeverPersists() async throws {
        for code in [302, 401, 403] {
            installSuccessfulResponses(healthStatus: code)
            let coordinator = makeCoordinator()
            coordinator.handle(try payload().pairingURL())
            coordinator.confirm(deviceName: "Phone")
            try await waitUntil { !coordinator.isPairing }
            XCTAssertNotNil(coordinator.errorMessage)
            XCTAssertTrue(store.records.isEmpty)
            XCTAssertFalse(configuration.snapshot().isHelper)
        }
    }

    func testCancelAndTransportChangeDuringPairingRejectLateSelection() async throws {
        installSuccessfulResponses(delay: 0.1)
        let coordinator = makeCoordinator()
        coordinator.handle(try payload().pairingURL())
        coordinator.confirm(deviceName: "Phone")
        try await waitUntil { !HelperPairingTestProtocol.requests.isEmpty }
        coordinator.cancel()
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertFalse(configuration.snapshot().isHelper)
        HelperPairingTestProtocol.reset()
        installSuccessfulResponses(delay: 0.1)
        coordinator.handle(try payload().pairingURL())
        coordinator.confirm(deviceName: "Phone")
        _ = try configuration.update("http://new.local:11434")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertFalse(configuration.snapshot().isHelper)
        XCTAssertFalse(coordinator.isPairing)
    }

    func testCredentialWriteFailureNeverChangesSelection() async throws {
        store.failWrites = true
        installSuccessfulResponses()
        let coordinator = makeCoordinator()
        coordinator.handle(try payload().pairingURL())
        coordinator.confirm(deviceName: "Phone")
        try await waitUntil { !coordinator.isPairing }
        XCTAssertNotNil(coordinator.errorMessage)
        XCTAssertFalse(configuration.snapshot().isHelper)
    }

    func testCacheIdentityAndRevisionRejectStaleAToBToA() throws {
        let a = MobileHelperConnection(credential: credential())
        let b = MobileHelperConnection(credential: credential(helperID: "33333333-3333-4333-8333-333333333333"))
        try configuration.selectHelper(a)
        let oldA = configuration.snapshot()
        XCTAssertTrue(configuration.storeModels([.init(rawValue: "a-model")!], for: oldA))
        try configuration.selectHelper(b)
        XCTAssertTrue(configuration.cachedModels().isEmpty)
        let oldB = configuration.snapshot()
        try configuration.selectHelper(a)
        let newA = configuration.snapshot()
        XCTAssertNotEqual(oldA.revision, newA.revision)
        XCTAssertFalse(configuration.storeModels([.init(rawValue: "stale")!], for: oldA))
        XCTAssertFalse(configuration.storeModels([.init(rawValue: "b")!], for: oldB))
        XCTAssertEqual(configuration.cachedModels().map(\.rawValue), ["a-model"])
        configuration.useDirect()
        XCTAssertTrue(configuration.cachedModels().isEmpty)
        XCTAssertFalse(configuration.storeModels([.init(rawValue: "stale")!], for: newA))
    }

    func testDisconnectAndMissingOrUnreadableCredentialFailClosedUntilExplicitDirect() throws {
        try configuration.selectHelper(MobileHelperConnection(credential: credential()))
        let captured = configuration.snapshot()
        try configuration.disconnectHelper()
        XCTAssertTrue(configuration.snapshot().isHelper)
        XCTAssertTrue(configuration.cachedModels().isEmpty)
        XCTAssertThrowsError(try configuration.snapshot().provider(directSession: .shared))
        XCTAssertEqual(try captured.provider(directSession: .shared).configuration.apiKey, credential().token)
        let restored = OllamaEndpointConfiguration(userDefaults: defaults, credentialStore: store)
        XCTAssertTrue(restored.snapshot().isHelper)
        XCTAssertThrowsError(try restored.snapshot().provider(directSession: .shared))
        store.failReads = true
        let unreadable = OllamaEndpointConfiguration(userDefaults: defaults, credentialStore: store)
        XCTAssertTrue(unreadable.snapshot().isHelper)
        XCTAssertThrowsError(try unreadable.snapshot().provider(directSession: .shared))
        unreadable.useDirect()
        XCTAssertFalse(unreadable.snapshot().isHelper)
        XCTAssertNil(try unreadable.snapshot().provider(directSession: .shared).configuration.apiKey)
    }

    func testRealKeychainRoundtripRejectsInvalidRecord() throws {
        let keychain = Keychain(service: suite + ".keychain").accessibility(.afterFirstUnlockThisDeviceOnly)
        defer { try? keychain.removeAll() }
        let store = MobileHelperCredentialStore(keychain: keychain)
        let saved = credential()
        try store.save(saved)
        XCTAssertEqual(try store.load(helperID: helperID), saved)
        XCTAssertFalse(saved.description.contains(saved.token))
        let bad = credential(token: "invalid")
        XCTAssertThrowsError(try store.save(bad))
        try keychain.set(JSONEncoder().encode(bad), key: helperID)
        XCTAssertThrowsError(try store.load(helperID: helperID))
        try store.remove(helperID: helperID)
        XCTAssertNil(try store.load(helperID: helperID))
    }

    func testCredentialValidationAcceptsGrantedSetsAndRejectsInvalidOnes() throws {
        let keychain = Keychain(service: suite + ".keychain").accessibility(.afterFirstUnlockThisDeviceOnly)
        defer { try? keychain.removeAll() }
        let store = MobileHelperCredentialStore(keychain: keychain)
        let granted = credential(capabilities: ["claude", "codex", "ollama"])
        try store.save(granted)
        XCTAssertEqual(try store.load(helperID: helperID), granted)
        for invalid in [["ollama", "account"], ["ollama", "ollama"], ["ollama", "claude"], [String]()] {
            XCTAssertThrowsError(try store.save(credential(capabilities: invalid)), "\(invalid)")
        }
    }

    func testV1ImplicitScopeRejectsCapabilityExpansion() async throws {
        let granted = ["claude", "codex", "ollama"]
        let pair = MobileHelperPairingResponse(version: 1, helperID: helperID, deviceID: deviceID,
            token: String(repeating: "c", count: 64), capabilities: granted)
        let health = MobileHelperHealthResponse(version: 1, helperID: helperID, capabilities: granted)
        HelperPairingTestProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/mobile/pair": return (200, try JSONEncoder().encode(pair), 0)
            case "/v1/mobile/health": return (200, try JSONEncoder().encode(health), 0)
            default: throw URLError(.unsupportedURL)
            }
        }
        let coordinator = makeCoordinator()
        coordinator.handle(try payload().pairingURL())
        coordinator.confirm(deviceName: "Test Phone")
        try await waitUntil { !coordinator.isPairing }
        XCTAssertNotNil(coordinator.errorMessage)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertFalse(configuration.snapshot().isHelper)
        XCTAssertEqual(HelperPairingTestProtocol.requests.map { $0.url!.path }, ["/v1/mobile/pair"])
    }

    func testPinnedTrustValidatesExactLeafAndCertificateTimeNotLANHostname() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "valid", withExtension: "der", subdirectory: "HelperCertificates"))
        let data = try Data(contentsOf: url)
        let cert = try XCTUnwrap(SecCertificateCreateWithData(nil, data as CFData))
        let pin = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        func trust(at date: String) throws -> SecTrust {
            var trust: SecTrust?
            XCTAssertEqual(SecTrustCreateWithCertificates(cert, SecPolicyCreateSSL(true, "192.168.1.200" as CFString), &trust), errSecSuccess)
            let value = try XCTUnwrap(trust)
            SecTrustSetVerifyDate(value, ISO8601DateFormatter().date(from: date)! as CFDate)
            return value
        }
        XCTAssertTrue(MobileHelperSessionDelegate.validate(trust: try trust(at: "2027-01-01T00:00:00Z"), fingerprint: pin))
        XCTAssertFalse(MobileHelperSessionDelegate.validate(trust: try trust(at: "2027-01-01T00:00:00Z"), fingerprint: String(repeating: "0", count: 64)))
        XCTAssertFalse(MobileHelperSessionDelegate.validate(trust: try trust(at: "2040-01-01T00:00:00Z"), fingerprint: pin))
        XCTAssertFalse(MobileHelperSessionDelegate.validate(trust: try trust(at: "2020-01-01T00:00:00Z"), fingerprint: pin))
    }

    func testRedirectDelegateRejectsSameAndDifferentOriginEvenWithBearer() {
        let endpoint = payload().endpoint
        let delegate = MobileHelperSessionDelegate(fingerprint: payload().fingerprint, origin: endpoint)
        let response = HTTPURLResponse(url: endpoint, statusCode: 302, httpVersion: nil, headerFields: [:])!
        for target in [endpoint.appendingPathComponent("other"), URL(string: "https://other.example/")!] {
            var request = URLRequest(url: target)
            request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
            var called = false
            delegate.urlSession(session, task: session.dataTask(with: endpoint), willPerformHTTPRedirection: response,
                newRequest: request) { result in called = true; XCTAssertNil(result) }
            XCTAssertTrue(called)
        }
    }

    func testSettingsInitDoesNotStartNetworkAndStatusUsesVerifiedHelper() async throws {
        let credential = credential()
        try configuration.selectHelper(MobileHelperConnection(credential: credential, session: session))
        let isolatedKeychain = Keychain(service: suite + ".status")
        let accessManager = ProviderAccessManager(keychainService: KeychainService(keychain: isolatedKeychain),
            sessionStore: AuthSessionStore(keychain: isolatedKeychain), ollamaEndpointConfiguration: configuration)
        let service = OllamaService(endpointConfiguration: configuration, session: .shared, providerAccessManager: accessManager)
        let viewModel = OllamaSettingsView.ViewModel(ollamaService: service)
        XCTAssertTrue(HelperPairingTestProtocol.requests.isEmpty)
        XCTAssertEqual(viewModel.helperName, "Test Mac")
        installSuccessfulResponses()
        viewModel.checkConnection()
        try await waitUntil { !viewModel.isCheckingConnection }
        XCTAssertTrue(viewModel.isConnected)
        XCTAssertNil(viewModel.connectionError)
        try configuration.disconnectHelper()
        viewModel.transportDidChange()
        try await waitUntil { !viewModel.isCheckingConnection }
        XCTAssertFalse(viewModel.isConnected)
        XCTAssertNotNil(viewModel.connectionError)
        XCTAssertEqual(viewModel.helperName, "Test Mac")
    }

    func testConfirmationIsBoundToDisplayedPayloadAndGeneration() throws {
        let coordinator = makeCoordinator()
        let displayedA = payload()
        coordinator.handle(try displayedA.pairingURL())
        let displayedGeneration = coordinator.pendingGeneration
        let incomingB = MobileHelperPairingPayload(version: 1, endpoint: displayedA.endpoint,
            helperID: UUID().uuidString, fingerprint: displayedA.fingerprint,
            code: String(repeating: "d", count: 64), name: "Different Mac")
        coordinator.handle(try incomingB.pairingURL())
        coordinator.confirm(displayedA, generation: displayedGeneration, deviceName: "Phone")
        XCTAssertEqual(coordinator.pendingPairing, incomingB)
        XCTAssertFalse(coordinator.isPairing)
        XCTAssertTrue(HelperPairingTestProtocol.requests.isEmpty)
        XCTAssertTrue(store.records.isEmpty)
        coordinator.handle(try displayedA.pairingURL())
        coordinator.confirm(displayedA, generation: displayedGeneration, deviceName: "Phone")
        XCTAssertEqual(coordinator.pendingPairing, displayedA)
        XCTAssertFalse(coordinator.isPairing)
        XCTAssertTrue(HelperPairingTestProtocol.requests.isEmpty)
        XCTAssertTrue(store.records.isEmpty)
    }

    func testOneAuthPresenterPerVisibleContextWithDesktopRootFallback() {
        let coordinator = AuthPresentationCoordinator()
        let root = UUID()
        let settings = UUID()
        let secondWindow = UUID()
        coordinator.registerPresenter(root, priority: 0)
        XCTAssertEqual(coordinator.presentationOwner, root)
        coordinator.registerPresenter(settings, priority: 10)
        XCTAssertEqual(coordinator.presentationOwner, settings)
        coordinator.registerPresenter(secondWindow, priority: 10)
        XCTAssertEqual(coordinator.presentationOwner, secondWindow)
        coordinator.present(preferredDestination: .openAI)
        XCTAssertTrue(coordinator.isPresented)
        coordinator.unregisterPresenter(secondWindow)
        XCTAssertEqual(coordinator.presentationOwner, settings)
        coordinator.unregisterPresenter(settings)
        XCTAssertEqual(coordinator.presentationOwner, root)
        XCTAssertTrue(coordinator.isPresented)
        coordinator.dismiss()
        XCTAssertFalse(coordinator.isPresented)
    }

    private func makeCoordinator() -> MobileHelperPairingCoordinator {
        MobileHelperPairingCoordinator(configuration: configuration,
            client: MobileHelperPairingClient(sessionFactory: { _, _ in
                let config = URLSessionConfiguration.ephemeral
                config.protocolClasses = [HelperPairingTestProtocol.self]
                return URLSession(configuration: config)
            }), didSelect: {})
    }
    private func payload() -> MobileHelperPairingPayload {
        MobileHelperPairingPayload(version: 1, endpoint: URL(string: "https://192.168.1.10:8086")!, helperID: helperID,
            fingerprint: String(repeating: "a", count: 64), code: String(repeating: "b", count: 64), name: "Test Mac")
    }
    private func credential(helperID: String? = nil, token: String? = nil, capabilities: [String] = ["ollama"]) -> MobileHelperCredential {
        MobileHelperCredential(endpoint: payload().endpoint, helperID: helperID ?? self.helperID,
            fingerprint: payload().fingerprint, name: payload().name, deviceID: deviceID,
            token: token ?? String(repeating: "c", count: 64), capabilities: capabilities)
    }
    private func installSuccessfulResponses(healthHelperID: String? = nil, healthStatus: Int = 200, delay: TimeInterval = 0) {
        let pair = MobileHelperPairingResponse(version: 1, helperID: helperID, deviceID: deviceID,
            token: String(repeating: "c", count: 64), capabilities: ["ollama"])
        let health = MobileHelperHealthResponse(version: 1, helperID: healthHelperID ?? helperID, capabilities: ["ollama"])
        HelperPairingTestProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/mobile/pair": return (200, try JSONEncoder().encode(pair), delay)
            case "/v1/mobile/health": return (healthStatus, try JSONEncoder().encode(health), 0)
            case "/v1/ollama/api/version": return (200, Data(#"{"version":"0.5.0"}"#.utf8), 0)
            default: throw URLError(.unsupportedURL)
            }
        }
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            if Date() >= deadline { throw URLError(.timedOut) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

@MainActor
private extension MobileHelperPairingCoordinator {
    /// Test convenience only: production confirmation must capture these when rendered.
    func confirm(deviceName: String) {
        guard let payload = pendingPairing else { return }
        confirm(payload, generation: pendingGeneration, deviceName: deviceName)
    }
}

private final class MemoryHelperStore: MobileHelperCredentialStoring, @unchecked Sendable {
    var records: [String: MobileHelperCredential] = [:]
    var failWrites = false
    var failReads = false
    func load(helperID: String) throws -> MobileHelperCredential? {
        if failReads { throw MobileHelperError.persistence("test") }
        return records[helperID]
    }
    func save(_ credential: MobileHelperCredential) throws {
        if failWrites { throw MobileHelperError.persistence("test") }
        records[credential.helperID] = credential
    }
    func remove(helperID: String) throws { records.removeValue(forKey: helperID) }
}

private final class HelperPairingTestProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> (Int, Data, TimeInterval)
    private static let lock = NSLock()
    private static var storedHandler: Handler?
    private static var storedRequests: [URLRequest] = []
    private var work: DispatchWorkItem?
    static var handler: Handler? {
        get { lock.lock(); defer { lock.unlock() }; return storedHandler }
        set { lock.lock(); defer { lock.unlock() }; storedHandler = newValue }
    }
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return storedRequests }
    static func reset() { lock.lock(); defer { lock.unlock() }; storedRequests = []; storedHandler = nil }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.storedRequests.append(request)
        let handler = Self.storedHandler
        Self.lock.unlock()
        do {
            guard let handler else { throw URLError(.badServerResponse) }
            let (status, data, delay) = try handler(request)
            let item = DispatchWorkItem { [weak self] in
                guard let self, self.work?.isCancelled == false else { return }
                let response = HTTPURLResponse(url: self.request.url!, statusCode: status, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"])!
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: data)
                self.client?.urlProtocolDidFinishLoading(self)
            }
            work = item
            DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: item)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { work?.cancel() }
}
