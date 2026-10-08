import Foundation
import KeychainAccess
import Ollama
import XCTest
@testable import Chat

@MainActor
final class ProviderAccessRefreshRegressionTests: XCTestCase {
    func testQueuedRefreshCannotRestoreOldServerCatalog() async throws {
        try await withConfiguration { configuration, manager in
            let old = try configuration.update("http://old.local:11434")
            XCTAssertTrue(configuration.storeModels([.init(rawValue: "old-model")!], for: old))
            try queueBackgroundRefresh(manager)

            let current = try configuration.update("http://new.local:11434")
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
            let old = try configuration.update("http://a.local:11434")
            XCTAssertTrue(configuration.storeModels([.init(rawValue: "old-model")!], for: old))
            try queueBackgroundRefresh(manager)

            _ = try configuration.update("http://b.local:11434")
            _ = try configuration.update("http://a.local:11434")
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
            let old = try configuration.update("http://old.local:11434")
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

            let current = try configuration.update("http://new.local:11434")
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
            sessionStore: AuthSessionStore(keychain: Keychain(service: suite)),
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
