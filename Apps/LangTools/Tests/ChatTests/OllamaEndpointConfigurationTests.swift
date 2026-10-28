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

    func testValidEndpointsAreCanonicalized() throws {
        let cases: [(String, String)] = [
            (" http://localhost:11434/ \n", "http://localhost:11434"),
            ("https://ollama.example.com", "https://ollama.example.com"),
            ("http://192.168.1.20:11434", "http://192.168.1.20:11434"),
            ("http://[::1]:11434/", "http://[::1]:11434"),
            ("https://host.local:443/", "https://host.local:443"),
        ]

        for (input, expected) in cases {
            XCTAssertEqual(try OllamaEndpointConfiguration.validate(input).absoluteString, expected)
        }
    }

    func testInvalidEndpointsAreRejected() {
        let values = [
            "", "localhost:11434", "ftp://localhost:11434", "http:///api",
            "http://user:pass@localhost:11434", "http://localhost:11434?x=1",
            "http://localhost:11434#fragment", "http://localhost:11434/api",
            "http://localhost:11434/models", "http://localhost:0",
            "http://localhost:65536", "http://localhost:notaport",
        ]

        for value in values {
            XCTAssertThrowsError(try OllamaEndpointConfiguration.validate(value), value)
        }
    }

    func testPersistsEndpointAcrossReconstructedInstances() throws {
        let configuration = OllamaEndpointConfiguration(userDefaults: defaults)
        let updated = try configuration.update(" http://192.168.1.10:11434/ ")
        XCTAssertEqual(updated.baseURL.absoluteString, "http://192.168.1.10:11434")

        let relaunched = OllamaEndpointConfiguration(userDefaults: defaults)
        XCTAssertEqual(relaunched.snapshot().baseURL, updated.baseURL)
    }

    func testInvalidPersistedEndpointFallsBackAndPersistsDefault() {
        defaults.set("http://localhost:11434/api", forKey: OllamaEndpointConfiguration.endpointKey)

        let configuration = OllamaEndpointConfiguration(userDefaults: defaults)

        XCTAssertEqual(configuration.snapshot().baseURL, OllamaEndpointConfiguration.defaultBaseURL)
        XCTAssertEqual(
            defaults.string(forKey: OllamaEndpointConfiguration.endpointKey),
            OllamaEndpointConfiguration.defaultBaseURL.absoluteString
        )
    }

    func testCachesAreEndpointScopedAndStaleWritesAreRejected() throws {
        defaults.set(["legacy-model"], forKey: "ollamaModels")
        let configuration = OllamaEndpointConfiguration(userDefaults: defaults)
        let localhost = configuration.snapshot()
        let localModel = try XCTUnwrap(Ollama.Model(rawValue: "local-model"))
        XCTAssertTrue(configuration.storeModels([localModel], for: localhost))

        let lan = try configuration.update("http://192.168.1.10:11434")
        XCTAssertEqual(configuration.cachedModels(), [])
        XCTAssertFalse(configuration.storeModels([try XCTUnwrap(Ollama.Model(rawValue: "stale"))], for: localhost))

        let lanModel = try XCTUnwrap(Ollama.Model(rawValue: "lan-model"))
        XCTAssertTrue(configuration.storeModels([lanModel], for: lan))
        XCTAssertEqual(configuration.cachedModels().map(\.rawValue), ["lan-model"])

        _ = try configuration.update(localhost.baseURL.absoluteString)
        XCTAssertEqual(configuration.cachedModels().map(\.rawValue), ["local-model"])
        XCTAssertFalse(configuration.cachedModels().contains { $0.rawValue == "legacy-model" })
    }

    func testRevisionOnlyChangesWhenCanonicalEndpointChanges() throws {
        let configuration = OllamaEndpointConfiguration(userDefaults: defaults)
        let initial = configuration.snapshot()
        let same = try configuration.update("http://localhost:11434/")
        XCTAssertEqual(same.revision, initial.revision)

        let changed = try configuration.update("http://mac.local:11434")
        XCTAssertGreaterThan(changed.revision, same.revision)
        XCTAssertFalse(configuration.isCurrent(initial))
        XCTAssertTrue(configuration.isCurrent(changed))
    }
}
