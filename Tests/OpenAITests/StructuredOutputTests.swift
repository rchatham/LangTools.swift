//
//  StructuredOutputTests.swift
//  OpenAITests
//
//  Created by Reid Chatham on 1/26/25.
//

import XCTest
@testable import OpenAI
@testable import LangTools

final class OpenAIStructuredOutputTests: XCTestCase {

    // MARK: - ResponseFormat Tests

    func testResponseFormatTextEncoding() throws {
        let format = OpenAI.ChatCompletionRequest.ResponseFormat.text

        let encoder = JSONEncoder()
        let data = try encoder.encode(format)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(json?["type"] as? String, "text")
        XCTAssertNil(json?["json_schema"])
    }

    func testResponseFormatJsonObjectEncoding() throws {
        let format = OpenAI.ChatCompletionRequest.ResponseFormat.json_object

        let encoder = JSONEncoder()
        let data = try encoder.encode(format)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(json?["type"] as? String, "json_object")
        XCTAssertNil(json?["json_schema"])
    }

    func testResponseFormatJsonSchemaEncoding() throws {
        let schema = JSONSchema.object(
            properties: [
                "name": .string(),
                "age": .integer()
            ],
            required: ["name", "age"],
            additionalProperties: .bool(false)
        )

        let schemaFormat = OpenAI.ChatCompletionRequest.ResponseFormat.JSONSchemaFormat(
            name: "test_schema",
            schema: schema,
            strict: true
        )
        let format = OpenAI.ChatCompletionRequest.ResponseFormat.json_schema(schemaFormat)

        let encoder = JSONEncoder()
        let data = try encoder.encode(format)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let typeStr: String? = json?["type"] as? String
        XCTAssertEqual(typeStr, "json_schema")

        let jsonSchema = json?["json_schema"] as? [String: Any]
        XCTAssertNotNil(jsonSchema)
        let schemaName: String? = jsonSchema?["name"] as? String
        let schemaStrict: Bool? = jsonSchema?["strict"] as? Bool
        XCTAssertEqual(schemaName, "test_schema")
        XCTAssertEqual(schemaStrict, true)
        XCTAssertNotNil(jsonSchema?["schema"])
    }

    func testResponseFormatDecoding() throws {
        let jsonString = """
        {
            "type": "json_schema",
            "json_schema": {
                "name": "my_schema",
                "schema": {
                    "type": "object",
                    "properties": {
                        "value": {"type": "string"}
                    }
                },
                "strict": true
            }
        }
        """

        let decoder = JSONDecoder()
        let format = try decoder.decode(
            OpenAI.ChatCompletionRequest.ResponseFormat.self,
            from: jsonString.data(using: .utf8)!
        )

        guard case .json_schema(let schemaFormat) = format else {
            XCTFail("Expected json_schema format")
            return
        }

        XCTAssertEqual(schemaFormat.name, "my_schema")
        XCTAssertEqual(schemaFormat.strict, true)
        XCTAssertEqual(schemaFormat.schema.type, JSONSchema.SchemaType.object)
    }

    // MARK: - Request Tests

    func testChatCompletionRequestWithResponseSchema() throws {
        let schema = JSONSchema.object(
            properties: [
                "result": .string(),
                "confidence": .number()
            ],
            required: ["result"],
            additionalProperties: .bool(false)
        )

        var request = OpenAI.ChatCompletionRequest(
            model: OpenAI.Model.gpt4o,
            messages: [OpenAI.Message(role: .user, content: "Test")],
            max_tokens: 1024
        )
        request.responseSchema = schema

        // Verify response_format is set correctly
        guard case .json_schema(let format) = request.response_format else {
            XCTFail("Expected json_schema response format")
            return
        }

        XCTAssertEqual(format.name, "structured_response")
        XCTAssertEqual(format.strict, true)
        XCTAssertEqual(format.schema.type, JSONSchema.SchemaType.object)
        XCTAssertTrue(request.usesStructuredOutput)
    }

    func testChatCompletionRequestWithoutResponseSchema() throws {
        let request = OpenAI.ChatCompletionRequest(
            model: OpenAI.Model.gpt4o,
            messages: [OpenAI.Message(role: .user, content: "Test")],
            max_tokens: 1024
        )

        XCTAssertNil(request.responseSchema)
        XCTAssertNil(request.response_format)
        XCTAssertFalse(request.usesStructuredOutput)
    }

    func testSetResponseTypeHelper() throws {
        struct TestResponse: StructuredOutput {
            let message: String

            static var jsonSchema: JSONSchema {
                .object(
                    properties: ["message": .string()],
                    required: ["message"],
                    additionalProperties: .bool(false)
                )
            }
        }

        var request = OpenAI.ChatCompletionRequest(
            model: OpenAI.Model.gpt4o,
            messages: [OpenAI.Message(role: .user, content: "Test")],
            max_tokens: 1024
        )
        request.setResponseType(TestResponse.self)

        XCTAssertNotNil(request.responseSchema)
        XCTAssertEqual(request.responseSchema?.type, JSONSchema.SchemaType.object)
        XCTAssertNotNil(request.responseSchema?.properties?["message"])
    }

