import Foundation
import XCTest
import Ollama
import OpenAI
import AppleLangTools
@testable import Chat

@MainActor
final class CombinedProviderMergeTests: XCTestCase {
    func testIndependentOllamaRoutesCoexistWithCompatibleAndAppleModels() throws {
        try withManager { manager, keys, configuration in
            let local = try XCTUnwrap(Ollama.Model(rawValue: "glm-5.2:cloud"))
            XCTAssertTrue(configuration.storeModels([local], for: configuration.snapshot()))
            keys.saveApiKey(apiKey: "synthetic-cloud-key", for: .ollama)
            keys.saveApiKey(apiKey: "synthetic-groq-key", for: .groq)
            manager.refresh()

            let models = manager.availableChatModels()
            XCTAssertTrue(models.contains(.ollama(local)))
            XCTAssertTrue(models.contains { $0.route == .ollamaCloud })
            XCTAssertTrue(models.contains { $0.route == .groq })
            XCTAssertEqual(models.contains { $0.route == .apple }, AppleIntelligence.isSupportedOnThisOS)
            XCTAssertEqual(manager.validateSelectedModel(.ollama(local)), .ollama(local))
        }
    }

    func testAppleAvailabilityDoesNotReplaceUnavailableCredentialedSelection() throws {
        try withManager { manager, _, _ in
            let selected = Model.codex(.gpt5_5)
            XCTAssertEqual(manager.validateSelectedModel(selected), selected)
            XCTAssertFalse(manager.availableChatModels().contains { $0.route == .ollamaCloud })
            let cloud = try XCTUnwrap(Model(rawValue: "ollama-cloud/glm-5.2"))
            XCTAssertEqual(manager.validateSelectedModel(cloud), cloud)
        }
    }

    func testLocalFallbackAndExplicitCloudPreferenceSurviveCombinedCatalog() throws {
        try withManager { manager, _, configuration in
            let local = try XCTUnwrap(Ollama.Model(rawValue: "local-fallback"))
            XCTAssertTrue(configuration.storeModels([local], for: configuration.snapshot()))
            manager.refresh()
            XCTAssertEqual(manager.validateSelectedModel(.codex(.gpt5_5)), .ollama(local))
            let cloud = try XCTUnwrap(Model(rawValue: "ollama-cloud/uncached-hosted"))
            XCTAssertEqual(manager.validateSelectedModel(cloud), cloud)
            for value in ["ollama/glm-5.2:cloud", "ollama-cloud/glm-5.2", "groq/llama-3.3-70b-versatile"] {
                XCTAssertEqual(Model(rawValue: value)?.rawValue, value)
            }
        }
    }

    private func withManager(_ test: (ProviderAccessManager, OllamaMemoryKeychainService, OllamaEndpointConfiguration) throws -> Void) throws {
        let suite = "CombinedProviderMergeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keys = OllamaMemoryKeychainService()
        let configuration = OllamaEndpointConfiguration(userDefaults: defaults, credentialStore: OllamaMemoryHelperStore())
        let catalog = CompatibleModelCatalog(userDefaults: defaults, fetcher: { _, _ in [] })
        let manager = ProviderAccessManager(
            keychainService: keys,
            sessionStore: AuthSessionStore(secretStore: OllamaMemorySecrets()),
            ollamaEndpointConfiguration: configuration,
            ollamaCloudModelStore: OllamaCloudModelStore(userDefaults: defaults),
            compatibleCatalog: catalog
        )
        try test(manager, keys, configuration)
    }
}
