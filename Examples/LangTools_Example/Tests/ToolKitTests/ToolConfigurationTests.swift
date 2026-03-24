import XCTest
import OpenAI
import LangTools
@testable import ToolKit

final class ToolConfigurationTests: XCTestCase {

    // MARK: - Initialisation defaults

    func testDefaultValues() {
        let config = ToolConfiguration(
            id: "my_tool",
            displayName: "My Tool",
            description: "Does something",
            iconName: "star"
        )

        XCTAssertEqual(config.id, "my_tool")
        XCTAssertEqual(config.displayName, "My Tool")
        XCTAssertEqual(config.description, "Does something")
        XCTAssertEqual(config.iconName, "star")
        XCTAssertFalse(config.isAgent, "isAgent should default to false")
        XCTAssertNil(config.callback, "callback should default to nil")
        XCTAssertNil(config.toolSchema, "toolSchema should default to nil")
        XCTAssertNil(config.requiredParameters, "requiredParameters should default to nil")
    }

    func testIsAgentCanBeSetToTrue() {
        let config = ToolConfiguration(
            id: "agent_tool",
            displayName: "Agent",
            description: "An agent",
            iconName: "person",
            isAgent: true
        )
        XCTAssertTrue(config.isAgent)
    }

    // MARK: - toTool() — name and description

    func testToToolProducesCorrectNameAndDescription() {
        let config = ToolConfiguration(
            id: "weather",
            displayName: "Weather",
            description: "Gets the weather",
            iconName: "cloud"
        )
        let tool = config.toTool()
        XCTAssertEqual(tool.name, "weather")
        XCTAssertEqual(tool.description, "Gets the weather")
    }

    // MARK: - toTool() — default schema

    func testToToolDefaultSchemaHasRequestProperty() {
        let config = ToolConfiguration(
            id: "search",
            displayName: "Search",
            description: "Searches the web",
            iconName: "magnifyingglass"
        )
        let tool = config.toTool()
        XCTAssertNotNil(tool.tool_schema.properties["request"],
                        "Default schema should contain a 'request' property")
    }

    func testToToolDefaultSchemaRequiresRequest() {
        let config = ToolConfiguration(
            id: "search",
            displayName: "Search",
            description: "Searches the web",
            iconName: "magnifyingglass"
        )
        let tool = config.toTool()
        XCTAssertEqual(tool.tool_schema.required, ["request"],
                       "Default required parameters should be ['request']")
    }

    // MARK: - toTool() — custom requiredParameters

    func testToToolUsesCustomRequiredParameters() {
        let config = ToolConfiguration(
            id: "calendar",
            displayName: "Calendar",
            description: "Manages calendar events",
            iconName: "calendar",
            requiredParameters: ["date", "title"]
        )
        let tool = config.toTool()
        XCTAssertEqual(tool.tool_schema.required, ["date", "title"])
    }

    // MARK: - toTool() — custom toolSchema

    func testToToolUsesCustomSchema() {
        let customSchema = OpenAI.Tool.FunctionSchema.Parameters(
            properties: [
                "query": .init(type: "string", description: "The search query"),
                "limit": .init(type: "integer", description: "Max results")
            ],
            required: ["query"]
        )
        let config = ToolConfiguration(
            id: "search",
            displayName: "Search",
            description: "Searches the web",
            iconName: "magnifyingglass",
            toolSchema: customSchema
        )
        let tool = config.toTool()
        XCTAssertNotNil(tool.tool_schema.properties["query"])
        XCTAssertNotNil(tool.tool_schema.properties["limit"])
        XCTAssertEqual(tool.tool_schema.required, ["query"])
    }

    func testToToolCustomSchemaOverridesDefault() {
        let customSchema = OpenAI.Tool.FunctionSchema.Parameters(
            properties: ["city": .init(type: "string", description: "City name")],
            required: ["city"]
        )
        let config = ToolConfiguration(
            id: "weather",
            displayName: "Weather",
            description: "Gets weather",
            iconName: "cloud",
            toolSchema: customSchema
        )
        let tool = config.toTool()
        // Should NOT have the default 'request' property
        XCTAssertNil(tool.tool_schema.properties["request"])
        XCTAssertNotNil(tool.tool_schema.properties["city"])
    }

    // MARK: - toTool() — callback

    func testCallbackIsInvokedDirectly() async throws {
        // Verify the callback stored on ToolConfiguration is called with the right args.
        var receivedArgs: [String: JSON]?
        let config = ToolConfiguration(
            id: "ping",
            displayName: "Ping",
            description: "Pings",
            iconName: "wifi",
            callback: { args in
                receivedArgs = args
                return "pong"
            }
        )
        let result = try await config.callback?(["key": .string("value")])
        XCTAssertEqual(result, "pong")
        XCTAssertEqual(receivedArgs?["key"], .string("value"))
    }

    func testCallbackStoredOnConfigWhenProvided() {
        let config = ToolConfiguration(
            id: "ping",
            displayName: "Ping",
            description: "Pings",
            iconName: "wifi",
            callback: { _ in "pong" }
        )
        XCTAssertNotNil(config.callback)
    }

    func testNoCallbackWhenNotProvided() {
        let config = ToolConfiguration(
            id: "info",
            displayName: "Info",
            description: "Returns info",
            iconName: "info.circle"
        )
        XCTAssertNil(config.callback)
    }
}
