//
//  AnthropicGatewayRoutingTests.swift
//  AnthropicTests
//

import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LangTools
@testable import Anthropic

final class AnthropicGatewayRoutingTests: XCTestCase {

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

    func testAnthropicLeavesGatewayRoutedRequestsToTheGateway() {
        let request = Anthropic.MessageRequest(model: .claude46Sonnet, messages: [.init(role: .user, content: "Hi")])
        let routed = request.routed(to: LangToolsProviderID(rawValue: "gateway"), modelID: "anthropic/claude-custom")

        XCTAssertTrue(Anthropic(apiKey: "key").canHandleRequest(request))
        XCTAssertFalse(Anthropic(apiKey: "key").canHandleRequest(routed))
        XCTAssertEqual(routed.gatewayModelID, "anthropic/claude-custom")
    }

    func testRoutingIsNotEncoded() throws {
        let routed = Anthropic.MessageRequest(model: .claude46Sonnet, messages: [.init(role: .user, content: "Hi")])
            .routed(to: LangToolsProviderID(rawValue: "gateway"), modelID: "anthropic/claude-custom")

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(routed)) as? [String: Any])

        XCTAssertEqual(body["model"] as? String, "claude-sonnet-4-6")
        XCTAssertNil(body["gatewayProviderID"])
        XCTAssertNil(body["gatewayModelID"])
    }

    func testBearerAuthenticationReplacesTheAPIKeyHeader() throws {
        let anthropic = Anthropic(configuration: .init(apiKey: "token", authentication: .bearer))

        let urlRequest = try anthropic.prepare(request: Anthropic.MessageRequest(model: .claude46Sonnet, messages: [.init(role: .user, content: "Hi")]))

        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer token")
        XCTAssertNil(urlRequest.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    }

    func testGatewayErrorDecodesAnthropicAndOpenAIShapes() throws {
        let anthropicShape = try JSONDecoder().decode(AnthropicGatewayErrorResponse.self, from: Data(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#.utf8))
        XCTAssertEqual(anthropicShape, .init(message: "Overloaded", type: "overloaded_error"))
        let openAIShape = try JSONDecoder().decode(AnthropicGatewayErrorResponse.self, from: Data(#"{"error":{"message":"Insufficient credits","code":402}}"#.utf8))
        XCTAssertEqual(openAIShape, .init(message: "Insufficient credits"))
        XCTAssertEqual(try JSONDecoder().decode(AnthropicGatewayErrorResponse.self, from: Data(#"{"message":"Unauthorized"}"#.utf8)).message, "Unauthorized")
    }
}
