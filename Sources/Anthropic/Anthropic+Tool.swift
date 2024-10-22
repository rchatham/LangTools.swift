import Foundation
import LangTools

public extension Anthropic {
    struct Tool: Codable, LangToolsTool {
        public let name: String
        public let description: String?
        let input_schema: InputSchema // JSON Schema object
        public var tool_schema: InputSchema { input_schema }
        public var callback: (([String:Any]) -> String?)? = nil
        public init(name: String, description: String, input_schema: InputSchema = InputSchema(properties: [:]), callback: (([String:Any]) -> String?)? = nil) {
            self.name = name
            self.description = description
            self.input_schema = input_schema
            self.callback = callback
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            description = try container.decodeIfPresent(String.self, forKey: .description)
            input_schema = try container.decode(InputSchema.self, forKey: .input_schema)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(description, forKey: .description)
            try container.encode(input_schema, forKey: .input_schema)
        }

        enum CodingKeys: String, CodingKey {
            case name, description, input_schema
        }

        public struct InputSchema: Codable, LangToolsToolSchema {
            public var type: String { "object" }
            public var properties: [String:Property]
            public var required: [String]?
            public init(properties: [String : Property] = [:], required: [String]? = nil) {
                self.properties = properties
                self.required = required
            }

            public struct Property: Codable, LangToolsToolSchemaProperty {
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
        }
    }
}
