//
//  LangTools+Tool.swift
//  LangTools
//
//  Created by Reid Chatham on 10/14/24.
//

import Foundation

public protocol LangToolsTool: Codable {
    associatedtype ToolSchema: LangToolsToolSchema
    var name: String { get }
    var description: String? { get }
    var tool_schema: ToolSchema { get } // JSON Schema object
    var callback: ((LangToolsRequestInfo, [String:JSON]) async throws -> String?)? { get }
    init(name: String, description: String?, tool_schema: ToolSchema, callback: ((LangToolsRequestInfo, [String:JSON]) async throws -> String?)?)
}

extension LangToolsTool {
    public init(name: String, description: String?, tool_schema: ToolSchema, callback: (([String:JSON]) async throws -> String?)?) {
        self.init(name: name, description: description, tool_schema: tool_schema) { try await callback?($1) }
    }
    public init(_ tool: any LangToolsTool) {
        self.init(name: tool.name, description: tool.description, tool_schema: ToolSchema(tool.tool_schema), callback: { try await tool.callback?($0, $1) })
    }
}

public protocol LangToolsToolSchema: Codable {
    associatedtype ToolSchemaProperty: LangToolsToolSchemaProperty
    var type: String { get }
    var properties: [String:ToolSchemaProperty] { get }
    var required: [String]? { get }
    init(type: String, properties: [String:ToolSchemaProperty], required: [String]?)
}

extension LangToolsToolSchema {
    public init(_ schema: any LangToolsToolSchema) {
        self.init(type: schema.type, properties: schema.properties.compactMapValues({ ToolSchemaProperty($0) }), required: schema.required)
    }
}

public protocol LangToolsToolSchemaProperty: Codable {
    var type: String { get }
    var enumValues: [String]? { get }
    var description: String? { get }
    init(type: String, enumValues: [String]?, description: String?)
}

extension LangToolsToolSchemaProperty {
    public init(_ property: any LangToolsToolSchemaProperty) {
        self.init(type: property.type, enumValues: property.enumValues, description: property.description)
    }
}

public struct Tool: Codable, LangToolsTool {
    public var name: String
    public var description: String?
    public var tool_schema: ToolSchema<ToolSchemaProperty>
    @CodableIgnored
    public var callback: ((LangToolsRequestInfo, [String : JSON]) async throws -> String?)?

    public init(name: String, description: String?, tool_schema: ToolSchema<ToolSchemaProperty>, callback: ((LangToolsRequestInfo, [String:JSON]) async throws -> String?)? = nil) {
        self.name = name
        self.description = description
        self.tool_schema = tool_schema
        self.callback = callback
    }
}

public struct ToolSchema<PropertySchema: LangToolsToolSchemaProperty>: LangToolsToolSchema, Codable {
    public let type: String
    public var properties: [String:PropertySchema]
    public var required: [String]?
    public init(type: String = "object", properties: [String:PropertySchema] = [:], required: [String]? = nil) {
        self.type = type
        self.properties = properties
        self.required = required
    }

    enum CodingKeys: String, CodingKey {
        case type, properties, required
    }
}

public struct ToolSchemaProperty: LangToolsToolSchemaProperty {
    public var type: String
    public var enumValues: [String]?
    public var description: String?
    public init(type: String, enumValues: [String]? = nil, description: String? = nil) {
        self.type = type
        self.enumValues = enumValues
        self.description = description
    }
    enum CodingKeys: String, CodingKey {
        case type, description
        case enumValues = "enum"
    }
}
