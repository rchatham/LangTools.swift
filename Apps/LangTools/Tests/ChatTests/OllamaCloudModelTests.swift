import XCTest
import Ollama
@testable import Chat

final class OllamaCloudModelTests: XCTestCase {
    private var previousCloudModels: Any?
    private var previousModelsByEndpoint: Any?

    override func setUp() {
        super.setUp()
        previousCloudModels = UserDefaults.standard.object(forKey: "ollamaCloudModels")
        previousModelsByEndpoint = UserDefaults.standard.object(forKey: "ollamaModelsByEndpoint")
        UserDefaults.standard.removeObject(forKey: "ollamaCloudModels")
        UserDefaults.standard.removeObject(forKey: "ollamaModelsByEndpoint")
    }

    override func tearDown() {
        restore(previousCloudModels, forKey: "ollamaCloudModels")
        restore(previousModelsByEndpoint, forKey: "ollamaModelsByEndpoint")
        super.tearDown()
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
        XCTAssertEqual(Model.cachedOllamaCloudModels.map(\.rawValue), ["glm-5.2"])

        Model.updateCachedOllamaCloudModels([])

        XCTAssertEqual(Model.cachedOllamaCloudModels.map(\.rawValue), ["glm-5.2"])
    }

    func testAllCasesKeepsCloudModelsDiscoverableWithoutAccessPolicy() {
        XCTAssertTrue(Model.allCases.contains(where: { $0.rawValue == "ollama-cloud/glm-5.2" }))
    }

    func testCloudCatalogIsNormalizedAndIndependentFromLocalCatalog() throws {
        let suiteName = "OllamaCloudModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let localModel = try XCTUnwrap(Ollama.Model(rawValue: "local-model:cloud"))
        let cloudModel = try XCTUnwrap(Ollama.Model(rawValue: "hosted-model:cloud"))

        // Local daemon models are stored in the endpoint-scoped cache; they must
        // not leak into the standalone Cloud catalog and must survive its updates.
        let endpointConfiguration = OllamaEndpointConfiguration(userDefaults: defaults)
        let snapshot = endpointConfiguration.snapshot()
        XCTAssertTrue(endpointConfiguration.storeModels([localModel], for: snapshot))

        Model.updateCachedOllamaCloudModels([cloudModel, cloudModel])

        XCTAssertEqual(endpointConfiguration.cachedModels().map(\.rawValue), ["local-model:cloud"])
        XCTAssertEqual(Model.cachedOllamaCloudModels.map(\.rawValue), ["hosted-model"])
        XCTAssertEqual(
            UserDefaults.standard.stringArray(forKey: "ollamaCloudModels"),
            ["hosted-model"]
        )
        XCTAssertNil((defaults.dictionary(forKey: "ollamaModelsByEndpoint") as? [String: Any])?["hosted-model"])
    }

    private func restore(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
