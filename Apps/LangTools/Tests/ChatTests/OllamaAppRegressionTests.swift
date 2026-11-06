import Foundation
import Ollama
import XCTest
@testable import Chat

@MainActor
final class ProviderAccessRefreshRegressionTests: XCTestCase {
    func testQueuedRefreshCannotRestoreOldServerCatalog() async throws {
        try await withConfiguration { configuration, manager in
            let old = try configuration.update("https://old.local:11434")
            XCTAssertTrue(configuration.storeModels([.init(rawValue: "old-model")!], for: old))
            try queueBackgroundRefresh(manager)

            let current = try configuration.update("https://new.local:11434")
            XCTAssertTrue(configuration.storeModels([.init(rawValue: "new-model")!], for: current))
            manager.refresh()
            await drainMainQueue()

            XCTAssertEqual(manager.state(for: .ollama).availableModels.map(\.slug), ["new-model"])
        }
    }

    func testQueuedRefreshCannotRestoreDisconnectedHelperCatalog() async throws {
        try await withConfiguration { configuration, manager in
            try configuration.selectHelper(makeHelperConnection())
            XCTAssertTrue(configuration.storeModels([.init(rawValue: "helper-model")!], for: configuration.snapshot()))
            try queueBackgroundRefresh(manager)

            try configuration.disconnectHelper()
            manager.refresh()
            await drainMainQueue()

            XCTAssertTrue(manager.state(for: .ollama).availableModels.isEmpty)
            XCTAssertTrue(configuration.snapshot().isHelper, "Disconnect must not select direct Ollama")
        }
    }

    func testQueuedRefreshIsRejectedOnEndpointRevisionChangeWithoutAnotherRefresh() async throws {
        try await withConfiguration { configuration, manager in
            let old = try configuration.update("https://a.local:11434")
            XCTAssertTrue(configuration.storeModels([.init(rawValue: "old-model")!], for: old))
            try queueBackgroundRefresh(manager)

            _ = try configuration.update("https://b.local:11434")
            _ = try configuration.update("https://a.local:11434")
            await drainMainQueue()

            XCTAssertTrue(manager.state(for: .ollama).availableModels.isEmpty,
                          "Returning to the same URL must not revive an older revision")
        }
    }

    func testNewerRefreshWinsWhenCacheChangesOnSameEndpoint() async throws {
        try await withConfiguration { configuration, manager in
            let snapshot = configuration.snapshot()
            XCTAssertTrue(configuration.storeModels([.init(rawValue: "old-model")!], for: snapshot))
            try queueBackgroundRefresh(manager)

            XCTAssertTrue(configuration.storeModels([.init(rawValue: "new-model")!], for: snapshot))
            manager.refresh()
            await drainMainQueue()

            XCTAssertEqual(manager.state(for: .ollama).availableModels.map(\.slug), ["new-model"])
        }
    }

    func testEndpointChangeDuringRefreshCannotPublishAnotherEndpointsCache() async throws {
        let keys = PausingRegressionKeychainService()
        try await withConfiguration(keys: keys) { configuration, manager in
            let old = try configuration.update("https://old.local:11434")
            XCTAssertTrue(configuration.storeModels([.init(rawValue: "old-model")!], for: old))
            let finished = DispatchSemaphore(value: 0)
            keys.pauseNextRead()
            let refresh = RegressionBackgroundRefresh(manager: manager)
            DispatchQueue.global().async {
                refresh.run()
                finished.signal()
            }
            defer { keys.resume.signal() }
            XCTAssertEqual(keys.paused.wait(timeout: .now() + 5), .success)

            let current = try configuration.update("https://new.local:11434")
            XCTAssertTrue(configuration.storeModels([.init(rawValue: "new-model")!], for: current))
            keys.resume.signal()
            XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
            await drainMainQueue()

            XCTAssertTrue(manager.state(for: .ollama).availableModels.isEmpty,
                          "The revision must be captured before cache/credential reads, not after them")
            manager.refresh()
            XCTAssertEqual(manager.state(for: .ollama).availableModels.map(\.slug), ["new-model"])
        }
    }

    private func withConfiguration(
        keys: KeychainService = PausingRegressionKeychainService(),
        operation: (OllamaEndpointConfiguration, ProviderAccessManager) async throws -> Void
    ) async throws {
        let suite = "ProviderAccessRefreshRegressionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = OllamaEndpointConfiguration(userDefaults: defaults, credentialStore: RegressionHelperStore())
        let manager = ProviderAccessManager(keychainService: keys,
            sessionStore: AuthSessionStore(secretStore: OllamaMemorySecrets()),
            ollamaEndpointConfiguration: configuration)
        try await operation(configuration, manager)
    }

