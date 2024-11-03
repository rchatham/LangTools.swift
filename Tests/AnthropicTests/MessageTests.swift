//
//  MessageTests.swift
//  AnthropicTests
//
//  Created by Reid Chatham on 12/15/23.
//

import XCTest
import Anthropic

final class MessageTests: XCTestCase {
    func testUserMessageDecodable() throws {
        Anthropic.decode { (result: Result<Anthropic.Message, Error>) in
            switch result {
            case .success(_): break
            case .failure(let error):
                XCTFail("failed to decode data \(error.localizedDescription)")
            }
        }(try getData(filename: "user_message")!)
    }

    func testUserMessageWithImageDecodable() throws {
        Anthropic.decode { (result: Result<Anthropic.Message, Error>) in
            switch result {
            case .success(_): break
            case .failure(let error):
                XCTFail("failed to decode data \(error.localizedDescription)")
            }
        }(try getData(filename: "user_message_with_image")!)
    }

    func testUserMessageEncodable() throws {
        let userMessage = Anthropic.Message(role: .user, content: "Hello!")
        let json = try userMessage.data()
        let data = try getData(filename: "user_message")!
        XCTAssert(json.dictionary == data.dictionary, "user message not encoded correctly")
    }
}
