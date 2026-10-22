//
//  VercelMessagesFormatTests.swift
//  OpenAICompatibleProvidersTests
//

import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LangTools
@testable import TestUtils
@testable import Anthropic
import OpenAI
import VercelAIGateway
import OpenAICompatible

final class VercelMessagesFormatTests: XCTestCase {

    var session: URLSession!

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        MockURLProtocol.resetHandlers()
        URLProtocol.unregisterClass(MockURLProtocol.self)
        super.tearDown()
    }

    private func request() -> Anthropic.MessageRequest {
        Anthropic.MessageRequest(model: .claude46Sonnet, messages: [.init(role: .user, content: "Hi")])
            .routed(to: VercelAIGateway.providerID)
    }

    func testPrepareTargetsTheGatewayWithItsModelID() throws {
        let urlRequest = try VercelAIGateway(apiKey: "key").prepare(request: request())
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(urlRequest.httpBody)) as? [String: Any])

        XCTAssertEqual(urlRequest.url?.absoluteString, "https://ai-gateway.vercel.sh/v1/messages")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer key")
        XCTAssertNil(urlRequest.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(body["model"] as? String, "anthropic/claude-sonnet-4.6")
        XCTAssertEqual(body["max_tokens"] as? Int, 4096)
    }

    func testExplicitModelIDWithAnOIDCToken() throws {
        let gateway = VercelAIGateway(apiKey: "oidc-token")
        let routed = request().routed(to: VercelAIGateway.providerID, modelID: "anthropic/claude-opus-5.5")

        let urlRequest = try gateway.prepare(request: routed)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(urlRequest.httpBody)) as? [String: Any])

        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer oidc-token")
        XCTAssertNil(urlRequest.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertEqual(body["model"] as? String, "anthropic/claude-opus-5.5")
    }

    func testToolchainKeepsDirectAndGatewayRequestsApart() throws {
        var toolchain = LangToolchain()
        toolchain.register(Anthropic(apiKey: "anthropic"))
        toolchain.register(VercelAIGateway(apiKey: "vercel"))
        let direct = Anthropic.MessageRequest(model: .claude46Sonnet, messages: [.init(role: .user, content: "Hi")])
        let chat = OpenAI.ChatCompletionRequest(model: "anthropic/claude-sonnet-4.5" as VercelAIGateway.Model, messages: [.init(role: .user, content: "Hi")])

        XCTAssertEqual(try toolchain.prepare(request: direct).url?.host, "api.anthropic.com")
        XCTAssertEqual(try toolchain.prepare(request: request()).url?.absoluteString, "https://ai-gateway.vercel.sh/v1/messages")
        XCTAssertEqual(try toolchain.prepare(request: chat).url?.absoluteString, "https://ai-gateway.vercel.sh/v1/chat/completions")
    }

    func testChatRequestIsRoutedToTheGateway() throws {
        let chat = try VercelAIGateway.chatRequest(model: Anthropic.Model.claude46Sonnet, messages: [], tools: nil, responseSchema: nil, toolEventHandler: { _ in })
        let request = try XCTUnwrap(chat as? Anthropic.MessageRequest)

        XCTAssertTrue(VercelAIGateway(apiKey: "key").canHandleRequest(request))
        XCTAssertFalse(Anthropic(apiKey: "key").canHandleRequest(request))
    }

    func testStreamsAndDecodesGatewayErrors() async throws {
        let response = try Anthropic.MessageResponse(content: .string("Hello via gateway"), id: "msg_1", model: "anthropic/claude-sonnet-4.6", role: .assistant, stop_reason: .end_turn, stop_sequence: nil, type: .message, usage: .init(input_tokens: 3, output_tokens: 4))
        MockURLProtocol.setHandler(for: Anthropic.MessageRequest.endpoint) { request in
            XCTAssertEqual(request.url?.host, "ai-gateway.vercel.sh")
            return (.success(try response.streamData()), 200)
        }
        let gateway = VercelAIGateway(apiKey: "key", session: session)

        var text = ""
        for try await chunk in gateway.stream(request: request()) {
            text += chunk.message?.content.string ?? chunk.stream?.delta?.text ?? ""
        }
        XCTAssertEqual(text, "Hello via gateway")

        MockURLProtocol.setHandler(for: Anthropic.MessageRequest.endpoint) { _ in
            (.success(Data(#"{"error":{"message":"Model not found","type":"model_not_found"}}"#.utf8)), 404)
        }
        do {
            _ = try await gateway.perform(request: request())
            XCTFail("Expected a 404")
        } catch LangToolsError.responseUnsuccessful(let status, let error as OpenAICompatibleErrorResponse) {
            XCTAssertEqual(status, 404)
            XCTAssertEqual(error.type, "model_not_found")
        }
    }
}
