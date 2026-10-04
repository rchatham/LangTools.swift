import Foundation
import XCTest
@testable import Chat

final class UserDefaultsModelMigrationTests: XCTestCase {
    private let key = "model"
    private var previousValue: Any?

    override func setUp() {
        super.setUp()
        previousValue = UserDefaults.standard.object(forKey: key)
    }

    override func tearDown() {
        if let previousValue {
            UserDefaults.standard.set(previousValue, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    func testBareGPT55MigratesToOpenAIPlatformRoute() {
        UserDefaults.standard.set("gpt-5.5", forKey: key)

        XCTAssertEqual(UserDefaults.model.rawValue, "openai/gpt-5.5")
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), "openai/gpt-5.5")
    }

    func testOnlyExplicitHistoricalCodexAliasesMigrateToCodexRoute() {
        for alias in ["gpt-5.1-codex", "gpt-5.3-codex"] {
            UserDefaults.standard.set(alias, forKey: key)
            XCTAssertEqual(UserDefaults.model.rawValue, "codex/gpt-5.3-codex-spark")
            XCTAssertEqual(UserDefaults.standard.string(forKey: key), "codex/gpt-5.3-codex-spark")
        }
    }

    func testBareCurrentCodexSlugDefaultsToOpenAIPlatformRoute() {
        UserDefaults.standard.set("gpt-5.3-codex-spark", forKey: key)

        XCTAssertEqual(UserDefaults.model.rawValue, "openai/gpt-5.3-codex-spark")
    }

    func testAlreadyRoutedModelIsUnchanged() {
        UserDefaults.standard.set("codex/gpt-5.5", forKey: key)

        XCTAssertEqual(UserDefaults.model.rawValue, "codex/gpt-5.5")
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), "codex/gpt-5.5")
    }

    func testOllamaCloudRoutePersistsIndependentlyFromLocalOllama() {
        UserDefaults.standard.set("ollama-cloud/glm-5.2", forKey: key)

        XCTAssertEqual(UserDefaults.model.rawValue, "ollama-cloud/glm-5.2")
        XCTAssertEqual(UserDefaults.model.route, .ollamaCloud)
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), "ollama-cloud/glm-5.2")
    }
}
