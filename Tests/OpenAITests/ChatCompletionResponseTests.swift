//
//  ChatCompletionResponseTests.swift
//  OpenAITests
//
//  Created by Reid Chatham on 12/15/23.
//

import XCTest
@testable import TestUtils
@testable import OpenAI

final class ChatCompletionResponseTests: XCTestCase {
    func testChatCompletionResponseDecodable() throws {
        OpenAI.decode { (result: Result<OpenAI.ChatCompletionResponse, Error>) in
            switch result {
            case .success(let response):
                XCTAssert(
                    response.id == "chatcmpl-123" &&
                    response.model == "gpt-3.5-turbo-0613" &&
                    response.system_fingerprint == "fp_44709d6fcb" &&
                    response.service_tier == .default
                )
                XCTAssertEqual(response.choices[0].logprobs?.content?.first?.token, "Hello")
                XCTAssertEqual(response.choices[0].logprobs?.content?.first?.logprob, -0.5)
                XCTAssertEqual(response.usage?.completion_tokens_details?.reasoning_tokens, 5)
                XCTAssertEqual(response.usage?.completion_tokens_details?.accepted_prediction_tokens, 3)
            case .failure(let error):
                XCTFail("failed to decode data \(error.localizedDescription)")
            }
        }(try getData(filename: "chat_completion_response")!)
    }

    func testChatCompletionResponseWithToolCallDecodable() throws {
        OpenAI.decode { (result: Result<OpenAI.ChatCompletionResponse, Error>) in
            switch result {
            case .success(let response):
                XCTAssertEqual(response.system_fingerprint, "fp_44709d6fcb")
                XCTAssertEqual(response.service_tier, .default)
                XCTAssertEqual(response.usage?.completion_tokens_details?.reasoning_tokens, 10)
                XCTAssertEqual(response.choices[0].finish_reason, .tool_calls)
            case .failure(let error):
                XCTFail("failed to decode data \(error.localizedDescription)")
            }
        }(try getData(filename: "chat_completion_response_tool_call")!)
    }

    func testChatCompletionResponseEncodable() throws {
        let response = OpenAI.ChatCompletionResponse(
            id: "chatcmpl-123",
            object: "chat.completion",
            created: 1677652288,
            model: "gpt-3.5-turbo-0613",
            system_fingerprint: "fp_44709d6fcb",
            choices: [.init(
                index: 0,
                message: .init(
                    role: .assistant,
                    content: "Hello there, how may I assist you today?"),
                finish_reason: .stop,
                delta: nil,
                logprobs: nil)
            ],
            usage: .init(
                prompt_tokens: 9,
                completion_tokens: 12,
                total_tokens: 21),
            service_tier: nil,
            choose: {_ in 0}
        )
        let data = try response.data()
        let testData = try getData(filename: "chat_completion_response")!
        XCTAssert(data.dictionary == testData.dictionary, "failed to correctly encode the data")
    }
}
