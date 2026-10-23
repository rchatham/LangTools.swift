//
//  AnthropicCompatibleTests.swift
//  AnthropicCompatibleTests
//

import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LangTools
import Anthropic
import AnthropicCompatible

/// A minimal provider serving Anthropic's Messages format.
private final class MessagesProvider: AnthropicCompatibleProvider {
    typealias Model = Anthropic.Model
    typealias ErrorResponse = AnthropicErrorResponse
    static let providerID = LangToolsProviderID(rawValue: "test.messages")

    let anthropic: Anthropic
    let anthropicAuthentication: AnthropicCompatibleAuthentication

    init(authentication: AnthropicCompatibleAuthentication = .apiKeyHeader) {
        anthropic = Anthropic(baseURL: URL(string: "https://gateway.example/v1/")!, apiKey: "key")
        anthropicAuthentication = authentication
    }
}

/// A provider that maps models to its own IDs.
private final class RenamingProvider: AnthropicCompatibleProvider {
    typealias Model = Anthropic.Model
    typealias ErrorResponse = AnthropicErrorResponse
    static let providerID = LangToolsProviderID(rawValue: "test.renaming")
    static func anthropicModelID(for model: Anthropic.Model) -> String { "renamed-\(model.rawValue)" }

    let anthropic = Anthropic(baseURL: URL(string: "https://renaming.example/v1/")!, apiKey: "key")
}

final class AnthropicCompatibleTests: XCTestCase {
    private func request(routedTo provider: LangToolsProviderID = MessagesProvider.providerID, modelID: String? = nil) -> Anthropic.MessageRequest {
        Anthropic.MessageRequest(model: .claude46Sonnet, messages: [.init(role: .user, content: "Hi")])
            .routed(to: provider, modelID: modelID)
    }

    private func body(of urlRequest: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(urlRequest.httpBody)) as? [String: Any])
    }

    func testGatewayModelIDsUseDottedVersionsWithoutSnapshotSuffixes() {
        XCTAssertEqual(Anthropic.Model.claude46Sonnet.gatewayModelID, "anthropic/claude-sonnet-4.6")
        XCTAssertEqual(Anthropic.Model.claude46Opus_20260205.gatewayModelID, "anthropic/claude-opus-4.6")
        XCTAssertEqual(Anthropic.Model.claude45Sonnet_20250929.gatewayModelID, "anthropic/claude-sonnet-4.5")
        XCTAssertEqual(Anthropic.Model.claude45Haiku_latest.gatewayModelID, "anthropic/claude-haiku-4.5")
        XCTAssertEqual(Anthropic.Model.claude41Opus_20250805.gatewayModelID, "anthropic/claude-opus-4.1")
        XCTAssertEqual(Anthropic.Model.claude4Sonnet_20250514.gatewayModelID, "anthropic/claude-sonnet-4")
        XCTAssertEqual(Anthropic.Model(rawValue: "claude-3-5-sonnet-20241022")?.gatewayModelID, "anthropic/claude-3.5-sonnet")
        XCTAssertEqual(Anthropic.Model(rawValue: "claude-3-haiku-20240307")?.gatewayModelID, "anthropic/claude-3-haiku")
    }

    func testRoutedRequestsBelongToTheProviderNotAnthropic() {
        let direct = Anthropic.MessageRequest(model: .claude46Sonnet, messages: [.init(role: .user, content: "Hi")])

        XCTAssertTrue(Anthropic(apiKey: "key").canHandleRequest(direct))
        XCTAssertFalse(MessagesProvider().canHandleRequest(direct))
        XCTAssertFalse(Anthropic(apiKey: "key").canHandleRequest(request()))
        XCTAssertTrue(MessagesProvider().canHandleRequest(request()))
        XCTAssertFalse(MessagesProvider().canHandleRequest(request(routedTo: RenamingProvider.providerID)))
    }

    func testRoutingIsNotEncoded() throws {
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request(modelID: "anthropic/claude-custom"))) as? [String: Any])

        XCTAssertEqual(body["model"] as? String, "claude-sonnet-4-6")
        XCTAssertNil(body["providerID"])
        XCTAssertNil(body["providerModelID"])
    }

    func testPrepareSendsTheGatewayModelIDWithAnthropicAuthentication() throws {
        let urlRequest = try MessagesProvider().prepare(request: request())

        XCTAssertEqual(urlRequest.url?.absoluteString, "https://gateway.example/v1/messages")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "x-api-key"), "key")
        XCTAssertNil(urlRequest.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(try body(of: urlRequest)["model"] as? String, "anthropic/claude-sonnet-4.6")
    }

    func testBearerAuthenticationReplacesTheAPIKeyHeader() throws {
        let urlRequest = try MessagesProvider(authentication: .bearer).prepare(request: request())

        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer key")
        XCTAssertNil(urlRequest.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    }

    func testExplicitModelIDsAndProviderModelMapping() throws {
        XCTAssertEqual(try body(of: MessagesProvider().prepare(request: request(modelID: "anthropic/claude-opus-5.5")))["model"] as? String, "anthropic/claude-opus-5.5")
        XCTAssertEqual(try body(of: RenamingProvider().prepare(request: request(routedTo: RenamingProvider.providerID)))["model"] as? String, "renamed-claude-sonnet-4-6")
    }

    func testChatRequestIsRoutedToTheProvider() throws {
        let chat = try MessagesProvider.chatRequest(model: Anthropic.Model.claude46Sonnet, messages: [], tools: nil, responseSchema: nil, toolEventHandler: { _ in })

        XCTAssertEqual((chat as? Anthropic.MessageRequest)?.providerID, MessagesProvider.providerID)
        XCTAssertThrowsError(try MessagesProvider.chatRequest(model: OpenAIModelStandIn.gpt, messages: [], tools: nil, responseSchema: nil, toolEventHandler: { _ in }))
    }
}

/// A model type the Messages format does not accept.
private enum OpenAIModelStandIn: String { case gpt }
