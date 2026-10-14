import XCTest
import Ollama
import OpenAI
import Anthropic
import XAI
import Gemini
@testable import Chat

final class OllamaCloudModelTests: XCTestCase {
    private var suiteNames: [String] = []
    private var defaults: [UserDefaults] = []
    private var store: OllamaCloudModelStore!

    override func setUp() {
        super.setUp()
        store = OllamaCloudModelStore(userDefaults: makeDefaults())
    }

    override func tearDown() {
        store = nil
        for (name, domain) in zip(suiteNames, defaults) {
            domain.removePersistentDomain(forName: name)
        }
        defaults = []
        suiteNames = []
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        let name = "OllamaCloudModelTests.\(UUID().uuidString)"
        let domain = UserDefaults(suiteName: name)!
        domain.removePersistentDomain(forName: name)
        suiteNames.append(name)
        defaults.append(domain)
        return domain
    }

    func testLocalCloudTaggedModelAndHostedCloudModelHaveDistinctIdentities() throws {
        let localModel = try XCTUnwrap(Model(rawValue: "ollama/glm-5.2:cloud"))
        let cloudModel = try XCTUnwrap(Model(rawValue: "ollama-cloud/glm-5.2"))

        XCTAssertEqual(localModel.rawValue, "ollama/glm-5.2:cloud")
        XCTAssertEqual(cloudModel.rawValue, "ollama-cloud/glm-5.2")
        XCTAssertNotEqual(localModel, cloudModel)
        XCTAssertEqual(localModel.route, .ollama)
        XCTAssertEqual(cloudModel.route, .ollamaCloud)
    }

    func testCloudRouteCanonicalizesTaggedModelID() throws {
        let cloudModel = try XCTUnwrap(Model(rawValue: "ollama-cloud/glm-5.2:cloud"))
        XCTAssertEqual(cloudModel.rawValue, "ollama-cloud/glm-5.2")
    }

    func testMissingOrEmptyCloudCatalogUsesVerifiedFallback() {
        XCTAssertEqual(store.cachedModels().map(\.rawValue), ["glm-5.2"])
        store.updateCachedModels([])
        XCTAssertEqual(store.cachedModels().map(\.rawValue), ["glm-5.2"])
        XCTAssertEqual(defaults[0].stringArray(forKey: "ollamaCloudModels"), [])
    }

    func testAllCasesKeepsCloudModelsDiscoverableWithoutAccessPolicy() {
        let models = Model.allCases(ollamaModels: [], ollamaCloudModels: store.cachedModels())
        XCTAssertTrue(models.contains { $0.rawValue == "ollama-cloud/glm-5.2" })
    }

    func testTwoStoresAreIndependent() throws {
        let otherStore = OllamaCloudModelStore(userDefaults: makeDefaults())
        store.updateCachedModels([try XCTUnwrap(Ollama.Model(rawValue: "first:cloud"))])
        XCTAssertEqual(otherStore.cachedModels().map(\.rawValue), ["glm-5.2"])
        otherStore.updateCachedModels([try XCTUnwrap(Ollama.Model(rawValue: "second:cloud"))])
        XCTAssertEqual(store.cachedModels().map(\.rawValue), ["first"])
        XCTAssertEqual(otherStore.cachedModels().map(\.rawValue), ["second"])
    }

    func testGetterNormalizesWithoutDeduplicatingReorderingOrRewritingSavedCatalog() {
        let saved = [" second:cloud ", "", "first", "second:cloud", " :cloud "]
        defaults[0].set(saved, forKey: "ollamaCloudModels")
        XCTAssertEqual(store.cachedModels().map(\.rawValue), ["second", "first", "second"])
        XCTAssertEqual(defaults[0].stringArray(forKey: "ollamaCloudModels"), saved)
    }

    func testInvalidSavedCatalogUsesFallbackWithoutRewriting() {
        defaults[0].set(["", " :cloud "], forKey: "ollamaCloudModels")
        XCTAssertEqual(store.cachedModels().map(\.rawValue), ["glm-5.2"])
        defaults[0].set(42, forKey: "ollamaCloudModels")
        XCTAssertEqual(store.cachedModels().map(\.rawValue), ["glm-5.2"])
        XCTAssertEqual(defaults[0].integer(forKey: "ollamaCloudModels"), 42)
    }

    func testCloudCatalogIsNormalizedAndIndependentFromLocalCatalog() throws {
        let localModel = try XCTUnwrap(Ollama.Model(rawValue: "local-model:cloud"))
        let cloudModel = try XCTUnwrap(Ollama.Model(rawValue: "hosted-model:cloud"))
        let nextModel = try XCTUnwrap(Ollama.Model(rawValue: "next-model"))
        let endpointConfiguration = OllamaEndpointConfiguration(userDefaults: defaults[0])
        let snapshot = endpointConfiguration.snapshot()
        XCTAssertTrue(endpointConfiguration.storeModels([localModel], for: snapshot))

        store.updateCachedModels([cloudModel, nextModel, cloudModel])

        XCTAssertEqual(endpointConfiguration.cachedModels().map(\.rawValue), ["local-model:cloud"])
        XCTAssertEqual(store.cachedModels().map(\.rawValue), ["hosted-model", "next-model"])
        XCTAssertEqual(defaults[0].stringArray(forKey: "ollamaCloudModels"), ["hosted-model", "next-model"])
        XCTAssertNil((defaults[0].dictionary(forKey: "ollamaModelsByEndpoint") as? [String: Any])?["hosted-model"])
    }

    func testEnumerationUsesSuppliedCatalogsAndPreservesProviderOrderAndMembership() throws {
        let local = [try XCTUnwrap(Ollama.Model(rawValue: "local:cloud"))]
        let cloud = [try XCTUnwrap(Ollama.Model(rawValue: "hosted")),
                     try XCTUnwrap(Ollama.Model(rawValue: "next-hosted"))]
        let ordinary: [Model] = Anthropic.Model.allCases.map { .anthropic($0) }
            + XAI.Model.allCases.map { .xAI($0) }
            + Gemini.Model.allCases.map { .gemini($0) }
        let independent: [Model] = local.map { .ollama($0) } + cloud.map { .ollamaCloud($0) }
        XCTAssertEqual(Model.allCases(ollamaModels: local, ollamaCloudModels: cloud),
                       OpenAI.Model.allCases.map { .openAI($0) } + ordinary + independent)
        XCTAssertEqual(Model.chatModels(ollamaModels: local, ollamaCloudModels: cloud),
                       OpenAI.Model.chatModels.map { .openAI($0) } + ordinary + independent)
        XCTAssertEqual(Model.allCases(ollamaModels: [], ollamaCloudModels: []),
                       OpenAI.Model.allCases.map { .openAI($0) } + ordinary)
        XCTAssertEqual(Model.chatModels(ollamaModels: [], ollamaCloudModels: []),
                       OpenAI.Model.chatModels.map { .openAI($0) } + ordinary)
    }
}
