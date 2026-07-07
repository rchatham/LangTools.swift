//
//  CrossProviderConversionTests.swift
//  LangToolsTests
//

import XCTest
import LangTools
import OpenAI
import Anthropic

/// Tests for cross-provider tool result conversion.
///
/// These tests cover the fix introduced by `LangToolsToolResultContentType`, which prevents
/// crashes when converting tool results between providers.
///
/// **Implementation note on full message conversion:**
/// `Message.init(_ message:)` converts each `ContentType` enum case via
/// `LangToolsContentType`. Since the `ContentType` enums themselves don't conform to
/// `LangToolsToolResultContentType` (only the inner structs do), tool result enum cases in
/// a full message conversion fall back to a text representation (Anthropic) or are skipped
/// (OpenAI). The critical path fixed by this PR is the direct struct-level conversion via
/// `ToolResultContent.init(_:)` and `ToolResult.init(_:)`, which is tested below.
final class CrossProviderConversionTests: XCTestCase {

    // MARK: - Direct Struct Conversion: OpenAI ToolResultContent → Anthropic ToolResult

    func testToolResultConversionOpenAIToAnthropic() throws {
        let openAIToolResult = OpenAI.Message.Content.ToolResultContent(
            tool_selection_id: "test_123",
            result: "success",
            is_error: false
        )

        let anthropicToolResult = try Anthropic.Message.Content.ContentType.ToolResult(openAIToolResult)
        XCTAssertEqual(anthropicToolResult.tool_use_id, "test_123")
        XCTAssertEqual(anthropicToolResult.result, "success")
        XCTAssertFalse(anthropicToolResult.is_error)
    }

    func testToolResultConversionOpenAIToAnthropicWithError() throws {
        let openAIToolResult = OpenAI.Message.Content.ToolResultContent(
            tool_selection_id: "test_err",
            result: "something went wrong",
            is_error: true
        )

        let anthropicToolResult = try Anthropic.Message.Content.ContentType.ToolResult(openAIToolResult)
        XCTAssertEqual(anthropicToolResult.tool_use_id, "test_err")
        XCTAssertEqual(anthropicToolResult.result, "something went wrong")
        XCTAssertTrue(anthropicToolResult.is_error)
    }

    // MARK: - Direct Struct Conversion: Anthropic ToolResult → OpenAI ToolResultContent

    func testToolResultConversionAnthropicToOpenAI() throws {
        let anthropicToolResult = Anthropic.Message.Content.ContentType.ToolResult(
            tool_selection_id: "test_456",
            result: "result data",
            is_error: true
        )

        let openAIToolResult = try OpenAI.Message.Content.ToolResultContent(anthropicToolResult)
        XCTAssertEqual(openAIToolResult.tool_selection_id, "test_456")
        XCTAssertEqual(openAIToolResult.result, "result data")
        XCTAssertTrue(openAIToolResult.is_error)
    }

    func testToolResultConversionPreservesJSONResult() throws {
        let jsonResult = "{\"temperature\": 72, \"unit\": \"fahrenheit\"}"
        let openAIToolResult = OpenAI.Message.Content.ToolResultContent(
            tool_selection_id: "weather_call_1",
            result: jsonResult
        )

        let anthropicToolResult = try Anthropic.Message.Content.ContentType.ToolResult(openAIToolResult)
        XCTAssertEqual(anthropicToolResult.result, jsonResult)
        XCTAssertEqual(anthropicToolResult.tool_use_id, "weather_call_1")
        XCTAssertFalse(anthropicToolResult.is_error)
    }

    // MARK: - ContentType-Level Conversion (passing struct directly)

    func testContentTypeConversionOpenAIToolResultToAnthropic() throws {
        let openAIToolResult = OpenAI.Message.Content.ToolResultContent(
            tool_selection_id: "call_789",
            result: "42"
        )

        // Passing the struct directly (conforms to LangToolsToolResultContentType)
        let anthropicContentType = try Anthropic.Message.Content.ContentType(openAIToolResult)
        if case .toolResult(let result) = anthropicContentType {
            XCTAssertEqual(result.tool_use_id, "call_789")
            XCTAssertEqual(result.result, "42")
        } else {
            XCTFail("Expected .toolResult content type, got \(anthropicContentType)")
        }
    }

