//
//  MessageRequestTests.swift
//  AnthropicTests
//
//  Created by Reid Chatham on 12/15/23.
//

import XCTest
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
            model: .claude35Sonnet_20240620,
            messages: [
                .init(role: .user, content: "Hello, world")
            ])
        let data = try request.data()
        let testData = try getData(filename: "message_request")!
        XCTAssert(data.dictionary == testData.dictionary, "failed to correctly encode the data")
    }

    func testMessageRequestWithImageEncodable() throws {
        let request = Anthropic.MessageRequest(
            model: .claude35Sonnet_20240620,
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

    func testMessageRequestWithFunctionsEncodable() throws {
        let request = Anthropic.MessageRequest(
            model: .claude35Sonnet_20240620,
            messages: [
                .init(role: .user, content: "What's the S&P 500 at today?")
            ],
            tools: [
                .init(
                    name: "get_stock_price",
                    description: "Get the current stock price for a given ticker symbol.",
                    input_schema: .init(
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
