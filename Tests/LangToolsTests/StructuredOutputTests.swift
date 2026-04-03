//
//  StructuredOutputTests.swift
//  LangToolsTests
//
//  Created by Reid Chatham on 1/26/25.
//

import XCTest
@testable import LangTools

final class StructuredOutputTests: XCTestCase {

    // MARK: - JSONSchema Basic Tests

    func testJSONSchemaStringType() throws {
        let schema = JSONSchema.string(description: "A test string")

        XCTAssertEqual(schema.type, .string)
        XCTAssertEqual(schema.schemaDescription, "A test string")
        XCTAssertNil(schema.properties)
        XCTAssertNil(schema.required)
    }

    func testJSONSchemaNumberType() throws {
        let schema = JSONSchema.number(description: "A test number")

        XCTAssertEqual(schema.type, .number)
        XCTAssertEqual(schema.schemaDescription, "A test number")
    }

    func testJSONSchemaIntegerType() throws {
        let schema = JSONSchema.integer(description: "A test integer")

        XCTAssertEqual(schema.type, .integer)
    }

    func testJSONSchemaBooleanType() throws {
        let schema = JSONSchema.boolean(description: "A test boolean")

        XCTAssertEqual(schema.type, .boolean)
    }

    func testJSONSchemaArrayType() throws {
        let itemsSchema = JSONSchema.string()
        let schema = JSONSchema.array(items: itemsSchema, description: "A test array")

        XCTAssertEqual(schema.type, .array)
        XCTAssertEqual(schema.items?.type, .string)
    }

    func testJSONSchemaObjectType() throws {
        let schema = JSONSchema.object(
            properties: [
                "name": .string(description: "The name"),
                "age": .integer(description: "The age")
            ],
            required: ["name"],
            additionalProperties: false,
            title: "Person"
        )

        XCTAssertEqual(schema.type, .object)
        XCTAssertEqual(schema.properties?.count, 2)
        XCTAssertEqual(schema.properties?["name"]?.type, .string)
        XCTAssertEqual(schema.properties?["age"]?.type, .integer)
        XCTAssertEqual(schema.required, ["name"])
        XCTAssertEqual(schema.additionalProperties, false)
        XCTAssertEqual(schema.title, "Person")
    }

    func testJSONSchemaEnumValues() throws {
        let schema = JSONSchema.string(
            description: "A color choice",
            enumValues: ["red", "green", "blue"]
        )

        XCTAssertEqual(schema.type, .string)
        XCTAssertEqual(schema.enumValues, ["red", "green", "blue"])
    }

    // MARK: - JSONSchema Encoding Tests

    func testJSONSchemaEncodingSimple() throws {
        let schema = JSONSchema.string(description: "A name")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(schema)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(json?["type"] as? String, "string")
        XCTAssertEqual(json?["description"] as? String, "A name")
    }

