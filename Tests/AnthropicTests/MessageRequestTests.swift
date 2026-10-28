//
//  MessageRequestTests.swift
//  AnthropicTests
//
//  Created by Reid Chatham on 12/15/23.
//

import XCTest
@testable import TestUtils
import Anthropic

final class MessageRequestTests: XCTestCase {
    func testMessageRequestDecodable() throws {
        Anthropic.decode { (result: Result<Anthropic.MessageRequest, Error>) in
            switch result {
            case .success(_): break
            case .failure(let error):
                XCTFail("failed to decode data \(error.localizedDescription)")
            }
        }(try getData(filename: "message_request")!)
    }

    func testMessageRequestWithImageDecodable() throws {
        Anthropic.decode { (result: Result<Anthropic.MessageRequest, Error>) in
            switch result {
            case .success(_): break
            case .failure(let error):
                XCTFail("failed to decode data \(error.localizedDescription)")
            }
        }(try getData(filename: "message_request_with_image")!)
    }

    func testMessageRequestWithFunctionsDecodable() throws {
        Anthropic.decode { (result: Result<Anthropic.MessageRequest, Error>) in
            switch result {
            case .success(_): break
            case .failure(let error):
                XCTFail("failed to decode data \(error.localizedDescription)")
            }
        }(try getData(filename: "message_request_with_tools")!)
    }

    func testMessageRequestEncodable() throws {
        let request = Anthropic.MessageRequest(
            model: .claude46Sonnet,
            messages: [
                .init(role: .user, content: "Hello, world")
            ])
        let data = try request.data()
        let testData = try getData(filename: "message_request")!
        XCTAssert(data.dictionary == testData.dictionary, "failed to correctly encode the data")
    }

    func testMessageRequestWithImageEncodable() throws {
        let request = Anthropic.MessageRequest(
            model: .claude46Sonnet,
            messages: [
                .init(role: .user, content: .array([
                    .image(.init(source: .init(data: "/9j/4AAQSkZJRg...", media_type: .jpeg))),
                    .text(.init(text: "What is in this image?")),
                ]))
            ])
        let data = try request.data()
        let testData = try getData(filename: "message_request_with_image")!
        XCTAssert(data.dictionary == testData.dictionary, "failed to correctly encode the data")
    }

    func testChatRequestFactoryPreservesNativeToolUseHistory() throws {
        let messages = [
            Anthropic.Message(
                role: .assistant,
                content: .array([
                    .text(.init(text: "Let me check.")),
                    .toolUse(.init(id: "tool-1", name: "calculate", input: #"{"expression":"1+1"}"#))
                ])
            ),
            Anthropic.Message(
                role: .user,
                content: .array([
                    .toolResult(.init(tool_selection_id: "tool-1", result: "2"))
                ])
            )
        ]

        let genericRequest = try Anthropic.chatRequest(
            model: Anthropic.Model.claude46Sonnet,
            messages: messages,
            tools: nil,
            responseSchema: nil,
            toolEventHandler: { _ in }
        )
        let request = try XCTUnwrap(genericRequest as? Anthropic.MessageRequest)

        XCTAssertEqual(request.messages.count, 2)
        XCTAssertEqual(request.messages[0].content.array?.count, 2)
        XCTAssertEqual(request.messages[0].tool_selection?.first?.id, "tool-1")
        XCTAssertEqual(request.messages[0].tool_selection?.first?.name, "calculate")
        XCTAssertEqual(request.messages[1].content.array?.first?.type, "tool_result")
    }

    func testMessageRequestWithFunctionsEncodable() throws {
        let request = Anthropic.MessageRequest(
            model: .claude46Sonnet,
            messages: [
                .init(role: .user, content: "What's the S&P 500 at today?")
            ],
            tools: [
                .init(
                    name: "get_stock_price",
                    description: "Get the current stock price for a given ticker symbol.",
                    tool_schema: .init(
                        properties: [
                            "ticker": .init(
                                type: "string",
                                description: "The stock ticker symbol, e.g. AAPL for Apple Inc."),
                        ], required: ["ticker"])),
            ],
            tool_choice: .any)
        let data = try request.data()
        let testData = try getData(filename: "message_request_with_tools")!
        XCTAssert(data.dictionary == testData.dictionary, "failed to correctly encode the data")
    }
}
