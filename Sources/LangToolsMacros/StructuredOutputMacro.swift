//
//  StructuredOutputMacro.swift
//  LangToolsMacros
//
//  Created by Reid Chatham on 1/26/25.
//

import Foundation

// MARK: - Schema generation for StructuredOutput types
//
// Use any of these approaches to define the `jsonSchema` required by `StructuredOutput`:
//
//   1. `@JSONSchema` macro (from the JSON package) — generates full `JSONConvertible`
//      conformance automatically from your struct's stored properties.
//
//      @JSONSchema
//      struct WeatherCard: Codable {
//          let location: String
//          let temperature: Double
//          let condition: String   // e.g. "sunny" | "cloudy" | "rainy"
//      }
//      // Then add StructuredOutput conformance (inherits jsonSchema from @JSONSchema):
//      extension WeatherCard: StructuredOutput {}
//
//   2. `JSONSchema.infer(from: MyType.self)` — decoder-driven automatic inference.
//      Works for any Decodable type with synthesised init(from:).
//
//      struct MyResponse: StructuredOutput {
//          let name: String
//          let score: Double
//          static var jsonSchema: JSONSchema { JSONSchema.infer(from: Self.self) }
//      }
//
//   3. `JSONSchema.build { }` result-builder DSL — declarative SwiftUI-style syntax.
//
//      static var jsonSchema: JSONSchema {
//          JSONSchema.build(title: "WeatherCard") {
//              JSONSchemaProperty.string("location", description: "City name")
//              JSONSchemaProperty.number("temperature")
//          }
//      }
//
//   4. `FluentSchemaBuilder` — class-based fluent chaining.
//
//      static var jsonSchema: JSONSchema {
//          FluentSchemaBuilder()
//              .string("location", description: "City name")
//              .number("temperature")
//              .build(title: "WeatherCard")
//      }
//
//   5. Manual `JSONSchema.object(properties:required:)` — explicit full control.
