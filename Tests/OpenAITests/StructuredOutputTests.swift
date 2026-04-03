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
            additionalProperties: false
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

        XCTAssertEqual(json?["type"] as? String, "json_schema")

        let jsonSchema = json?["json_schema"] as? [String: Any]
        XCTAssertNotNil(jsonSchema)
        XCTAssertEqual(jsonSchema?["name"] as? String, "test_schema")
        XCTAssertEqual(jsonSchema?["strict"] as? Bool, true)
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
            additionalProperties: false
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
                    additionalProperties: false
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
            additionalProperties: false
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
                    additionalProperties: false
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

    // MARK: - JSON Schema Format Tests

    func testJSONSchemaFormatEncoding() throws {
        let schema = JSONSchema.object(
            properties: ["test": .string()],
            required: ["test"],
            additionalProperties: false
        )

        let format = OpenAI.ChatCompletionRequest.ResponseFormat.JSONSchemaFormat(
            name: "test_format",
            schema: schema,
            strict: true
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(format)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(json?["name"] as? String, "test_format")
        XCTAssertEqual(json?["strict"] as? Bool, true)
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
            additionalProperties: false
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
