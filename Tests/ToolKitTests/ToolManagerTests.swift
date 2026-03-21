import XCTest
import OpenAI
@testable import ToolKit

final class ToolManagerTests: XCTestCase {

    // Each test gets its own isolated UserDefaults suite so tests don't interfere.
    private var defaults: UserDefaults!
    private var manager: ToolManager!

    override func setUp() {
        super.setUp()
        let suiteName = "ToolManagerTests.\(name)"
        // Remove any leftover data from a previous run
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)!
        manager = ToolManager(defaults: defaults)
    }

    override func tearDown() {
        manager = nil
        defaults.removePersistentDomain(forName: defaults.description)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeConfig(
        id: String,
        displayName: String = "",
        description: String = "",
        iconName: String = "star"
    ) -> ToolConfiguration {
        ToolConfiguration(id: id, displayName: displayName.isEmpty ? id : displayName,
                          description: description, iconName: iconName)
    }

    // MARK: - Registration

    func testRegisterSingleConfig() {
        let config = makeConfig(id: "search", displayName: "Search")
        manager.register(config)
        XCTAssertNotNil(manager.configuration(for: "search"))
        XCTAssertEqual(manager.configuration(for: "search")?.displayName, "Search")
    }

    func testRegisterMultipleConfigs() {
        let configs = [
            makeConfig(id: "a", displayName: "Alpha"),
            makeConfig(id: "b", displayName: "Beta"),
            makeConfig(id: "c", displayName: "Gamma"),
        ]
        manager.register(configs)
        XCTAssertEqual(manager.allToolConfigurations().count, 3)
    }

    func testRegisterOverwritesExistingConfig() {
        manager.register(makeConfig(id: "tool", displayName: "Old Name"))
        manager.register(makeConfig(id: "tool", displayName: "New Name"))
        XCTAssertEqual(manager.configuration(for: "tool")?.displayName, "New Name")
    }

    func testConfigurationForUnknownIdReturnsNil() {
        XCTAssertNil(manager.configuration(for: "nonexistent"))
    }

    // MARK: - allToolConfigurations() ordering

    func testAllToolConfigurationsSortedByDisplayName() {
        manager.register([
            makeConfig(id: "c", displayName: "Gamma"),
            makeConfig(id: "a", displayName: "Alpha"),
            makeConfig(id: "b", displayName: "Beta"),
        ])
        let names = manager.allToolConfigurations().map { $0.displayName }
        XCTAssertEqual(names, ["Alpha", "Beta", "Gamma"])
    }

    // MARK: - generateTools()

    func testGenerateToolsReturnsAllRegisteredTools() {
        manager.register([makeConfig(id: "a"), makeConfig(id: "b")])
        let tools = manager.generateTools()
        XCTAssertEqual(tools.count, 2)
        let ids = Set(tools.map { $0.name })
        XCTAssertEqual(ids, ["a", "b"])
    }

    func testGenerateToolsIgnoresEnabledState() {
        manager.register(makeConfig(id: "tool"))
        manager["tool"] = false
        // generateTools ignores enabled state — all tools are returned
        XCTAssertEqual(manager.generateTools().count, 1)
    }

    // MARK: - isToolEnabled()

    func testNewlyRegisteredToolIsEnabledByDefault() {
        manager.register(makeConfig(id: "new_tool"))
        XCTAssertTrue(manager.isToolEnabled(id: "new_tool"))
    }

    func testIsToolEnabledReturnsFalseWhenMasterSwitchOff() {
        manager.register(makeConfig(id: "tool"))
        manager.toolsEnabled = false
        XCTAssertFalse(manager.isToolEnabled(id: "tool"))
    }

    func testIsToolEnabledRespectsIndividualState() {
        manager.register(makeConfig(id: "tool"))
        manager["tool"] = false
        XCTAssertFalse(manager.isToolEnabled(id: "tool"))
    }

    func testIsToolEnabledReturnsFalseForUnregisteredId() {
        XCTAssertFalse(manager.isToolEnabled(id: "ghost"))
    }

    // MARK: - Subscript get/set

    func testSubscriptGet() {
        manager.register(makeConfig(id: "tool"))
        XCTAssertTrue(manager["tool"])
    }

    func testSubscriptSet() {
        manager.register(makeConfig(id: "tool"))
        manager["tool"] = false
        XCTAssertFalse(manager["tool"])
        manager["tool"] = true
        XCTAssertTrue(manager["tool"])
    }

    // MARK: - filteredTools()

    func testFilteredToolsReturnsNilWhenMasterSwitchOff() {
        manager.register(makeConfig(id: "tool"))
        manager.toolsEnabled = false
        XCTAssertNil(manager.filteredTools())
    }

    func testFilteredToolsReturnsEnabledToolsOnly() {
        manager.register([makeConfig(id: "a"), makeConfig(id: "b"), makeConfig(id: "c")])
        manager["b"] = false
        let filtered = manager.filteredTools()
        XCTAssertNotNil(filtered)
        let ids = Set(filtered!.map { $0.name })
        XCTAssertEqual(ids, ["a", "c"])
    }

    func testFilteredToolsReturnsAllWhenAllEnabled() {
        manager.register([makeConfig(id: "x"), makeConfig(id: "y")])
        let filtered = manager.filteredTools()
        XCTAssertNotNil(filtered)
        XCTAssertEqual(filtered!.count, 2)
    }

    func testFilteredToolsReturnsEmptyArrayNotNilWhenAllIndividuallyDisabled() {
        manager.register([makeConfig(id: "a"), makeConfig(id: "b")])
        manager["a"] = false
        manager["b"] = false
        let filtered = manager.filteredTools()
        // Master switch is on, so returns array (just empty)
        XCTAssertNotNil(filtered)
        XCTAssertTrue(filtered!.isEmpty)
    }

    // MARK: - toolsEnabled master switch side-effects

    func testDisablingMasterSwitchDisablesAllIndividualTools() {
        manager.register([makeConfig(id: "a"), makeConfig(id: "b")])
        manager.toolsEnabled = false
        XCTAssertFalse(manager["a"])
        XCTAssertFalse(manager["b"])
    }

    // MARK: - resetToDefaults()

    func testResetToDefaultsEnablesAllTools() {
        manager.register([makeConfig(id: "a"), makeConfig(id: "b")])
        manager["a"] = false
        manager.toolsEnabled = false
        manager.resetToDefaults()
        XCTAssertTrue(manager.toolsEnabled)
        XCTAssertTrue(manager["a"])
        XCTAssertTrue(manager["b"])
    }

    // MARK: - Persistence (saveSettings / re-init round-trip)

    func testPersistenceRoundTrip() {
        manager.register([makeConfig(id: "p"), makeConfig(id: "q")])
        manager["q"] = false
        manager.toolsEnabled = true
        manager.saveSettings()

        // Create a new manager backed by the same UserDefaults — simulates app relaunch
        let manager2 = ToolManager(defaults: defaults)
        // Note: toolConfigurations are not persisted (they come from app code at startup),
        // but toolsEnabled and per-tool states are.
        XCTAssertTrue(manager2.toolsEnabled)
        XCTAssertFalse(manager2["q"], "Disabled state for 'q' should survive round-trip")
        XCTAssertTrue(manager2["p"], "Enabled state for 'p' should survive round-trip")
    }

    func testPersistenceMasterSwitchOff() {
        manager.toolsEnabled = false
        manager.saveSettings()

        let manager2 = ToolManager(defaults: defaults)
        XCTAssertFalse(manager2.toolsEnabled)
    }
}