    func testResponseSchemaRoundTrip() throws {
        var request = OpenAI.ChatCompletionRequest(
            model: OpenAI.Model.gpt4o,
            messages: [OpenAI.Message(role: .user, content: "Test")],
            max_tokens: 1024
        )

        // Set a schema
        let originalSchema = JSONSchema.object(
            properties: [
                "name": .string(description: "The name"),
                "tags": .array(items: .string())
            ],
            required: ["name"],
            additionalProperties: .bool(false)
        )
        request.responseSchema = originalSchema

        // Get it back
        let retrievedSchema = request.responseSchema

        XCTAssertEqual(retrievedSchema?.type, JSONSchema.SchemaType.object)
        XCTAssertEqual(retrievedSchema?.properties?["name"]?.type, JSONSchema.SchemaType.string)
        XCTAssertEqual(retrievedSchema?.properties?["tags"]?.type, JSONSchema.SchemaType.array)
    }

    // MARK: - Response Tests

    func testChatCompletionResponseJsonContent() throws {
        let jsonString = "{\"name\": \"test\", \"value\": 42}"
        let message = OpenAI.Message(role: .assistant, content: jsonString)
        let choice = OpenAI.ChatCompletionResponse.Choice(
            index: 0,
            message: message,
            finish_reason: .stop,
            delta: nil,
            logprobs: nil
        )

        let response = OpenAI.ChatCompletionResponse(
            id: "test-id",
            object: "chat.completion",
            created: 1234567890,
            model: "gpt-4o",
            system_fingerprint: nil,
            choices: [choice],
            usage: nil,
            service_tier: nil,
            choose: { _ in 0 }  // Return index 0 to select the first choice
        )

        XCTAssertEqual(response.jsonContent, jsonString)
    }

    func testStructuredOutputDecoding() throws {
        struct TestOutput: StructuredOutput, Equatable {
            let name: String
            let count: Int

            static var jsonSchema: JSONSchema {
                .object(
                    properties: [
                        "name": .string(),
                        "count": .integer()
                    ],
                    required: ["name", "count"],
                    additionalProperties: .bool(false)
                )
            }
        }

        let jsonString = "{\"name\": \"hello\", \"count\": 5}"
        let message = OpenAI.Message(role: .assistant, content: jsonString)
        let choice = OpenAI.ChatCompletionResponse.Choice(
            index: 0,
            message: message,
            finish_reason: .stop,
            delta: nil,
            logprobs: nil
        )

        let response = OpenAI.ChatCompletionResponse(
            id: "test-id",
            object: "chat.completion",
            created: 1234567890,
            model: "gpt-4o",
            system_fingerprint: nil,
            choices: [choice],
            usage: nil,
            service_tier: nil,
            choose: { _ in 0 }  // Return index 0 to select the first choice
        )

        let output: TestOutput = try response.structuredOutput()

        XCTAssertEqual(output.name, "hello")
        XCTAssertEqual(output.count, 5)
    }

    // MARK: - JSONSchemaFormat name sanitization

    func testSanitizeNamePassthrough() {
        // Valid names are unchanged
        XCTAssertEqual(OpenAI.ChatCompletionRequest.ResponseFormat.JSONSchemaFormat.sanitize(name: "WeatherCard"), "WeatherCard")
        XCTAssertEqual(OpenAI.ChatCompletionRequest.ResponseFormat.JSONSchemaFormat.sanitize(name: "my_schema-v2"), "my_schema-v2")
    }

    func testSanitizeNameReplacesInvalidChars() {
        // Spaces and special characters replaced with '_'
        XCTAssertEqual(OpenAI.ChatCompletionRequest.ResponseFormat.JSONSchemaFormat.sanitize(name: "My Schema"), "My_Schema")
        XCTAssertEqual(OpenAI.ChatCompletionRequest.ResponseFormat.JSONSchemaFormat.sanitize(name: "hello.world!@#"), "hello_world___")
    }

    func testSanitizeNameTruncatesTo64Chars() {
        let long = String(repeating: "a", count: 100)
        let result = OpenAI.ChatCompletionRequest.ResponseFormat.JSONSchemaFormat.sanitize(name: long)
        XCTAssertEqual(result.count, 64)
    }

    func testSanitizeNameFallsBackOnEmpty() {
        XCTAssertEqual(OpenAI.ChatCompletionRequest.ResponseFormat.JSONSchemaFormat.sanitize(name: ""), "structured_response")
        // String of only invalid chars becomes all underscores — still valid, NOT the fallback
        let allInvalid = OpenAI.ChatCompletionRequest.ResponseFormat.JSONSchemaFormat.sanitize(name: "!@#")
        XCTAssertEqual(allInvalid, "___")
    }