    func testContentTypeConversionAnthropicToolResultToOpenAI() throws {
        let anthropicToolResult = Anthropic.Message.Content.ContentType.ToolResult(
            tool_selection_id: "call_abc",
            result: "done"
        )

        // Passing the struct directly (conforms to LangToolsToolResultContentType)
        let openAIContentType = try OpenAI.Message.Content.ContentType(anthropicToolResult)
        if case .toolResult(let result) = openAIContentType {
            XCTAssertEqual(result.tool_selection_id, "call_abc")
            XCTAssertEqual(result.result, "done")
        } else {
            XCTFail("Expected .toolResult content type, got \(openAIContentType)")
        }
    }

    // MARK: - Full Message Conversion (no-crash verification)
    //
    // When converting full messages, tool result ContentType enum cases don't directly
    // conform to LangToolsToolResultContentType. The Anthropic path falls back to a text
    // representation; the OpenAI path skips the element via compactMap+try?.
    // These tests verify the conversion completes without a crash.

    func testOpenAIToolMessageConversionDoesNotCrash() {
        let toolResult = OpenAI.Message.Content.ToolResultContent(
            tool_selection_id: "call_123",
            result: "{\"temperature\": 72}",
            is_error: false
        )

        let openAIMessage = OpenAI.Message(
            role: .tool,
            content: .array([.toolResult(toolResult)])
        )

        // This previously triggered a fatalError — verify it now completes without crashing.
        let anthropicMessage = Anthropic.Message(openAIMessage)
        XCTAssertNotNil(anthropicMessage)
        XCTAssertNotNil(anthropicMessage.content)
    }

    func testAnthropicToolResultMessageConversionDoesNotCrash() {
        let toolResult = Anthropic.Message.Content.ContentType.ToolResult(
            tool_selection_id: "call_456",
            result: "42",
            is_error: false
        )

        let anthropicMessage = Anthropic.Message(
            role: .user,
            content: .array([.toolResult(toolResult)])
        )

        // Verify conversion completes without crash.
        let openAIMessage = OpenAI.Message(anthropicMessage)
        XCTAssertNotNil(openAIMessage)
    }

    // MARK: - Error Cases

    func testInvalidContentTypeConversionToOpenAIToolResult() {
        let textContent = OpenAI.Message.Content.TextContent(text: "hello")
        XCTAssertThrowsError(try OpenAI.Message.Content.ToolResultContent(textContent)) { error in
            XCTAssertTrue(error is LangToolsError, "Expected LangToolsError, got \(type(of: error))")
            if case .invalidContentType = error as! LangToolsError {
                // Expected
            } else {
                XCTFail("Expected LangToolsError.invalidContentType, got \(error)")
            }
        }
    }

    func testInvalidContentTypeConversionToAnthropicToolResult() {
        let textContent = Anthropic.Message.Content.ContentType.TextContent(text: "hello")
        XCTAssertThrowsError(try Anthropic.Message.Content.ContentType.ToolResult(textContent)) { error in
            XCTAssertTrue(error is LangToolsError, "Expected LangToolsError, got \(type(of: error))")
            if case .invalidContentType = error as! LangToolsError {
                // Expected
            } else {
                XCTFail("Expected LangToolsError.invalidContentType, got \(error)")
            }
        }
    }

    func testTextContentFromAnthropicCannotConvertToOpenAIToolResult() {
        // Passing an Anthropic text content where an OpenAI tool result is expected should throw
        let anthropicText = Anthropic.Message.Content.ContentType.TextContent(text: "not a tool result")
        XCTAssertThrowsError(try OpenAI.Message.Content.ToolResultContent(anthropicText)) { error in
            XCTAssertTrue(error is LangToolsError)
        }
    }
}
