import Foundation
import LangTools
import OpenAI

/// Configuration for a tool including both functional and UI aspects.
public struct ToolConfiguration: Identifiable {
    /// Tool identifier - must be unique
    public let id: String

    /// Display name in the UI
    public let displayName: String

    /// User-facing description
    public let description: String

    /// SF Symbol icon name
    public let iconName: String

    /// Whether this tool is an agent
    public let isAgent: Bool

    /// Tool callback function
    public let callback: (([String: JSON]) async throws -> String?)?

    /// Tool schema for the generated OpenAI.Tool
    public let toolSchema: OpenAI.Tool.FunctionSchema.Parameters?

    /// Required parameters used when no custom toolSchema is provided
    public let requiredParameters: [String]?

    /// Creates a ToolConfiguration
    public init(
        id: String,
        displayName: String,
        description: String,
        iconName: String,
        isAgent: Bool = false,
        callback: (([String: JSON]) async throws -> String?)? = nil,
        toolSchema: OpenAI.Tool.FunctionSchema.Parameters? = nil,
        requiredParameters: [String]? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.iconName = iconName
        self.isAgent = isAgent
        self.callback = callback
        self.toolSchema = toolSchema
        self.requiredParameters = requiredParameters
    }

    /// Creates an OpenAI.Tool from this configuration.
    public func toTool() -> OpenAI.Tool {
        let schema = toolSchema ?? .init(
            properties: [
                "request": .init(
                    type: "string",
                    description: "The request in natural language"
                )
            ],
            required: requiredParameters ?? ["request"]
        )

        return OpenAI.Tool(
            name: id,
            description: description,
            tool_schema: schema,
            callback: callback
        )
    }
}
