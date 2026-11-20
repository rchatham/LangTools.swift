//
//  CrossProviderContentConversionTests.swift
//  LangToolsTests
//

import XCTest
import LangTools
import OpenAI
@testable import Anthropic

/// Converting whole messages between OpenAI and Anthropic: empty content, multi-part text, and images.
final class CrossProviderContentConversionTests: XCTestCase {

    // MARK: - Empty content

    func testNullOpenAIContentConvertsWithoutCrashing() {
        // An assistant turn that only carried tool calls has `.null` content.
        let openAIMessage = OpenAI.Message(role: .assistant, content: .null)
        let anthropicMessage = Anthropic.Message(openAIMessage)
        XCTAssertEqual(anthropicMessage.content.string, "")
    }

    func testEmptyConvertedMessagesAreDroppedFromAnthropicRequests() {
        let messages: [any LangToolsMessage] = [
            OpenAI.Message(role: .user, content: "weather?"),
            OpenAI.Message(role: .assistant, content: .null),
            OpenAI.Message(role: .user, content: "thanks")
        ]
        let converted = Anthropic.toAnthropicMessages(messages)
        XCTAssertEqual(converted.map { $0.content.string }, ["weather?", "thanks"])
    }

    // MARK: - Text

    func testMultiPartOpenAITextConvertsToAnthropicText() throws {
        let openAIMessage = OpenAI.Message(role: .user, content: .array([.text(.init(text: "hello"))]))
        let content = try XCTUnwrap(Anthropic.Message(openAIMessage).content.array)
        guard case .text(let text) = try XCTUnwrap(content.first) else { return XCTFail("Expected text, got \(content)") }
        XCTAssertEqual(text.text, "hello")
    }

    func testMultiPartAnthropicTextConvertsToOpenAIText() throws {
        let anthropicMessage = Anthropic.Message(role: .user, content: .array([.text(.init(text: "hello"))]))
        let content = try XCTUnwrap(OpenAI.Message(anthropicMessage).content.array)
        guard case .text(let text) = try XCTUnwrap(content.first) else { return XCTFail("Expected text, got \(content)") }
        XCTAssertEqual(text.text, "hello")
    }

    // MARK: - Images

    func testOpenAIDataURLImageConvertsToAnthropicBase64() throws {
        let openAIMessage = OpenAI.Message(role: .user, content: .array([
            .text(.init(text: "look")),
            .image(.init(image_url: .init(url: "data:image/png;base64,AA==")))
        ]))
        let content = try XCTUnwrap(Anthropic.Message(openAIMessage).content.array)
        XCTAssertEqual(content.count, 2)
        guard case .image(let image) = content[1] else { return XCTFail("Expected image, got \(content[1])") }
        XCTAssertEqual(image.source.type, "base64")
        XCTAssertEqual(image.source.media_type, .png)
        XCTAssertEqual(image.source.data, "AA==")
    }

    func testOpenAIRemoteImageConvertsToAnthropicURLSource() throws {
        let openAIMessage = OpenAI.Message(role: .user, content: .array([
            .image(.init(image_url: .init(url: "https://example.com/cat.jpg")))
        ]))
        let content = try XCTUnwrap(Anthropic.Message(openAIMessage).content.array)
        guard case .image(let image) = try XCTUnwrap(content.first) else { return XCTFail("Expected image, got \(content)") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(image), as: UTF8.self)
        XCTAssertEqual(json, #"{"source":{"type":"url","url":"https:\/\/example.com\/cat.jpg"},"type":"image"}"#)
    }

    func testUnsupportedImageFormatIsDroppedInsteadOfSentAsText() throws {
        let openAIMessage = OpenAI.Message(role: .user, content: .array([
            .text(.init(text: "look")),
            .image(.init(image_url: .init(url: "data:image/bmp;base64,AA==")))
        ]))
        let content = try XCTUnwrap(Anthropic.Message(openAIMessage).content.array)
        XCTAssertEqual(content.count, 1)
    }

    func testAnthropicBase64ImageConvertsToOpenAIDataURL() throws {
        let anthropicMessage = Anthropic.Message(role: .user, content: .array([
            .image(.init(source: .init(data: "AA==", media_type: .jpeg)))
        ]))
        let content = try XCTUnwrap(OpenAI.Message(anthropicMessage).content.array)
        guard case .image(let image) = try XCTUnwrap(content.first) else { return XCTFail("Expected image, got \(content)") }
        XCTAssertEqual(image.image_url.url, "data:image/jpeg;base64,AA==")
    }

    func testAnthropicURLImageSourceRoundTrips() throws {
        let json = #"{"type":"image","source":{"type":"url","url":"https://example.com/cat.jpg"}}"#
        let image = try JSONDecoder().decode(Anthropic.Message.Content.ContentType.ImageContent.self, from: Data(json.utf8))
        XCTAssertEqual(image.source.url, "https://example.com/cat.jpg")
        XCTAssertNil(image.source.media_type)
        XCTAssertEqual(image.imageURL, "https://example.com/cat.jpg")
    }
}