    private func queueBackgroundRefresh(_ manager: ProviderAccessManager) throws {
        // Keep the main queue blocked until refresh has captured and queued its result.
        XCTAssertTrue(Thread.isMainThread)
        let finished = DispatchSemaphore(value: 0)
        let refresh = RegressionBackgroundRefresh(manager: manager)
        DispatchQueue.global().async {
            refresh.run()
            finished.signal()
        }
        guard finished.wait(timeout: .now() + 5) == .success else { throw URLError(.timedOut) }
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

@MainActor
final class OllamaSettingsErrorRegressionTests: XCTestCase {
    func testLoadReportsTrustChangedForRecordedPinRejection() async throws {
        try await assertOperationError(pull: false, rejectedTrust: true)
    }

    func testPullReportsTrustChangedForRecordedPinRejection() async throws {
        try await assertOperationError(pull: true, rejectedTrust: true)
    }

    func testLoadPreservesActualSessionCancellation() async throws {
        try await assertOperationError(pull: false, rejectedTrust: false)
    }

    func testPullPreservesActualSessionCancellation() async throws {
        try await assertOperationError(pull: true, rejectedTrust: false)
    }

    private func assertOperationError(pull: Bool, rejectedTrust: Bool) async throws {
        let suite = "OllamaSettingsErrorRegressionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = OllamaEndpointConfiguration(userDefaults: defaults, credentialStore: RegressionHelperStore())
        let credential = makeHelperConnection().credential
        let delegate = MobileHelperSessionDelegate(fingerprint: credential.fingerprint, origin: credential.endpoint)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [SettingsRegressionURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration, delegate: delegate, delegateQueue: nil)
        defer {
            SettingsRegressionURLProtocol.onStart = nil
            session.invalidateAndCancel()
        }
        try configuration.selectHelper(MobileHelperConnection(credential: credential, session: session))
        if rejectedTrust {
            // Simulate the delegate's recorded wrong-pin rejection without TLS fixtures.
            // Foundation can report that rejected challenge as URLError.cancelled.
            let space = URLProtectionSpace(host: credential.endpoint.host!, port: credential.endpoint.port!,
                protocol: "https", realm: nil, authenticationMethod: NSURLAuthenticationMethodServerTrust)
            let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil,
                previousFailureCount: 0, failureResponse: nil, error: nil, sender: RegressionChallengeSender())
            delegate.urlSession(session, didReceive: challenge) { disposition, suppliedCredential in
                XCTAssertEqual(disposition, .cancelAuthenticationChallenge)
                XCTAssertNil(suppliedCredential)
            }
            XCTAssertTrue(delegate.hasRejectedTrust)
            SettingsRegressionURLProtocol.onStart = { urlProtocol in
                urlProtocol.client?.urlProtocol(urlProtocol, didFailWithError: URLError(.cancelled))
            }
        } else {
            // Cancel the real URLSession request after it starts, not a fabricated error.
            SettingsRegressionURLProtocol.onStart = { _ in
                session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
            }
        }
        let manager = ProviderAccessManager(keychainService: PausingRegressionKeychainService(),
            sessionStore: AuthSessionStore(secretStore: OllamaMemorySecrets()), ollamaEndpointConfiguration: configuration)
        let service = OllamaService(endpointConfiguration: configuration, session: .shared, providerAccessManager: manager)
        let viewModel = OllamaSettingsView.ViewModel(ollamaService: service, endpointConfiguration: configuration)
        if pull {
            viewModel.newModelName = "test-model"
            viewModel.pullModel()
        } else {
            viewModel.toggleModel(try XCTUnwrap(Ollama.Model(rawValue: "test-model")))
        }
        let deadline = Date().addingTimeInterval(5)
        while pull ? viewModel.isPulling : viewModel.loadingModelName != nil {
            if Date() >= deadline { throw URLError(.timedOut) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let expected: String
        if rejectedTrust {
            expected = MobileHelperError.trustChanged.localizedDescription
        } else {
            do {
                _ = try await session.data(from: credential.endpoint)
                XCTFail("The cancelled URLSession task must report cancellation")
                return
            } catch {
                let cancellation = try XCTUnwrap(error as? URLError)
                XCTAssertEqual(cancellation.code, .cancelled)
                XCTAssertNil(configuration.snapshot().actionableError(error) as? MobileHelperError)
                // Foundation supplies localized userInfo for actual cancellation;
                // a freshly constructed URLError(-999) has a different description.
                expected = cancellation.localizedDescription
            }
        }
        XCTAssertEqual(pull ? viewModel.pullError : viewModel.connectionError, expected)
        XCTAssertEqual(delegate.hasRejectedTrust, rejectedTrust)
    }
}

/// Only the manager's lock-protected refresh entry point crosses the test queue.
private struct RegressionBackgroundRefresh: @unchecked Sendable {
    let manager: ProviderAccessManager
    func run() { manager.refresh() }
}

private final class PausingRegressionKeychainService: KeychainService {
    let paused = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var shouldPause = false

    func pauseNextRead() {
        lock.lock()
        shouldPause = true
        lock.unlock()
    }

    override func getApiKey(for service: APIService) -> String? {
        lock.lock()
        let pause = shouldPause
        shouldPause = false
        lock.unlock()
        if pause {
            paused.signal()
            XCTAssertEqual(resume.wait(timeout: .now() + 5), .success)
        }
        return nil
    }
}

private final class RegressionHelperStore: MobileHelperCredentialStoring, @unchecked Sendable {
    private var records: [String: MobileHelperCredential] = [:]
    func load(helperID: String) throws -> MobileHelperCredential? { records[helperID] }
    func save(_ credential: MobileHelperCredential) throws { records[credential.helperID] = credential }
    func remove(helperID: String) throws { records.removeValue(forKey: helperID) }
}

private func makeHelperConnection() -> MobileHelperConnection {
    MobileHelperConnection(credential: MobileHelperCredential(endpoint: URL(string: "https://192.168.1.10:8086")!,
        helperID: UUID().uuidString, fingerprint: String(repeating: "a", count: 64), name: "Test Mac",
        deviceID: UUID().uuidString, token: String(repeating: "b", count: 64), capabilities: ["ollama"]))
}

private final class SettingsRegressionURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var storedOnStart: ((URLProtocol) -> Void)?
    static var onStart: ((URLProtocol) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return storedOnStart }
        set { lock.lock(); defer { lock.unlock() }; storedOnStart = newValue }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let onStart = Self.onStart else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        onStart(self)
    }
    override func stopLoading() {}
}

private final class RegressionChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}
