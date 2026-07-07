//
//  AnthropicToolCallEmptyInputTests.swift
//  LangTools
//
//  Created by Reid Chatham on 4/22/25.
//


import XCTest
@testable import Anthropic
@testable import LangTools
@testable import TestUtils

final class AnthropicToolCallEmptyInputTests: XCTestCase {
    
    var anthropic: Anthropic!

    override func setUp() {
        super.setUp()
        anthropic = Anthropic(apiKey: "test_key").configure(testURLSessionConfiguration: MockURLProtocol.configuration)
    }
    
    override func tearDown() {
        anthropic = nil
        super.tearDown()
    }
    
    func testToolCallWithEmptyInput() async throws {

        // Configure the mock responses
        MockURLProtocol.registerResponse(
            for: Anthropic.MessageRequest.endpoint,
            data: try self.getData(filename: "tool_call_empty_input_response")!,
            statusCode: 200
        )

        // Set up the tool with empty input
        let answerTool = Anthropic.Tool(
            name: "getAnswerToUniverse",
            description: "The answer to the universe, life, and everything.",
            tool_schema: .init(),
            callback: { _,_ in
                // Set up the completion response
                MockURLProtocol.registerResponse(
                    for: Anthropic.MessageRequest.endpoint,
                    data: try self.getData(filename: "tool_call_empty_input_completion")!,
                    statusCode: 200
                )
                return "42"
            }
        )
        
        // Create the request
        let messages = [
            Anthropic.Message(role: .user, content: "What is the answer to the universe?")
        ]
        
        let request = Anthropic.MessageRequest(
            model: .claude46Sonnet,
            messages: messages,
            tools: [answerTool]
        )

        // Perform the request
        let response = try await anthropic.perform(request: request)

        // Verify the completion response
        XCTAssertNotNil(response.message)
        XCTAssertEqual(response.message?.role, .assistant)
        XCTAssertTrue(response.message?.content.text.contains("42") ?? false)
    }
}
