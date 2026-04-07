//
//  StructuredOutputTests.swift
//  AnthropicTests
//
//  Created by Reid Chatham on 1/26/25.
//

import XCTest
@testable import Anthropic
@testable import LangTools

final class AnthropicStructuredOutputTests: XCTestCase {

    // MARK: - Model Support Tests

    func testSupportedModelsForStructuredOutput() {
        // Test that Claude 4.x models support structured output
        // Check that the supported models set contains the expected models
        let supportedModels = Anthropic.Model.structuredOutputModels

        // Claude 4.5 Sonnet
        XCTAssertTrue(supportedModels.contains(.claude45Sonnet_latest), "claude45Sonnet_latest should support structured output")

        // Claude 4.1 Opus
        XCTAssertTrue(supportedModels.contains(.claude41Opus_latest), "claude41Opus_latest should support structured output")

        // Claude 4.5 Haiku
        XCTAssertTrue(supportedModels.contains(.claude45Haiku_latest), "claude45Haiku_latest should support structured output")

        // Verify supportsStructuredOutput computed property
        XCTAssertTrue(Anthropic.Model.claude45Sonnet_latest.supportsStructuredOutput)
        XCTAssertTrue(Anthropic.Model.claude41Opus_latest.supportsStructuredOutput)
        XCTAssertTrue(Anthropic.Model.claude45Haiku_latest.supportsStructuredOutput)
    }

    func testUnsupportedModelsForStructuredOutput() {
        // Test that older models do not support structured output.
        // Use rawValue init to avoid deprecated-use warnings at the call site.
        let supportedModels = Anthropic.Model.structuredOutputModels
        let retiredSonnet = Anthropic.Model(rawValue: "claude-3-5-sonnet-latest")!
        let retiredOpus   = Anthropic.Model(rawValue: "claude-3-opus-latest")!

        XCTAssertFalse(supportedModels.contains(retiredSonnet), "claude-3-5-sonnet-latest should not support structured output")
        XCTAssertFalse(supportedModels.contains(retiredOpus),   "claude-3-opus-latest should not support structured output")
        XCTAssertFalse(supportedModels.contains(.claude3Haiku_20240307), "claude3Haiku_20240307 should not support structured output")

        // Verify supportsStructuredOutput computed property
        XCTAssertFalse(retiredSonnet.supportsStructuredOutput)
        XCTAssertFalse(retiredOpus.supportsStructuredOutput)
        XCTAssertFalse(Anthropic.Model.claude3Haiku_20240307.supportsStructuredOutput)
    }

    // MARK: - Request Tests

    func testMessageRequestWithOutputFormat() throws {
        let schema = JSONSchema.object(
            properties: [
                "name": .string(),
                "age": .integer()
            ],
            required: ["name", "age"],
            additionalProperties: false
        )

        var request = Anthropic.MessageRequest(
            model: .claude45Sonnet_latest,
            messages: [Anthropic.Message(role: .user, content: "Test")],
            max_tokens: 1024
        )
        request.responseSchema = schema

        XCTAssertNotNil(request.output_config)
        XCTAssertEqual(request.output_config?.format.type, "json_schema")
        XCTAssertEqual(request.output_config?.format.schema.type, .object)
        XCTAssertTrue(request.usesStructuredOutput)
    }

    func testMessageRequestWithoutOutputFormat() throws {
        let request = Anthropic.MessageRequest(
            model: .claude45Sonnet_latest,
            messages: [Anthropic.Message(role: .user, content: "Test")],
            max_tokens: 1024
        )

        XCTAssertNil(request.output_config)
        XCTAssertNil(request.responseSchema)
        XCTAssertFalse(request.usesStructuredOutput)
    }

    func testSetResponseTypeHelper() throws {
        struct TestResponse: StructuredOutput {
            let value: String

            static var jsonSchema: JSONSchema {
                .object(
                    properties: ["value": .string()],
                    required: ["value"],
                    additionalProperties: false
                )
            }
        }

        var request = Anthropic.MessageRequest(
            model: .claude45Sonnet_latest,
            messages: [Anthropic.Message(role: .user, content: "Test")],
            max_tokens: 1024
        )
        request.setResponseType(TestResponse.self)

        XCTAssertNotNil(request.responseSchema)
        XCTAssertEqual(request.responseSchema?.type, .object)
        XCTAssertNotNil(request.responseSchema?.properties?["value"])
    }

    // MARK: - OutputConfig Encoding Tests

