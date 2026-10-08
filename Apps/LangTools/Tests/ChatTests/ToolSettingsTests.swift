import XCTest
@testable import Chat

final class ToolSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        suiteName = "ToolSettingsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Tool execution settings via UserDefaults

    func testMaxToolIterationsPersists() {
        defaults.set(5, forKey: "maxToolIterations")
        XCTAssertEqual(defaults.integer(forKey: "maxToolIterations"), 5)

        defaults.removeObject(forKey: "maxToolIterations")
        XCTAssertNil(defaults.object(forKey: "maxToolIterations"))
    }

    func testToolTimeoutSecondsPersists() {
        defaults.set(30, forKey: "toolTimeoutSeconds")
        XCTAssertEqual(defaults.integer(forKey: "toolTimeoutSeconds"), 30)

        defaults.removeObject(forKey: "toolTimeoutSeconds")
        XCTAssertNil(defaults.object(forKey: "toolTimeoutSeconds"))
    }

    func testAutoRetryFailedToolsPersists() {
        defaults.set(true, forKey: "autoRetryFailedTools")
        XCTAssertTrue(defaults.bool(forKey: "autoRetryFailedTools"))

        defaults.set(false, forKey: "autoRetryFailedTools")
        XCTAssertFalse(defaults.bool(forKey: "autoRetryFailedTools"))
    }

    func testAgentModelOverridePersists() {
        let modelID = Model.openAI(.gpt4o).rawValue
        defaults.set(modelID, forKey: "agentModelOverride")
        XCTAssertEqual(defaults.string(forKey: "agentModelOverride"), modelID)

        defaults.removeObject(forKey: "agentModelOverride")
        XCTAssertNil(defaults.string(forKey: "agentModelOverride"))
    }

    func testAgentModelOverrideRestores() {
        defaults.set(Model.openAI(.gpt41).rawValue, forKey: "agentModelOverride")
        let restored = defaults.string(forKey: "agentModelOverride").flatMap(Model.init(rawValue:))
        XCTAssertEqual(restored, .openAI(.gpt41))
    }

    func testAgentModelOverrideUnrecognizedIDReturnsNil() {
        defaults.set("openAI/unknown-future-model", forKey: "agentModelOverride")
        let restored = defaults.string(forKey: "agentModelOverride").flatMap(Model.init(rawValue:))
        XCTAssertNil(restored)
    }

    // MARK: - Shared instance sanity

    func testSharedInstanceExists() {
        let shared = ToolSettings.shared
        // Just verify the singleton exists and properties are accessible
        XCTAssertNotNil(shared)
        _ = shared.richContentEnabled
        _ = shared.keepsToolCallsInHistory
        _ = shared.autoRetryFailedTools
        _ = shared.agentModelOverride
        _ = shared.maxToolIterations
        _ = shared.toolTimeoutSeconds
    }
}