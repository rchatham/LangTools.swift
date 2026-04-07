//
//  StructuredOutputMacro.swift
//  LangToolsMacros
//
//  Created by Reid Chatham on 1/26/25.
//

import Foundation

// MARK: - @StructuredOutput Macro (Placeholder)
//
// The @StructuredOutput macro will automatically generate StructuredOutput conformance
// for structs, including the `jsonSchema` static property, so you don't have to write
// it by hand.
//
// Planned usage:
//
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
// The macro will expand to:
//
//   extension WeatherCard: StructuredOutput {
//       static var jsonSchema: JSONSchema {
//           .object(
//               properties: [
//                   "location":    .string(),
//                   "temperature": .number(),
//                   "condition":   .string(enumValues: ["sunny", "cloudy", "rainy"])
//               ],
//               required: ["location", "temperature", "condition"],
//               additionalProperties: false
//           )
//       }
//   }
//
// Implementation status: PENDING
//   Full implementation requires:
//   1. Adding SwiftSyntax + SwiftCompilerPlugin dependencies to Package.swift
//   2. Creating a macro CompilerPlugin target
//   3. Implementing StructuredOutputMacro using SwiftSyntaxMacros
//
// In the meantime, use one of these alternatives:
//
//   • `JSONSchema.infer(from: MyType.self)` — automatic decoder-driven inference
//     (works for structs with synthesised Codable; see JSONSchema+Inference.swift)
//
//   • `SchemaBuilder` — fluent DSL for manual schema construction
//     (available in the LangTools module; see SchemaBuilder.swift)
//
//   • Manual `StructuredOutput` conformance — full control over the schema
//
// See: https://docs.swift.org/swift-book/documentation/the-swift-programming-language/macros/
