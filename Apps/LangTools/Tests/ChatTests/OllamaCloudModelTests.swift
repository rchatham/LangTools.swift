import XCTest
import Ollama
@testable import Chat

final class OllamaCloudModelTests: XCTestCase {
    private var previousLocalModels: Any?
    private var previousCloudModels: Any?

    override func setUp() {
        super.setUp()
        previousLocalModels = UserDefaults.standard.object(forKey: "ollamaModels")
        previousCloudModels = UserDefaults.standard.object(forKey: "ollamaCloudModels")
        UserDefaults.standard.removeObject(forKey: "ollamaModels")
        UserDefaults.standard.removeObject(forKey: "ollamaCloudModels")
    }

    override func tearDown() {
        restore(previousLocalModels, forKey: "ollamaModels")
        restore(previousCloudModels, forKey: "ollamaCloudModels")
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
        let localModel = try XCTUnwrap(Ollama.Model(rawValue: "local-model:cloud"))
        let cloudModel = try XCTUnwrap(Ollama.Model(rawValue: "hosted-model:cloud"))
        Model.updateCachedOllamaModels([localModel])
        Model.updateCachedOllamaCloudModels([cloudModel, cloudModel])

        XCTAssertEqual(Model.cachedOllamaModels.map(\.rawValue), ["local-model:cloud"])
        XCTAssertEqual(Model.cachedOllamaCloudModels.map(\.rawValue), ["hosted-model"])
        XCTAssertEqual(
            UserDefaults.standard.stringArray(forKey: "ollamaCloudModels"),
            ["hosted-model"]
        )
    }

    private func restore(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
