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

public extension LangToolsToolSchema {
    var type: String { "object" }
}

public struct ToolSchema<PropertySchema: LangToolsToolSchemaProperty>: LangToolsToolSchema, Codable {
    public var properties: [String:PropertySchema]
    public var required: [String]?
    public init(properties: [String:PropertySchema] = [:], required: [String]? = nil) {
        self.properties = properties
        self.required = required
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

//extension LangToolsTool {
//    public init(name: String, description: String, input_schema: LangToolsToolSchema = LangToolsToolSchema(properties: [:]), callback: (([String:Any]) -> String?)? = nil) {
//        self.name = name
//        self.description = description
//        self.input_schema = input_schema
//        self.callback = callback
//    }
//
//    public init(from decoder: Decoder) throws {
//        let container = try decoder.container(keyedBy: CodingKeys.self)
//        name = try container.decode(String.self, forKey: .name)
//        description = try container.decodeIfPresent(String.self, forKey: .description)
//        input_schema = try container.decode(InputSchema.self, forKey: .input_schema)
//    }
//
//    public func encode(to encoder: Encoder) throws {
//        var container = encoder.container(keyedBy: CodingKeys.self)
//        try container.encode(name, forKey: .name)
//        try container.encode(description, forKey: .description)
//        try container.encode(input_schema, forKey: .input_schema)
//    }
//
//    enum CodingKeys: String, CodingKey {
//        case name, description, input_schema
//    }
//}
