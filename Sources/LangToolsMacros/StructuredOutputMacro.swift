//
//  StructuredOutputMacro.swift
//  LangToolsMacros
//
//  Created by Reid Chatham on 1/26/25.
//

import Foundation

// MARK: - @StructuredOutput Macro (Placeholder)
//
// The @StructuredOutput macro automatically generates StructuredOutput conformance
// for structs, including the jsonSchema static property.
//
// Usage:
//   @StructuredOutput
//   struct WeatherCard {
//       let location: String
//       let temperature: Double
//       let condition: WeatherCondition
//
//       enum WeatherCondition: String, Codable {
//           case sunny, cloudy, rainy
//       }
//   }
//
// The macro generates:
//   extension WeatherCard: StructuredOutput {
//       static var jsonSchema: JSONSchema {
//           .object(
//               properties: [
//                   "location": .string(),
//                   "temperature": .number(),
//                   "condition": .string(enumValues: ["sunny", "cloudy", "rainy"])
//               ],
//               required: ["location", "temperature", "condition"],
//               additionalProperties: false
//           )
//       }
//   }
//
// NOTE: Full macro implementation requires SwiftSyntax and CompilerPlugin.
// For now, use manual StructuredOutput conformance or the SchemaBuilder helpers.
//
// To implement the macro:
// 1. Add SwiftSyntax dependencies to Package.swift
// 2. Create a macro target with CompilerPlugin
// 3. Implement StructuredOutputMacro using SwiftSyntaxMacros
//
// See: https://docs.swift.org/swift-book/documentation/the-swift-programming-language/macros/

// MARK: - Manual Schema Generation Helpers

import LangTools

extension JSONSchema {
    /// Create a schema for a type using reflection (limited support)
    /// Note: This is a simplified helper; for complex types, use manual schema definition
    public static func infer<T: Codable>(from type: T.Type) -> JSONSchema {
        // This is a basic implementation; full reflection would require Mirror
        // For production use, prefer explicit schema definition or macros
        return .object(properties: [:], required: [], additionalProperties: false)
    }
}

// MARK: - SchemaBuilder DSL

/// Builder for creating JSON schemas with a fluent API
public struct SchemaBuilder {
    private var properties: [String: JSONSchema] = [:]
    private var requiredProperties: [String] = []
    private var schemaDescription: String?
    private var title: String?

    public init() {}

    /// Add a string property
    public mutating func string(_ name: String, required: Bool = true, description: String? = nil, enumValues: [String]? = nil) -> SchemaBuilder {
        properties[name] = .string(description: description, enumValues: enumValues)
        if required { requiredProperties.append(name) }
        return self
    }

    /// Add a number property
    public mutating func number(_ name: String, required: Bool = true, description: String? = nil) -> SchemaBuilder {
        properties[name] = .number(description: description)
        if required { requiredProperties.append(name) }
        return self
    }

    /// Add an integer property
    public mutating func integer(_ name: String, required: Bool = true, description: String? = nil) -> SchemaBuilder {
        properties[name] = .integer(description: description)
        if required { requiredProperties.append(name) }
        return self
    }

    /// Add a boolean property
    public mutating func boolean(_ name: String, required: Bool = true, description: String? = nil) -> SchemaBuilder {
        properties[name] = .boolean(description: description)
        if required { requiredProperties.append(name) }
        return self
    }

    /// Add an array property
    public mutating func array(_ name: String, items: JSONSchema, required: Bool = true, description: String? = nil) -> SchemaBuilder {
        properties[name] = .array(items: items, description: description)
        if required { requiredProperties.append(name) }
        return self
    }

    /// Add an object property
    public mutating func object(_ name: String, schema: JSONSchema, required: Bool = true) -> SchemaBuilder {
        properties[name] = schema
        if required { requiredProperties.append(name) }
        return self
    }

    /// Set the schema description
    public mutating func description(_ description: String) -> SchemaBuilder {
        self.schemaDescription = description
        return self
    }

    /// Set the schema title
    public mutating func title(_ title: String) -> SchemaBuilder {
        self.title = title
        return self
    }

    /// Build the final JSONSchema
    public func build() -> JSONSchema {
        .object(
            properties: properties,
            required: requiredProperties.isEmpty ? nil : requiredProperties,
            additionalProperties: false,
            description: schemaDescription,
            title: title
        )
    }
}

// MARK: - Example Usage

/*
 // Manual StructuredOutput conformance example:

 struct WeatherCard: StructuredOutput {
     let location: String
     let temperature: Double
     let unit: TemperatureUnit
     let condition: WeatherCondition
     let message: String?

     enum TemperatureUnit: String, Codable {
         case celsius, fahrenheit
     }

     enum WeatherCondition: String, Codable {
         case clear, cloudy, rain, snow, storm
     }

     static var jsonSchema: JSONSchema {
         .object(
             properties: [
                 "location": .string(description: "The location for the weather"),
                 "temperature": .number(description: "The temperature value"),
                 "unit": .string(description: "Temperature unit", enumValues: ["celsius", "fahrenheit"]),
                 "condition": .string(description: "Weather condition", enumValues: ["clear", "cloudy", "rain", "snow", "storm"]),
                 "message": .string(description: "Optional message about the weather")
             ],
             required: ["location", "temperature", "unit", "condition"],
             additionalProperties: false,
             title: "WeatherCard"
         )
     }
 }

 // Or using SchemaBuilder:

 struct WeatherCard: StructuredOutput {
     // ... properties ...

     static var jsonSchema: JSONSchema {
         var builder = SchemaBuilder()
         _ = builder
             .title("WeatherCard")
             .string("location", description: "The location for the weather")
             .number("temperature", description: "The temperature value")
             .string("unit", description: "Temperature unit", enumValues: ["celsius", "fahrenheit"])
             .string("condition", description: "Weather condition", enumValues: ["clear", "cloudy", "rain", "snow", "storm"])
             .string("message", required: false, description: "Optional message about the weather")
         return builder.build()
     }
 }
 */