    func testJSONSchemaEncodingObject() throws {
        let schema = JSONSchema.object(
            properties: [
                "name": .string(),
                "value": .number()
            ],
            required: ["name"],
            additionalProperties: false
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(schema)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(json?["type"] as? String, "object")
        XCTAssertNotNil(json?["properties"])
        XCTAssertEqual(json?["required"] as? [String], ["name"])
        XCTAssertEqual(json?["additionalProperties"] as? Bool, false)
    }

    func testJSONSchemaEncodingEnum() throws {
        let schema = JSONSchema.string(enumValues: ["a", "b", "c"])

        let encoder = JSONEncoder()
        let data = try encoder.encode(schema)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(json?["type"] as? String, "string")
        XCTAssertEqual(json?["enum"] as? [String], ["a", "b", "c"])
    }

    // MARK: - JSONSchema Decoding Tests

    func testJSONSchemaDecodingSimple() throws {
        let jsonString = """
        {"type": "string", "description": "A test"}
        """

        let decoder = JSONDecoder()
        let schema = try decoder.decode(JSONSchema.self, from: jsonString.data(using: .utf8)!)

        XCTAssertEqual(schema.type, .string)
        XCTAssertEqual(schema.schemaDescription, "A test")
    }

    func testJSONSchemaDecodingObject() throws {
        let jsonString = """
        {
            "type": "object",
            "properties": {
                "name": {"type": "string"},
                "count": {"type": "integer"}
            },
            "required": ["name"],
            "additionalProperties": false
        }
        """

        let decoder = JSONDecoder()
        let schema = try decoder.decode(JSONSchema.self, from: jsonString.data(using: .utf8)!)

        XCTAssertEqual(schema.type, .object)
        XCTAssertEqual(schema.properties?.count, 2)
        XCTAssertEqual(schema.properties?["name"]?.type, .string)
        XCTAssertEqual(schema.properties?["count"]?.type, .integer)
        XCTAssertEqual(schema.required, ["name"])
    }

    func testJSONSchemaRoundTrip() throws {
        let original = JSONSchema.object(
            properties: [
                "location": .string(description: "The location"),
                "temperature": .number(description: "Temperature value"),
                "unit": .string(enumValues: ["celsius", "fahrenheit"]),
                "tags": .array(items: .string())
            ],
            required: ["location", "temperature", "unit"],
            additionalProperties: false,
            title: "WeatherData"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(JSONSchema.self, from: data)

        XCTAssertEqual(decoded.type, original.type)
        XCTAssertEqual(decoded.properties?.count, original.properties?.count)
        XCTAssertEqual(decoded.required, original.required)
        XCTAssertEqual(decoded.additionalProperties, original.additionalProperties)
        XCTAssertEqual(decoded.title, original.title)
    }

    // MARK: - StructuredOutput Protocol Tests

    func testStructuredOutputConformance() throws {
        // Test that a type can conform to StructuredOutput
        struct TestOutput: StructuredOutput {
            let name: String
            let value: Int

            static var jsonSchema: JSONSchema {
                .object(
                    properties: [
                        "name": .string(),
                        "value": .integer()
                    ],
                    required: ["name", "value"],
                    additionalProperties: false
                )
            }
        }

        let schema = TestOutput.jsonSchema

        XCTAssertEqual(schema.type, .object)
        XCTAssertEqual(schema.properties?.count, 2)
        XCTAssertEqual(schema.required, ["name", "value"])
    }

    func testJSONSchemaFromStructuredOutput() throws {
        struct MyResponse: StructuredOutput {
            let message: String

            static var jsonSchema: JSONSchema {
                .object(
                    properties: ["message": .string()],
                    required: ["message"],
                    additionalProperties: false
                )
            }
        }

        let schema = JSONSchema.from(MyResponse.self)

        XCTAssertEqual(schema.type, .object)
        XCTAssertEqual(schema.properties?["message"]?.type, .string)
    }

    // MARK: - NoStructuredOutput Tests

    func testNoStructuredOutput() throws {
        let schema = NoStructuredOutput.jsonSchema

        XCTAssertEqual(schema.type, .object)
        XCTAssertEqual(schema.properties?.isEmpty ?? true, true)
    }

    // MARK: - StructuredOutputError Tests

    func testStructuredOutputErrorDescriptions() {
        let error1 = StructuredOutputError.invalidResponse("Bad data")
        XCTAssertTrue(error1.errorDescription?.contains("Bad data") ?? false)

        let error2 = StructuredOutputError.modelDoesNotSupportStructuredOutput(
            model: "test-model",
            supportedModels: ["model-a", "model-b"]
        )
        XCTAssertTrue(error2.errorDescription?.contains("test-model") ?? false)
        XCTAssertTrue(error2.errorDescription?.contains("model-a") ?? false)

        let error3 = StructuredOutputError.schemaRequired
        XCTAssertNotNil(error3.errorDescription)
    }

    // MARK: - Nested Schema Tests

    func testNestedObjectSchema() throws {
        let addressSchema = JSONSchema.object(
            properties: [
                "street": .string(),
                "city": .string(),
                "zip": .string()
            ],
            required: ["street", "city"],
            additionalProperties: false
        )

        let personSchema = JSONSchema.object(
            properties: [
                "name": .string(),
                "address": addressSchema
            ],
            required: ["name"],
            additionalProperties: false
        )

        XCTAssertEqual(personSchema.type, .object)
        XCTAssertEqual(personSchema.properties?["address"]?.type, .object)
        XCTAssertEqual(personSchema.properties?["address"]?.properties?["street"]?.type, .string)
    }

    func testArrayOfObjectsSchema() throws {
        let itemSchema = JSONSchema.object(
            properties: [
                "id": .integer(),
                "name": .string()
            ],
            required: ["id", "name"],
            additionalProperties: false
        )

        let listSchema = JSONSchema.object(
            properties: [
                "items": .array(items: itemSchema)
            ],
            required: ["items"],
            additionalProperties: false
        )

        XCTAssertEqual(listSchema.properties?["items"]?.type, .array)
        XCTAssertEqual(listSchema.properties?["items"]?.items?.type, .object)
        XCTAssertEqual(listSchema.properties?["items"]?.items?.properties?["id"]?.type, .integer)
    }
}
