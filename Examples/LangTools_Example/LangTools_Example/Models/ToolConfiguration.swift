import Foundation
import SwiftUI
import LangTools
import OpenAI

/// Configuration for a tool including both functional and UI aspects
public struct ToolConfiguration {
    /// Tool identifier - must be unique
    let id: String
    
    /// Display name in the UI
    let displayName: String
    
    /// User-facing description
    let description: String
    
    /// SF Symbol icon name
    let iconName: String
    
    /// Whether this tool is an agent
    let isAgent: Bool
    
    /// Tool callback function
    let callback: (([String: JSON]) async throws -> String?)?
    
    /// Tool schema for LangTools
    let toolSchema: Tool.ToolSchema?
    
    /// Required parameters for the tool
    let requiredParameters: [String]?
    
    /// Creates a ToolConfiguration
    public init(
        id: String,
        displayName: String,
        description: String,
        iconName: String,
        isAgent: Bool = false,
        callback: (([String: JSON]) async throws -> String?)? = nil,
        toolSchema: Tool.ToolSchema? = nil,
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
    
    /// Creates an OpenAI.Tool from this configuration
    func toTool() -> OpenAI.Tool {
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