    func testOutputFormatEncoding() throws {
        let outputFormat = Anthropic.MessageRequest.OutputFormat(
            schema: .object(
                properties: ["test": .string()],
                required: ["test"],
                additionalProperties: false
            )
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(outputFormat)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(json?["type"] as? String, "json_schema")
        XCTAssertNotNil(json?["schema"])
    }

    func testOutputConfigEncoding() throws {
        let outputConfig = Anthropic.MessageRequest.OutputConfig(
            schema: .object(
                properties: ["test": .string()],
                required: ["test"],
                additionalProperties: false
            )
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(outputConfig)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        // output_config encodes as { "format": { "type": "json_schema", "schema": {...} } }
        XCTAssertNotNil(json?["format"])
        let format = json?["format"] as? [String: Any]
        XCTAssertEqual(format?["type"] as? String, "json_schema")
        XCTAssertNotNil(format?["schema"])
    }

    func testMessageRequestEncodingWithOutputFormat() throws {
        var request = Anthropic.MessageRequest(
            model: .claude45Sonnet_latest,
            messages: [Anthropic.Message(role: .user, content: "Test message")],
            max_tokens: 1024
        )
        request.responseSchema = .object(
            properties: ["result": .string()],
            required: ["result"],
            additionalProperties: false
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        // Now encodes as output_config.format (not output_format)
        XCTAssertNotNil(json?["output_config"])
        let outputConfig = json?["output_config"] as? [String: Any]
        XCTAssertNotNil(outputConfig?["format"])
        let format = outputConfig?["format"] as? [String: Any]
        XCTAssertEqual(format?["type"] as? String, "json_schema")
    }

    // MARK: - Response Tests

    func testMessageResponseJsonContent() throws {
        // Test that jsonContent extracts text from response
        let textContent = Anthropic.Content.ContentType.TextContent(text: "{\"name\": \"test\"}")
        let content = Anthropic.Content.array([.text(textContent)])

        let response = Anthropic.MessageResponse(
            content: content,
            id: "test-id",
            model: "claude-4-5-sonnet-latest",
            role: .assistant,
            stop_reason: .end_turn,
            stop_sequence: nil,
            type: .message,
            usage: Anthropic.MessageResponse.Usage(input_tokens: 10, output_tokens: 20)
        )

        XCTAssertEqual(response.jsonContent, "{\"name\": \"test\"}")
    }

    func testStructuredOutputDecoding() throws {
        struct TestOutput: StructuredOutput, Equatable {
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

        // Create a mock response with JSON content
        let jsonString = "{\"name\": \"test\", \"value\": 42}"
        let textContent = Anthropic.Content.ContentType.TextContent(text: jsonString)
        let content = Anthropic.Content.array([.text(textContent)])

        let response = Anthropic.MessageResponse(
            content: content,
            id: "test-id",
            model: "claude-4-5-sonnet-latest",
            role: .assistant,
            stop_reason: .end_turn,
            stop_sequence: nil,
            type: .message,
            usage: Anthropic.MessageResponse.Usage(input_tokens: 10, output_tokens: 20)
        )

        let output: TestOutput = try response.structuredOutput()

        XCTAssertEqual(output.name, "test")
        XCTAssertEqual(output.value, 42)
    }

    // MARK: - Validation Tests

    func testModelValidationError() throws {
        // Test that using structured output with unsupported model throws
        let anthropic = Anthropic(apiKey: "test-key")

        // Use rawValue init to avoid deprecated-use warning at the call site.
        let retiredModel = Anthropic.Model(rawValue: "claude-3-5-sonnet-latest")!
        var request = Anthropic.MessageRequest(
            model: retiredModel, // Unsupported model
            messages: [Anthropic.Message(role: .user, content: "Test")],
            max_tokens: 1024
        )
        request.responseSchema = JSONSchema.object(properties: ["test": .string()])

        // Verify that preparing the request throws an error
        XCTAssertThrowsError(try anthropic.prepare(request: request)) { error in
            // Check if it's the expected error type
            if case StructuredOutputError.modelDoesNotSupportStructuredOutput(let model, _) = error {
                XCTAssertEqual(model, "claude-3-5-sonnet-latest")
            } else {
                // If we get a different error, check the error description contains relevant info
                let errorString = String(describing: error)
                XCTAssertTrue(
                    errorString.contains("structured") || errorString.contains("model") || errorString.contains("support"),
                    "Error should mention structured output or model support, got: \(error)"
                )
            }
        }
    }

    func testModelValidationSuccess() throws {
        // Test that using structured output with supported model succeeds
        let anthropic = Anthropic(apiKey: "test-key")

        var request = Anthropic.MessageRequest(
            model: .claude45Sonnet_latest, // Supported model
            messages: [Anthropic.Message(role: .user, content: "Test")],
            max_tokens: 1024
        )
        request.responseSchema = JSONSchema.object(properties: ["test": .string()])

        XCTAssertNoThrow(try anthropic.prepare(request: request))
    }
}
