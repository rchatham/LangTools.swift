//
//  ToolRegistryTests.swift
//  ChatCLITests
//
//  Tests for the tool registry system
//

import XCTest
import Foundation
import OpenAI
import LangTools

final class ToolRegistryTests: XCTestCase {

    // MARK: - Tool Protocol Tests

    func testToolProtocolConformance() {
        // Verify that tools have required properties
        XCTAssertEqual(MockReadTool.name, "Read")
        XCTAssertFalse(MockReadTool.description.isEmpty)
        XCTAssertNotNil(MockReadTool.parametersSchema)
    }

    func testToolParametersSchema() {
        let schema = MockReadTool.parametersSchema

        XCTAssertEqual(schema.type, "object")
        XCTAssertNotNil(schema.properties["file_path"])
        XCTAssertTrue(schema.required?.contains("file_path") ?? false)
    }

    // MARK: - Registry Tests

    func testRegistryContainsDefaultTools() {
        let registry = MockToolRegistry()

        XCTAssertTrue(registry.toolNames.contains("Read"))
        XCTAssertTrue(registry.toolNames.contains("Write"))
        XCTAssertTrue(registry.toolNames.contains("Edit"))
        XCTAssertTrue(registry.toolNames.contains("Bash"))
        XCTAssertTrue(registry.toolNames.contains("Glob"))
        XCTAssertTrue(registry.toolNames.contains("Grep"))
    }

    func testRegistryToolLookup() {
        let registry = MockToolRegistry()

        XCTAssertNotNil(registry.tool(named: "Read"))
        XCTAssertNotNil(registry.tool(named: "Bash"))
        XCTAssertNil(registry.tool(named: "NonexistentTool"))
    }

    func testRegistryAsOpenAITools() {
        let registry = MockToolRegistry()
        let tools = registry.asOpenAITools()

        XCTAssertEqual(tools.count, 6)

        // Verify each tool has the expected structure
        for tool in tools {
            XCTAssertFalse(tool.name.isEmpty)
            XCTAssertNotNil(tool.description)
        }
    }

    // MARK: - Parameter Extraction Tests

    func testRequiredStringExtraction() throws {
        let params: [String: Any] = ["name": "test", "value": 42]

        let name = try params.testRequiredString("name", tool: "Test")
        XCTAssertEqual(name, "test")

        XCTAssertThrowsError(try params.testRequiredString("missing", tool: "Test"))
        XCTAssertThrowsError(try params.testRequiredString("value", tool: "Test")) // Int, not String
    }

    func testOptionalStringExtraction() {
        let params: [String: Any] = ["name": "test", "value": 42]

        XCTAssertEqual(params.testOptionalString("name"), "test")
        XCTAssertNil(params.testOptionalString("missing"))
        XCTAssertNil(params.testOptionalString("value")) // Int, not String
    }

    func testOptionalIntExtraction() {
        let params: [String: Any] = ["int": 42, "double": 3.14, "string": "not a number"]

        XCTAssertEqual(params.testOptionalInt("int"), 42)
        XCTAssertEqual(params.testOptionalInt("double"), 3) // Truncated
        XCTAssertNil(params.testOptionalInt("string"))
        XCTAssertNil(params.testOptionalInt("missing"))
    }

    func testOptionalBoolExtraction() {
        let params: [String: Any] = ["flag": true, "string": "true"]

        XCTAssertEqual(params.testOptionalBool("flag"), true)
        XCTAssertNil(params.testOptionalBool("string")) // String "true", not Bool
        XCTAssertNil(params.testOptionalBool("missing"))
    }
}

// MARK: - Mock Implementations

protocol MockExecutableTool {
    static var name: String { get }
    static var description: String { get }
    static var parametersSchema: OpenAI.Tool.FunctionSchema.Parameters { get }
    static func execute(parameters: [String: Any]) async throws -> String
}

struct MockReadTool: MockExecutableTool {
    static let name = "Read"
    static let description = "Reads a file from the filesystem"
    static let parametersSchema = OpenAI.Tool.FunctionSchema.Parameters(
        properties: [
            "file_path": .init(type: "string", description: "Path to file"),
            "offset": .init(type: "integer", description: "Line offset"),
            "limit": .init(type: "integer", description: "Line limit")
        ],
        required: ["file_path"]
    )

    static func execute(parameters: [String: Any]) async throws -> String {
        return "Mock read result"
    }
}

