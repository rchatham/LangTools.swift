import Foundation
import Ollama
import XCTest
@testable import Chat

final class OllamaEndpointConfigurationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "OllamaEndpointConfigurationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func configuration() -> OllamaEndpointConfiguration {
        OllamaEndpointConfiguration(userDefaults: defaults, credentialStore: OllamaMemoryHelperStore())
    }

    func testValidEndpointsAreCanonicalizedAndPreserveEncodedPaths() throws {
        let cases = [
            (" http://localhost:11434/ \n", "http://localhost:11434"),
            ("https://ollama.example.com", "https://ollama.example.com"),
            ("https://192.168.1.20:11434", "https://192.168.1.20:11434"),
            ("http://[::1]:11434/", "http://[::1]:11434"),
            ("https://host.local:443/", "https://host.local:443"),
            (" HTTPS://HOST.local/base%20path/v1 ", "https://host.local/base%20path/v1"),
            ("http://127.0.0.1:11434/api/custom/", "http://127.0.0.1:11434/api/custom/"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(try OllamaEndpointConfiguration.validate(input).absoluteString, expected)
            XCTAssertEqual(try OllamaEndpointPolicy.validate(input).absoluteString, expected)
        }
    }

    func testInvalidEndpointsAreRejectedByBothEntryPoints() {
        let values = [
            "", "localhost:11434", "ftp://localhost:11434", "http:///api",
            "http://user:pass@localhost:11434", "http://localhost:11434?x=1",
            "http://localhost:11434#fragment", "http://192.168.1.10:11434",
            "http://localhost.example.com:11434", "http://127.0.0.2:11434",
            "http://LOCALHOST.:11434", "http://localhost:0", "http://localhost:65536",
            "http://localhost:notaport", "http://localhost:", "https://host.local:0",
            "https://host.local?", "https://host.local#",
        ]
        for value in values {
            XCTAssertThrowsError(try OllamaEndpointConfiguration.validate(value), value)
            XCTAssertThrowsError(try OllamaEndpointPolicy.validate(value), value)
        }
    }

    func testPersistsEndpointAcrossReconstructedInstances() throws {
        let config = configuration()
        let updated = try config.update(" https://192.168.1.10:11434/custom%20base/ ")
        XCTAssertEqual(updated.baseURL?.absoluteString, "https://192.168.1.10:11434/custom%20base/")
        XCTAssertEqual(configuration().snapshot().baseURL, updated.baseURL)
    }

    func testInvalidPersistedEndpointIsUnusableAndNeverReplaced() throws {
        for value in ["https://user:secret@host.local/path", "https://host.local?secret", "https://host.local#secret", "http://remote.local"] {
            defaults.set(value, forKey: OllamaEndpointConfiguration.endpointKey)
            let config = configuration()
            let snapshot = config.snapshot()
            XCTAssertNil(config.directBaseURL)
            XCTAssertNil(snapshot.baseURL)
            XCTAssertNil(snapshot.cacheScope)
            XCTAssertNotNil(snapshot.validationError)
            XCTAssertFalse(String(describing: snapshot.validationError).contains("secret"))
            XCTAssertThrowsError(try snapshot.makeToolchain())
            XCTAssertThrowsError(try snapshot.makeAgentContext(model: .init(rawValue: "test")!, messages: [], eventHandler: { _ in }))
            XCTAssertEqual(defaults.string(forKey: OllamaEndpointConfiguration.endpointKey), value)
            XCTAssertTrue(config.cachedModels().isEmpty)
            XCTAssertFalse(config.storeModels([.init(rawValue: "blocked")!], for: snapshot))
            XCTAssertNil(defaults.object(forKey: OllamaEndpointConfiguration.modelsByEndpointKey))
            let recovered = try config.update("https://host.local/base")
            XCTAssertNil(recovered.validationError)
            XCTAssertGreaterThan(recovered.revision, snapshot.revision)
            XCTAssertFalse(config.isCurrent(snapshot))
        }
    }

    func testNonStringPersistenceFailsClosedAndOnlyAbsentSettingUsesDefault() {
        defaults.set(11434, forKey: OllamaEndpointConfiguration.endpointKey)
        let invalid = configuration()
        XCTAssertNil(invalid.directBaseURL)
        XCTAssertEqual(invalid.directValidationError, .invalidURL)
        XCTAssertEqual(defaults.integer(forKey: OllamaEndpointConfiguration.endpointKey), 11434)
        defaults.removeObject(forKey: OllamaEndpointConfiguration.endpointKey)
        XCTAssertEqual(configuration().directBaseURL, OllamaEndpointConfiguration.defaultBaseURL)
        XCTAssertNil(defaults.object(forKey: OllamaEndpointConfiguration.endpointKey))
    }

    func testFailedSaveLeavesSnapshotPersistenceAndCacheUnchanged() throws {
        let config = configuration()
        let old = config.snapshot()
        XCTAssertTrue(config.storeModels([.init(rawValue: "old")!], for: old))
        XCTAssertThrowsError(try config.update("http://remote.local/secret"))
        XCTAssertEqual(config.snapshot(), old)
        XCTAssertNil(defaults.object(forKey: OllamaEndpointConfiguration.endpointKey))
        XCTAssertEqual(config.cachedModels().map(\.rawValue), ["old"])
    }

    func testCachesAreEndpointScopedAndStaleWritesAreRejected() throws {
        defaults.set(["legacy-model"], forKey: "ollamaModels")
        let config = configuration()
        let localhost = config.snapshot()
        XCTAssertTrue(config.storeModels([.init(rawValue: "local-model")!], for: localhost))
        let remote = try config.update("https://192.168.1.10:11434")
        XCTAssertEqual(config.cachedModels(), [])
        XCTAssertFalse(config.storeModels([.init(rawValue: "stale")!], for: localhost))
        XCTAssertTrue(config.storeModels([.init(rawValue: "remote-model")!], for: remote))
        XCTAssertEqual(config.cachedModels().map(\.rawValue), ["remote-model"])
        _ = try config.update(try XCTUnwrap(localhost.baseURL).absoluteString)
        XCTAssertEqual(config.cachedModels().map(\.rawValue), ["local-model"])
        XCTAssertFalse(config.cachedModels().contains { $0.rawValue == "legacy-model" })
    }

    func testExternalPersistedChangesFailClosedBeforeNewOperationWhileCapturedCapabilityStaysOld() throws {
        let config = configuration()
        let old = config.snapshot()
        let captured = try old.makeToolchain()
        let request = Ollama.ChatRequest(model: .init(rawValue: "fixture")!, messages: [], stream: false)
        XCTAssertTrue(config.storeModels([.init(rawValue: "old")!], for: old))
        defaults.set("https://user:secret@remote.local/path", forKey: OllamaEndpointConfiguration.endpointKey)
        XCTAssertFalse(config.isCurrent(old), "Currentness checks must reread and validate changed persistence")
        let invalid = config.snapshot()
        XCTAssertGreaterThan(invalid.revision, old.revision)
        XCTAssertNil(invalid.baseURL)
        XCTAssertEqual(invalid.validationError, .credentialsNotAllowed)
        XCTAssertThrowsError(try invalid.makeToolchain())
        XCTAssertTrue(config.cachedModels().isEmpty)
        XCTAssertTrue(config.cachedModels(for: old).isEmpty)
        XCTAssertFalse(config.storeModels([.init(rawValue: "stale")!], for: old))
        XCTAssertEqual(try captured.prepare(request: request).url?.host, "localhost")
        XCTAssertEqual(defaults.string(forKey: OllamaEndpointConfiguration.endpointKey), "https://user:secret@remote.local/path")
        defaults.set("https://remote.local/custom%20path", forKey: OllamaEndpointConfiguration.endpointKey)
        let repaired = config.snapshot()
        XCTAssertGreaterThan(repaired.revision, invalid.revision)
        XCTAssertEqual(try repaired.makeToolchain().prepare(request: request).url?.host, "remote.local")
        defaults.set(42, forKey: OllamaEndpointConfiguration.endpointKey)
        XCTAssertNil(config.snapshot().baseURL)
        XCTAssertEqual(config.directValidationError, .invalidURL)
        defaults.removeObject(forKey: OllamaEndpointConfiguration.endpointKey)
        XCTAssertEqual(config.snapshot().baseURL, OllamaEndpointConfiguration.defaultBaseURL)
        XCTAssertFalse(config.isCurrent(old), "Returning to localhost does not restore the old revision")
    }

    func testRevisionOnlyChangesWhenCanonicalEndpointChanges() throws {
        let config = configuration()
        let initial = config.snapshot()
        let same = try config.update("http://localhost:11434/")
        XCTAssertEqual(same.revision, initial.revision)
        let changed = try config.update("https://mac.local:11434")
        XCTAssertGreaterThan(changed.revision, same.revision)
        XCTAssertFalse(config.isCurrent(initial))
        XCTAssertTrue(config.isCurrent(changed))
    }
}
