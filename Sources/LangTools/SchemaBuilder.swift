//
//  SchemaBuilder.swift
//  LangTools
//
//  Fluent builder for constructing JSONSchema objects.
//

import Foundation

/// Fluent, immutable builder for constructing JSON object schemas.
///
/// Each method returns a **new** `SchemaBuilder` value, enabling clean chaining
/// without `var` or `_ =`:
///
/// ```swift
/// let schema = SchemaBuilder()
///     .title("WeatherCard")
///     .string("location", description: "The location")
///     .number("temperature")
///     .string("unit", enumValues: ["celsius", "fahrenheit"])
///     .build()
/// ```
public struct SchemaBuilder {
    private let properties: [String: JSONSchema]
    private let requiredProperties: [String]
    private let schemaDescription: String?
    private let schemaTitle: String?

    public init() {
        self.properties = [:]
        self.requiredProperties = []
        self.schemaDescription = nil
        self.schemaTitle = nil
    }

    private init(
        properties: [String: JSONSchema],
        requiredProperties: [String],
        schemaDescription: String?,
        schemaTitle: String?
    ) {
        self.properties = properties
        self.requiredProperties = requiredProperties
        self.schemaDescription = schemaDescription
        self.schemaTitle = schemaTitle
    }

    // MARK: - Property adders

    /// Add a string property.
    public func string(_ name: String, required: Bool = true, description: String? = nil, enumValues: [String]? = nil) -> SchemaBuilder {
        adding(name: name, schema: .string(description: description, enumValues: enumValues), required: required)
    }

    /// Add a number property.
    public func number(_ name: String, required: Bool = true, description: String? = nil) -> SchemaBuilder {
        adding(name: name, schema: .number(description: description), required: required)
    }

    /// Add an integer property.
    public func integer(_ name: String, required: Bool = true, description: String? = nil) -> SchemaBuilder {
        adding(name: name, schema: .integer(description: description), required: required)
    }

    /// Add a boolean property.
    public func boolean(_ name: String, required: Bool = true, description: String? = nil) -> SchemaBuilder {
        adding(name: name, schema: .boolean(description: description), required: required)
    }

    /// Add an array property.
    public func array(_ name: String, items: JSONSchema, required: Bool = true, description: String? = nil) -> SchemaBuilder {
        adding(name: name, schema: .array(items: items, description: description), required: required)
    }

    /// Add a nested object property using an existing `JSONSchema`.
    public func object(_ name: String, schema: JSONSchema, required: Bool = true) -> SchemaBuilder {
        adding(name: name, schema: schema, required: required)
    }

    // MARK: - Metadata

    /// Set the schema description.
    public func description(_ description: String) -> SchemaBuilder {
        SchemaBuilder(properties: properties, requiredProperties: requiredProperties,
                      schemaDescription: description, schemaTitle: schemaTitle)
    }

    /// Set the schema title (also used as the `name` field in OpenAI's `json_schema` response format).
    public func title(_ title: String) -> SchemaBuilder {
        SchemaBuilder(properties: properties, requiredProperties: requiredProperties,
                      schemaDescription: schemaDescription, schemaTitle: title)
    }

    // MARK: - Terminal

    /// Build and return the final `JSONSchema`.
    public func build() -> JSONSchema {
        .object(
            properties: properties,
            required: requiredProperties.isEmpty ? nil : requiredProperties,
            additionalProperties: false,
            description: schemaDescription,
            title: schemaTitle
        )
    }

    // MARK: - Private

    private func adding(name: String, schema: JSONSchema, required: Bool) -> SchemaBuilder {
        var newProperties = properties
        newProperties[name] = schema
        let newRequired = required ? requiredProperties + [name] : requiredProperties
        return SchemaBuilder(properties: newProperties, requiredProperties: newRequired,
                             schemaDescription: schemaDescription, schemaTitle: schemaTitle)
    }
}