struct MockWriteTool: MockExecutableTool {
    static let name = "Write"
    static let description = "Writes content to a file"
    static let parametersSchema = OpenAI.Tool.FunctionSchema.Parameters(
        properties: [
            "file_path": .init(type: "string", description: "Path to file"),
            "content": .init(type: "string", description: "Content to write")
        ],
        required: ["file_path", "content"]
    )

    static func execute(parameters: [String: Any]) async throws -> String {
        return "Mock write result"
    }
}

struct MockEditTool: MockExecutableTool {
    static let name = "Edit"
    static let description = "Edits a file"
    static let parametersSchema = OpenAI.Tool.FunctionSchema.Parameters(
        properties: [
            "file_path": .init(type: "string", description: "Path to file"),
            "old_string": .init(type: "string", description: "String to find"),
            "new_string": .init(type: "string", description: "Replacement")
        ],
        required: ["file_path", "old_string", "new_string"]
    )

    static func execute(parameters: [String: Any]) async throws -> String {
        return "Mock edit result"
    }
}

struct MockBashTool: MockExecutableTool {
    static let name = "Bash"
    static let description = "Executes a bash command"
    static let parametersSchema = OpenAI.Tool.FunctionSchema.Parameters(
        properties: [
            "command": .init(type: "string", description: "Command to execute")
        ],
        required: ["command"]
    )

    static func execute(parameters: [String: Any]) async throws -> String {
        return "Mock bash result"
    }
}

struct MockGlobTool: MockExecutableTool {
    static let name = "Glob"
    static let description = "Finds files by pattern"
    static let parametersSchema = OpenAI.Tool.FunctionSchema.Parameters(
        properties: [
            "pattern": .init(type: "string", description: "Glob pattern")
        ],
        required: ["pattern"]
    )

    static func execute(parameters: [String: Any]) async throws -> String {
        return "Mock glob result"
    }
}

struct MockGrepTool: MockExecutableTool {
    static let name = "Grep"
    static let description = "Searches file contents"
    static let parametersSchema = OpenAI.Tool.FunctionSchema.Parameters(
        properties: [
            "pattern": .init(type: "string", description: "Search pattern")
        ],
        required: ["pattern"]
    )

    static func execute(parameters: [String: Any]) async throws -> String {
        return "Mock grep result"
    }
}

class MockToolRegistry {
    private var tools: [String: any MockExecutableTool.Type] = [:]

    init() {
        tools[MockReadTool.name] = MockReadTool.self
        tools[MockWriteTool.name] = MockWriteTool.self
        tools[MockEditTool.name] = MockEditTool.self
        tools[MockBashTool.name] = MockBashTool.self
        tools[MockGlobTool.name] = MockGlobTool.self
        tools[MockGrepTool.name] = MockGrepTool.self
    }

    func tool(named name: String) -> (any MockExecutableTool.Type)? {
        return tools[name]
    }

    var toolNames: [String] {
        return Array(tools.keys).sorted()
    }

    func asOpenAITools() -> [OpenAI.Tool] {
        return tools.values.map { tool in
            .function(.init(
                name: tool.name,
                description: tool.description,
                parameters: tool.parametersSchema,
                callback: nil
            ))
        }
    }
}

// MARK: - Parameter Extraction Helpers

enum MockToolError: LocalizedError {
    case missingRequiredParameter(tool: String, parameter: String)
    case invalidParameters(tool: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .missingRequiredParameter(let tool, let parameter):
            return "Missing required parameter '\(parameter)' for tool '\(tool)'"
        case .invalidParameters(let tool, let reason):
            return "Invalid parameters for tool '\(tool)': \(reason)"
        }
    }
}

extension Dictionary where Key == String, Value == Any {
    func testRequiredString(_ key: String, tool: String) throws -> String {
        guard let value = self[key] else {
            throw MockToolError.missingRequiredParameter(tool: tool, parameter: key)
        }
        guard let stringValue = value as? String else {
            throw MockToolError.invalidParameters(tool: tool, reason: "\(key) must be a string")
        }
        return stringValue
    }

    func testOptionalString(_ key: String) -> String? {
        return self[key] as? String
    }

    func testOptionalInt(_ key: String) -> Int? {
        if let intValue = self[key] as? Int {
            return intValue
        }
        if let doubleValue = self[key] as? Double {
            return Int(doubleValue)
        }
        return nil
    }

    func testOptionalBool(_ key: String) -> Bool? {
        return self[key] as? Bool
    }
}
