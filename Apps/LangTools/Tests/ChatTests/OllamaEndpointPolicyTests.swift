import XCTest
import Ollama
@testable import Chat

final class OllamaEndpointPolicyTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "OllamaEndpointPolicyTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testAbsentSettingUsesDefaultAndFactoryUsesLoopbackSession() throws {
        XCTAssertEqual(try OllamaEndpointPolicy.resolve(userDefaults: defaults), OllamaEndpointPolicy.defaultURL)

        let ollama = try OllamaEndpointPolicy.makeOllama(userDefaults: defaults)

        XCTAssertEqual(ollama.configuration.baseURL, URL(string: "http://localhost:11434"))
        XCTAssertTrue(ollama.session === LoopbackURLSession.shared)
    }

    func testValidEndpointsPreserveCustomPath() throws {
        let values = [
            "http://localhost:22445/custom/path",
            "http://127.0.0.1:22445/custom/path",
            "http://[::1]:22445/custom/path",
            "https://ollama.example.com/custom/path",
        ]

        for value in values {
            XCTAssertEqual(try OllamaEndpointPolicy.validate(value).absoluteString, value)
        }
    }

    func testPresentInvalidEndpointsNeverFallBackToDefault() {
        let invalidValues: [(String, OllamaEndpointError)] = [
            ("", .empty),
            (" https://ollama.example.com", .malformed(" https://ollama.example.com")),
            ("not a url", .unsupportedScheme(nil)),
            ("localhost:11434", .unsupportedScheme("localhost")),
            ("ftp://localhost:11434", .unsupportedScheme("ftp")),
            ("https:///missing-host", .missingHost),
            ("https://user@ollama.example.com/path", .disallowedComponent("user or password")),
            ("https://user:password@ollama.example.com/path", .disallowedComponent("user or password")),
            ("https://ollama.example.com/path?model=one", .disallowedComponent("query")),
            ("https://ollama.example.com/path?", .disallowedComponent("query")),
            ("https://ollama.example.com/path#models", .disallowedComponent("fragment")),
            ("https://ollama.example.com/path#", .disallowedComponent("fragment")),
            ("http://example.com:11434", .unsafeHTTPHost("example.com")),
            ("http://localhost.example.com:11434", .unsafeHTTPHost("localhost.example.com")),
        ]

        for (value, expectedError) in invalidValues {
            defaults.set(value, forKey: OllamaEndpointPolicy.userDefaultsKey)
            XCTAssertThrowsError(try OllamaEndpointPolicy.resolve(userDefaults: defaults), value) { error in
                XCTAssertEqual(error as? OllamaEndpointError, expectedError)
            }
        }

        defaults.set(11434, forKey: OllamaEndpointPolicy.userDefaultsKey)
        XCTAssertThrowsError(try OllamaEndpointPolicy.resolve(userDefaults: defaults)) { error in
            guard case .malformed = error as? OllamaEndpointError else {
                return XCTFail("Expected malformed error, got \(error)")
            }
        }
    }

    func testOllamaServiceColdStartUsesPersistedEndpoint() {
        defaults.set("http://127.0.0.1:22445/custom", forKey: OllamaEndpointPolicy.userDefaultsKey)

        let service = OllamaService(userDefaults: defaults)

        XCTAssertEqual(service.configuredBaseURL, URL(string: "http://127.0.0.1:22445/custom"))
        XCTAssertNil(service.error)
    }

    func testOllamaServiceColdStartRetainsInvalidEndpointError() async {
        defaults.set("http://remote.example.com:11434", forKey: OllamaEndpointPolicy.userDefaultsKey)

        let service = OllamaService(userDefaults: defaults)

        XCTAssertNil(service.configuredBaseURL)
        XCTAssertTrue(service.error is OllamaEndpointError)
        do {
            _ = try await service.checkConnection()
            XCTFail("Expected invalid endpoint error")
        } catch {
            XCTAssertTrue(error is OllamaEndpointError)
        }
    }

    @MainActor
    func testEndpointSaveSynchronouslyUpdatesServiceAndInjectedDefaults() throws {
        let service = OllamaService(userDefaults: defaults)
        let savedURL = try service.updateBaseUrl("https://ollama.example.com/custom/path")

        XCTAssertEqual(savedURL, URL(string: "https://ollama.example.com/custom/path"))
        XCTAssertEqual(service.configuredBaseURL, savedURL)
        XCTAssertEqual(
            defaults.string(forKey: OllamaEndpointPolicy.userDefaultsKey),
            savedURL.absoluteString
        )
    }

    @MainActor
    func testInvalidEndpointSaveMutatesNeitherPublishedStateNorInFlightRefresh() async throws {
        let originalValue = "http://127.0.0.1:22445/custom"
        defaults.set(originalValue, forKey: OllamaEndpointPolicy.userDefaultsKey)
        let firstGate = AsyncResultGate<[Ollama.Model]>()
        let secondGate = AsyncResultGate<[Ollama.Model]>()
        let requests = SequencedAsyncResults(first: firstGate, second: secondGate)
        let oldRunningModel = try runningModel("old-model")
        let cacheRecorder = ModelCacheRecorder()
        let dependencies = OllamaService.Dependencies(
            availableModels: { _ in try await requests.next() },
            runningModels: { _ in [oldRunningModel] },
            checkConnection: { _ in },
            cacheModels: cacheRecorder.record
        )
        let service = OllamaService(userDefaults: defaults, dependencies: dependencies)

        let initialRefresh = service.refreshModels()
        await firstGate.waitUntilStarted()
        await firstGate.succeed([model("old-model")])
        await initialRefresh.value
        let inFlightRefresh = service.refreshModels()
        await secondGate.waitUntilStarted()

        XCTAssertThrowsError(try service.updateBaseUrl("https://ollama.example.com/path?"))
        XCTAssertEqual(service.configuredBaseURL, URL(string: originalValue))
        XCTAssertEqual(defaults.string(forKey: OllamaEndpointPolicy.userDefaultsKey), originalValue)
        XCTAssertEqual(service.availableModels.map(\.rawValue), ["old-model"])
        XCTAssertEqual(service.runningModels.map(\.model), ["old-model"])
        XCTAssertEqual(cacheRecorder.values, [["old-model"]])
        XCTAssertTrue(service.isLoading)

        await secondGate.succeed([model("new-model")])
        await inFlightRefresh.value
        XCTAssertEqual(service.availableModels.map(\.rawValue), ["new-model"])
        XCTAssertEqual(cacheRecorder.values, [["old-model"], ["new-model"]])
    }

    @MainActor
    func testSameEndpointSavePreservesPublishedStateAndInFlightRefresh() async throws {
        let endpoint = OllamaEndpointPolicy.defaultURL.absoluteString
        let firstGate = AsyncResultGate<[Ollama.Model]>()
        let secondGate = AsyncResultGate<[Ollama.Model]>()
        let requests = SequencedAsyncResults(first: firstGate, second: secondGate)
        let oldRunningModel = try runningModel("old-model")
        let cacheRecorder = ModelCacheRecorder()
        let dependencies = OllamaService.Dependencies(
            availableModels: { _ in try await requests.next() },
            runningModels: { _ in [oldRunningModel] },
            checkConnection: { _ in },
            cacheModels: cacheRecorder.record
        )
        let service = OllamaService(userDefaults: defaults, dependencies: dependencies)

        let initialRefresh = service.refreshModels()
        await firstGate.waitUntilStarted()
        await firstGate.succeed([model("old-model")])
        await initialRefresh.value
        let inFlightRefresh = service.refreshModels()
        await secondGate.waitUntilStarted()

        try service.updateBaseUrl(endpoint)

        XCTAssertEqual(service.availableModels.map(\.rawValue), ["old-model"])
        XCTAssertEqual(service.runningModels.map(\.model), ["old-model"])
        XCTAssertEqual(cacheRecorder.values, [["old-model"]])
        XCTAssertTrue(service.isLoading)

        await secondGate.succeed([model("new-model")])
        await inFlightRefresh.value
        XCTAssertEqual(service.availableModels.map(\.rawValue), ["new-model"])
        XCTAssertEqual(cacheRecorder.values, [["old-model"], ["new-model"]])
    }

    @MainActor
    func testActualEndpointSaveClearsCompletedModelsRunningModelsAndCache() async throws {
        let oldRunningModel = try runningModel("old-model")
        let cacheRecorder = ModelCacheRecorder()
        let dependencies = OllamaService.Dependencies(
            availableModels: { _ in [self.model("old-model")] },
            runningModels: { _ in [oldRunningModel] },
            checkConnection: { _ in },
            cacheModels: cacheRecorder.record
        )
        let service = OllamaService(userDefaults: defaults, dependencies: dependencies)

        await service.refreshModels().value
        XCTAssertEqual(service.availableModels.map(\.rawValue), ["old-model"])
        XCTAssertEqual(service.runningModels.map(\.model), ["old-model"])
        XCTAssertEqual(cacheRecorder.values, [["old-model"]])

        try service.updateBaseUrl("http://localhost:22445/custom")

        XCTAssertTrue(service.availableModels.isEmpty)
        XCTAssertTrue(service.runningModels.isEmpty)
        XCTAssertEqual(cacheRecorder.values, [["old-model"], []])
        XCTAssertFalse(service.isLoading)
    }

    @MainActor
    func testOldEndpointRefreshCannotPublishAfterEndpointSave() async throws {
        let oldGate = AsyncResultGate<[Ollama.Model]>()
        let newGate = AsyncResultGate<[Ollama.Model]>()
        let cacheRecorder = ModelCacheRecorder()
        let dependencies = OllamaService.Dependencies(
            availableModels: { ollama in
                if ollama.configuration.baseURL.port == 11434 {
                    return try await oldGate.wait()
                }
                return try await newGate.wait()
            },
            runningModels: { _ in [] },
            checkConnection: { _ in },
            cacheModels: cacheRecorder.record
        )
        let service = OllamaService(userDefaults: defaults, dependencies: dependencies)

        let oldRefresh = service.refreshModels()
        await oldGate.waitUntilStarted()
        try service.updateBaseUrl("http://localhost:22445/custom")
        let newRefresh = service.refreshModels()
        await newGate.waitUntilStarted()
        await newGate.succeed([model("new-model")])
        await newRefresh.value
        await oldGate.succeed([model("stale-model")])
        await oldRefresh.value

        XCTAssertEqual(service.availableModels.map(\.rawValue), ["new-model"])
        XCTAssertEqual(cacheRecorder.values, [[], ["new-model"]])
        XCTAssertNil(service.error)
        XCTAssertFalse(service.isLoading)
    }

    @MainActor
    func testOlderSameEndpointRefreshErrorCannotOverwriteLatestRefresh() async {
        let firstGate = AsyncResultGate<[Ollama.Model]>()
        let secondGate = AsyncResultGate<[Ollama.Model]>()
        let requests = SequencedAsyncResults(first: firstGate, second: secondGate)
        let cacheRecorder = ModelCacheRecorder()
        let dependencies = OllamaService.Dependencies(
            availableModels: { _ in try await requests.next() },
            runningModels: { _ in [] },
            checkConnection: { _ in },
            cacheModels: cacheRecorder.record
        )
        let service = OllamaService(userDefaults: defaults, dependencies: dependencies)

        let firstRefresh = service.refreshModels()
        await firstGate.waitUntilStarted()
        let secondRefresh = service.refreshModels()
        await secondGate.waitUntilStarted()
        await secondGate.succeed([model("latest-model")])
        await secondRefresh.value
        await firstGate.fail(TestFailure.expected)
        await firstRefresh.value

        XCTAssertEqual(service.availableModels.map(\.rawValue), ["latest-model"])
        XCTAssertEqual(cacheRecorder.values, [["latest-model"]])
        XCTAssertNil(service.error)
        XCTAssertFalse(service.isLoading)
    }

    @MainActor
    func testEndpointChangeCancelsStaleConnectionProbe() async throws {
        let probeGate = AsyncResultGate<Void>()
        let dependencies = OllamaService.Dependencies(
            availableModels: { _ in [] },
            runningModels: { _ in [] },
            checkConnection: { _ in try await probeGate.wait() },
            cacheModels: { _ in }
        )
        let service = OllamaService(userDefaults: defaults, dependencies: dependencies)
        let probe = Task { try await service.checkConnection() }
        await probeGate.waitUntilStarted()

        try service.updateBaseUrl("http://localhost:22445/custom")
        await probeGate.succeed(())

        do {
            _ = try await probe.value
            XCTFail("Expected stale probe cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    @MainActor
    func testSettingsSaveResetsStatusAndDiscoversNewEndpointModelsAfterProbe() async throws {
        let probeGate = AsyncResultGate<Void>()
        let modelGate = AsyncResultGate<[Ollama.Model]>()
        let cacheRecorder = ModelCacheRecorder()
        let dependencies = OllamaService.Dependencies(
            availableModels: { _ in try await modelGate.wait() },
            runningModels: { _ in [] },
            checkConnection: { _ in try await probeGate.wait() },
            cacheModels: cacheRecorder.record
        )
        let service = OllamaService(userDefaults: defaults, dependencies: dependencies)
        let viewModel = OllamaSettingsView.ViewModel(
            ollamaService: service,
            userDefaults: defaults,
            checksConnectionOnInit: false
        )
        viewModel.isConnected = true
        viewModel.editingServerUrl = "http://localhost:22445/custom"

        let saveTask = try XCTUnwrap(viewModel.updateServerUrl())

        XCTAssertFalse(viewModel.isConnected)
        XCTAssertTrue(viewModel.isCheckingConnection)
        await probeGate.waitUntilStarted()
        await probeGate.succeed(())
        await modelGate.waitUntilStarted()
        XCTAssertTrue(viewModel.isConnected)
        XCTAssertFalse(viewModel.isCheckingConnection)

        await modelGate.succeed([model("new-endpoint-model")])
        await saveTask.value

        XCTAssertEqual(service.availableModels.map(\.rawValue), ["new-endpoint-model"])
        XCTAssertEqual(cacheRecorder.values, [[], ["new-endpoint-model"]])
        XCTAssertNil(viewModel.connectionError)
    }

    @MainActor
    func testSettingsIgnoresObsoleteSameEndpointProbeCompletion() async {
        let firstGate = AsyncResultGate<Void>()
        let secondGate = AsyncResultGate<Void>()
        let probes = SequencedAsyncResults(first: firstGate, second: secondGate)
        let dependencies = OllamaService.Dependencies(
            availableModels: { _ in [] },
            runningModels: { _ in [] },
            checkConnection: { _ in try await probes.next() },
            cacheModels: { _ in }
        )
        let service = OllamaService(userDefaults: defaults, dependencies: dependencies)
        let viewModel = OllamaSettingsView.ViewModel(
            ollamaService: service,
            userDefaults: defaults,
            checksConnectionOnInit: false
        )

        let firstProbe = viewModel.checkConnection()
        await firstGate.waitUntilStarted()
        let secondProbe = viewModel.checkConnection()
        await secondGate.waitUntilStarted()
        await secondGate.succeed(())
        await secondProbe.value
        await firstGate.fail(TestFailure.expected)
        await firstProbe.value

        XCTAssertTrue(viewModel.isConnected)
        XCTAssertFalse(viewModel.isCheckingConnection)
        XCTAssertNil(viewModel.connectionError)
    }

    private func model(_ name: String) -> Ollama.Model {
        Ollama.Model(rawValue: name)!
    }

    private func runningModel(
        _ name: String
    ) throws -> Ollama.ListRunningModelsResponse.RunningModelInfo {
        let json = """
        {
          "name": "\(name)",
          "model": "\(name)",
          "size": 1,
          "digest": "digest",
          "details": {},
          "expires_at": "2026-10-01T00:00:00Z",
          "size_vram": 1
        }
        """
        return try JSONDecoder().decode(
            Ollama.ListRunningModelsResponse.RunningModelInfo.self,
            from: Data(json.utf8)
        )
    }
}

private enum TestFailure: Error {
    case expected
}

private actor AsyncResultGate<Value> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var started = false

    func wait() async throws -> Value {
        started = true
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilStarted() async {
        while !started {
            await Task.yield()
        }
    }

    func succeed(_ value: Value) {
        continuation?.resume(returning: value)
        continuation = nil
    }

    func fail(_ error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

private actor SequencedAsyncResults<Value> {
    private let first: AsyncResultGate<Value>
    private let second: AsyncResultGate<Value>
    private var requestCount = 0

    init(first: AsyncResultGate<Value>, second: AsyncResultGate<Value>) {
        self.first = first
        self.second = second
    }

    func next() async throws -> Value {
        requestCount += 1
        if requestCount == 1 {
            return try await first.wait()
        }
        return try await second.wait()
    }
}

private final class ModelCacheRecorder {
    private let lock = NSLock()
    private var recordedValues: [[String]] = []

    var values: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recordedValues
    }

    func record(_ models: [Ollama.Model]) {
        lock.lock()
        defer { lock.unlock() }
        recordedValues.append(models.map(\.rawValue))
    }
}
