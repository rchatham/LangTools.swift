//
//  LangTools+Tool.swift
//  LangTools
//
//  Created by Reid Chatham on 10/14/24.
//

public protocol LangToolsTool: Codable {
    associatedtype ToolSchema: LangToolsToolSchema
    var name: String { get }
    var description: String? { get }
    var tool_schema: ToolSchema { get } // JSON Schema object
    var callback: (([String:Any]) -> String?)? { get }
    init(name: String, description: String, input_schema: ToolSchema, callback: (([String:Any]) -> String?)?)
}

public protocol LangToolsToolSchema: Codable {
    associatedtype ToolSchemaProperty: LangToolsToolSchemaProperty
    var type: String { get }
    var properties: [String:ToolSchemaProperty] { get }
    var required: [String]? { get }
    init(properties: [String:ToolSchemaProperty], required: [String]?)
}

public struct ToolSchema<PropertySchema: LangToolsToolSchemaProperty>: LangToolsToolSchema, Codable {
    public let type: String = "object"
    public var properties: [String:PropertySchema]
    public var required: [String]?
    public init(properties: [String:PropertySchema] = [:], required: [String]? = nil) {
        self.properties = properties
        self.required = required
    }

    enum CodingKeys: String, CodingKey {
        case type, properties, required
    }
}

public protocol LangToolsToolSchemaProperty: Codable {
    var type: String { get }
    var enumValues: [String]? { get }
    var description: String? { get }
    init(type: String, enumValues: [String]?, description: String?)
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