    func testResponseSchemaSetterSanitizesTitle() {
        // A schema whose title has spaces must be sanitized when responseSchema is set
        var request = OpenAI.ChatCompletionRequest(model: .gpt4o, messages: [OpenAI.Message]())
        request.responseSchema = JSONSchema.object(
            properties: ["x": .string()],
            title: "My Structured Response"
        )
        guard case .json_schema(let fmt) = request.response_format else {
            return XCTFail("Expected json_schema response format")
        }
        XCTAssertEqual(fmt.name, "My_Structured_Response")
    }

    // MARK: - JSON Schema Format Tests

    func testJSONSchemaFormatEncoding() throws {
        let schema = JSONSchema.object(
            properties: ["test": .string()],
            required: ["test"],
            additionalProperties: .bool(false)
        )

        let format = OpenAI.ChatCompletionRequest.ResponseFormat.JSONSchemaFormat(
            name: "test_format",
            schema: schema,
            strict: true
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(format)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let fmtName: String? = json?["name"] as? String
        let fmtStrict: Bool? = json?["strict"] as? Bool
        XCTAssertEqual(fmtName, "test_format")
        XCTAssertEqual(fmtStrict, true)
        XCTAssertNotNil(json?["schema"])
    }

    // MARK: - Full Request Encoding Tests

    func testChatCompletionRequestEncodingWithStructuredOutput() throws {
        var request = OpenAI.ChatCompletionRequest(
            model: OpenAI.Model.gpt4o,
            messages: [OpenAI.Message(role: .user, content: "Get weather for SF")],
            max_tokens: 1024
        )
        request.responseSchema = .object(
            properties: [
                "location": .string(),
                "temperature": .number()
            ],
            required: ["location", "temperature"],
            additionalProperties: .bool(false)
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        // Verify basic request fields
        XCTAssertEqual(json?["model"] as? String, "gpt-4o")
        XCTAssertNotNil(json?["messages"])

        // Verify response_format
        let responseFormat = json?["response_format"] as? [String: Any]
        XCTAssertNotNil(responseFormat)
        XCTAssertEqual(responseFormat?["type"] as? String, "json_schema")

        let jsonSchema = responseFormat?["json_schema"] as? [String: Any]
        XCTAssertNotNil(jsonSchema)
        XCTAssertEqual(jsonSchema?["name"] as? String, "structured_response")
    }

    // MARK: - Request Encoding Round-Trip

    func testChatCompletionRequestWithResponseSchemaEncodingRoundTrip() throws {
        let messages: [OpenAI.Message] = [OpenAI.Message(role: .user, content: "Test")]
        var request = OpenAI.ChatCompletionRequest(
            model: OpenAI.Model.gpt4o,
            messages: messages
        )
        request.responseSchema = JSONSchema.object(
            properties: [
                "name": JSONSchema.string(description: "The name"),
                "scores": JSONSchema.array(items: JSONSchema.integer()),
                "active": JSONSchema.boolean()
            ],
            required: ["name", "active"],
            additionalProperties: AdditionalProperties.bool(false)
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(request)
        let decoded = try JSONDecoder().decode(OpenAI.ChatCompletionRequest.self, from: data)

        // Verify the response_format round-trips correctly
        guard case .json_schema(let fmt) = decoded.response_format else {
            return XCTFail("Expected json_schema response format after round-trip")
        }
        XCTAssertEqual(fmt.name, "structured_response")
        XCTAssertTrue(fmt.strict)
        XCTAssertEqual(fmt.schema.type, JSONSchema.SchemaType.object)
        XCTAssertEqual(fmt.schema.properties?["name"]?.type, JSONSchema.SchemaType.string)
        XCTAssertEqual(fmt.schema.properties?["scores"]?.type, JSONSchema.SchemaType.array)
        XCTAssertEqual(fmt.schema.properties?["scores"]?.items?.type, JSONSchema.SchemaType.integer)
        XCTAssertEqual(fmt.schema.properties?["active"]?.type, JSONSchema.SchemaType.boolean)
        XCTAssertEqual(Set(fmt.schema.required ?? []), ["name", "active"])
        XCTAssertEqual(fmt.schema.additionalProperties, AdditionalProperties.bool(false))

        // Verify responseSchema getter also works on decoded request
        XCTAssertNotNil(decoded.responseSchema)
        XCTAssertEqual(decoded.responseSchema?.type, JSONSchema.SchemaType.object)
    }

    // MARK: - Legacy ResponseType Tests

    func testLegacyResponseTypeCompatibility() throws {
        // Create request and manually set response_format for legacy behavior
        var request = OpenAI.ChatCompletionRequest(
            model: OpenAI.Model.gpt4o,
            messages: [OpenAI.Message(role: .user, content: "Test")],
            max_tokens: 1024
        )
        request.response_format = .json_object

        guard case .json_object = request.response_format else {
            XCTFail("Expected json_object response format")
            return
        }

        // json_object response format should not set responseSchema
        XCTAssertNil(request.responseSchema)
    }
}
