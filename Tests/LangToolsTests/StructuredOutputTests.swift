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

    // MARK: - StructuredOutput Initializer Tests

    private struct SampleOutput: StructuredOutput {
        let name: String
        let score: Double

        static var jsonSchema: JSONSchema {
            .object(
                properties: ["name": .string(), "score": .number()],
                required: ["name", "score"],
                additionalProperties: false
            )
        }
    }

    func testInitFromJsonData() throws {
        let json = #"{"name":"Alice","score":9.5}"#
        let data = json.data(using: .utf8)!
        let output = try SampleOutput(jsonData: data)
        XCTAssertEqual(output.name, "Alice")
        XCTAssertEqual(output.score, 9.5)
    }

    func testInitFromJsonString() throws {
        let output = try SampleOutput(jsonString: #"{"name":"Bob","score":7.0}"#)
        XCTAssertEqual(output.name, "Bob")
        XCTAssertEqual(output.score, 7.0)
    }

    func testInitFromJsonStringBadUTF8ThrowsInvalidResponse() {
        // We can't easily create a non-UTF-8 string in Swift, but we can test
        // that an invalid JSON string throws decodingFailed.
        XCTAssertThrowsError(try SampleOutput(jsonString: "not-json")) { error in
            guard case StructuredOutputError.decodingFailed = error else {
                return XCTFail("Expected decodingFailed, got \(error)")
            }
        }
    }

    func testInitFromJson() throws {
        let json = JSON.object(["name": .string("Carol"), "score": .number(8.2)])
        let output = try SampleOutput(json: json)
        XCTAssertEqual(output.name, "Carol")
        XCTAssertEqual(output.score, 8.2)
    }

    // MARK: - JSONSchema.validate Tests

    func testValidateObjectSuccess() throws {
        let schema = SampleOutput.jsonSchema
        let json = JSON.object(["name": .string("Alice"), "score": .number(9.5)])
        XCTAssertNoThrow(try schema.validate(json))
    }

    func testValidateMissingRequiredKey() {
        let schema = SampleOutput.jsonSchema
        let json = JSON.object(["name": .string("Alice")])  // missing "score"
        XCTAssertThrowsError(try schema.validate(json)) { error in
            guard case StructuredOutputError.validationFailed(let path, let reason) = error else {
                return XCTFail("Expected validationFailed, got \(error)")
            }
            XCTAssertTrue(path.contains("score"), "Path should reference 'score', got '\(path)'")
            XCTAssertTrue(reason.contains("Missing"), "Reason should mention missing, got '\(reason)'")
        }
    }

    func testValidateAdditionalPropertyNotAllowed() {
        let schema = SampleOutput.jsonSchema  // additionalProperties: false
        let json = JSON.object(["name": .string("Alice"), "score": .number(9.5), "extra": .string("nope")])
        XCTAssertThrowsError(try schema.validate(json)) { error in
            guard case StructuredOutputError.validationFailed(let path, _) = error else {
                return XCTFail("Expected validationFailed, got \(error)")
            }
            XCTAssertTrue(path.contains("extra"), "Path should reference 'extra', got '\(path)'")
        }
    }

    func testValidateTypeMismatch() {
        let schema = SampleOutput.jsonSchema
        let json = JSON.object(["name": .number(42), "score": .number(9.5)])  // name should be string
        XCTAssertThrowsError(try schema.validate(json)) { error in
            guard case StructuredOutputError.validationFailed(let path, let reason) = error else {
                return XCTFail("Expected validationFailed, got \(error)")
            }
            XCTAssertTrue(path.contains("name"), "Path should reference 'name', got '\(path)'")
            XCTAssertTrue(reason.contains("string"), "Reason should mention expected type, got '\(reason)'")
        }
    }

    func testValidateTopLevelTypeMismatch() {
        let schema = SampleOutput.jsonSchema  // expects object
        let json = JSON.string("not-an-object")
        XCTAssertThrowsError(try schema.validate(json)) { error in
            guard case StructuredOutputError.validationFailed(let path, _) = error else {
                return XCTFail("Expected validationFailed, got \(error)")
            }
            XCTAssertEqual(path, "$")
        }
    }

    func testValidateEnumValueSuccess() throws {
        let schema = JSONSchema.string(enumValues: ["red", "green", "blue"])
        XCTAssertNoThrow(try schema.validate(.string("red")))
    }

    func testValidateEnumValueFailure() {
        let schema = JSONSchema.string(enumValues: ["red", "green", "blue"])
        XCTAssertThrowsError(try schema.validate(.string("purple"))) { error in
            guard case StructuredOutputError.validationFailed(_, let reason) = error else {
                return XCTFail("Expected validationFailed, got \(error)")
            }
            XCTAssertTrue(reason.contains("purple"), "Reason should mention the bad value, got '\(reason)'")
        }
    }

    func testValidateArraySuccess() throws {
        let schema = JSONSchema.array(items: .string())
        XCTAssertNoThrow(try schema.validate(.array([.string("a"), .string("b")])))
    }

    func testValidateArrayItemTypeMismatch() {
        let schema = JSONSchema.array(items: .string())
        XCTAssertThrowsError(try schema.validate(.array([.string("a"), .number(1)]))) { error in
            guard case StructuredOutputError.validationFailed(let path, _) = error else {
                return XCTFail("Expected validationFailed, got \(error)")
            }
            XCTAssertTrue(path.contains("[1]"), "Path should reference index 1, got '\(path)'")
        }
    }

    func testValidateNestedObjectRecurses() {
        let schema = JSONSchema.object(
            properties: [
                "address": .object(
                    properties: ["city": .string()],
                    required: ["city"],
                    additionalProperties: false
                )
            ],
            required: ["address"],
            additionalProperties: false
        )
        // address.city is a number instead of a string
        let json = JSON.object(["address": .object(["city": .number(42)])])
        XCTAssertThrowsError(try schema.validate(json)) { error in
            guard case StructuredOutputError.validationFailed(let path, _) = error else {
                return XCTFail("Expected validationFailed, got \(error)")
            }
            XCTAssertTrue(path.contains("city"), "Path should reference 'city', got '\(path)'")
        }
    }

    // MARK: - validated(from:) Tests

    func testValidatedFromJsonSuccess() throws {
        let json = JSON.object(["name": .string("Dave"), "score": .number(6.0)])
        let output = try SampleOutput.validated(from: json)
        XCTAssertEqual(output.name, "Dave")
        XCTAssertEqual(output.score, 6.0)
    }

    func testValidatedFromJsonValidationFailure() {
        let json = JSON.object(["name": .number(99), "score": .number(6.0)])  // name wrong type
        XCTAssertThrowsError(try SampleOutput.validated(from: json)) { error in
            guard case StructuredOutputError.validationFailed = error else {
                return XCTFail("Expected validationFailed, got \(error)")
            }
        }
    }

    func testValidatedFromDataSuccess() throws {
        let data = #"{"name":"Eve","score":5.5}"#.data(using: .utf8)!
        let output = try SampleOutput.validated(from: data)
        XCTAssertEqual(output.name, "Eve")
        XCTAssertEqual(output.score, 5.5)
    }

    // MARK: - StructuredOutputError.validationFailed Tests

    func testValidationFailedErrorDescription() {
        let error = StructuredOutputError.validationFailed(path: "$.name", reason: "Expected string, got number")
        XCTAssertEqual(error.errorDescription, "Schema validation failed at '$.name': Expected string, got number")
    }
}
