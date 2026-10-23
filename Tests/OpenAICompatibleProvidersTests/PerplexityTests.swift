//
//  PerplexityTests.swift
//  OpenAICompatibleProvidersTests
//

import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LangTools
@testable import TestUtils
import OpenAI
import OpenAICompatible
import Perplexity

final class PerplexityTests: MockSessionTestCase {



    private func request(_ model: Perplexity.Model, stream: Bool? = nil) -> OpenAI.ResponsesRequest {
        OpenAI.ResponsesRequest(model: model, messages: [.init(role: .user, content: "Hi")], stream: stream)
    }

    // MARK: - Requests

    func testPrepareTargetsTheAgentEndpointWithBearerAuth() throws {
        let urlRequest = try Perplexity(apiKey: "key").prepare(request: request(.sonar))

        XCTAssertEqual(urlRequest.url?.absoluteString, "https://api.perplexity.ai/v1/agent")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer key")
        let body = try body(of: urlRequest)
        XCTAssertEqual(body["model"] as? String, "perplexity/sonar")
        XCTAssertNil(body["preset"])
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.first?["type"] as? String, "message")
    }

    func testPresetsAreSentAsPresetInsteadOfModel() throws {
        let body = try body(of: Perplexity(apiKey: "key").prepare(request: request(.high)))

        XCTAssertEqual(body["preset"] as? String, "high")
        XCTAssertNil(body["model"])
    }

    func testStructuredOutputUsesResponseFormatAndUnsupportedOptionsAreDropped() throws {
        var request = OpenAI.ResponsesRequest(
            model: "openai/gpt-5.2" as Perplexity.Model,
            messages: [.init(role: .user, content: "Hi")],
            tool_choice: .auto,
            parallel_tool_calls: true,
            metadata: ["k": "v"]
        )
        request.responseSchema = .object(properties: ["answer": .string()], title: "Answer")

        let body = try body(of: Perplexity(apiKey: "key").prepare(request: request))

        XCTAssertNil(body["text"])
        XCTAssertNil(body["tool_choice"])
        XCTAssertNil(body["parallel_tool_calls"])
        XCTAssertNil(body["metadata"])
        let format = try XCTUnwrap(body["response_format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        let schema = try XCTUnwrap(format["json_schema"] as? [String: Any])
        XCTAssertEqual(schema["name"] as? String, "Answer")
        XCTAssertEqual(schema["strict"] as? Bool, true)
        XCTAssertNotNil(schema["schema"] as? [String: Any])
        XCTAssertNil(schema["type"])
    }

    func testOnlyTaggedResponsesRequestsRouteToPerplexity() throws {
        var toolchain = LangToolchain()
        toolchain.register(OpenAI(apiKey: "openai"))
        toolchain.register(Perplexity(apiKey: "perplexity"))

        XCTAssertTrue(Perplexity(apiKey: "key").canHandleRequest(request(.fast)))
        XCTAssertFalse(OpenAI(apiKey: "key").canHandleRequest(request(.fast)))
        XCTAssertFalse(Perplexity(apiKey: "key").canHandleRequest(OpenAI.ResponsesRequest(model: .gpt4o, messages: [.init(role: .user, content: "Hi")])))
        // Perplexity no longer serves Chat Completions.
        XCTAssertFalse(Perplexity(apiKey: "key").canHandleRequest(OpenAI.ChatCompletionRequest(model: Perplexity.Model.fast, messages: [.init(role: .user, content: "Hi")])))
    }

    func testChatRequestBuildsAResponsesRequest() throws {
        let chat = try Perplexity.chatRequest(model: Perplexity.Model.medium, messages: [], tools: nil, responseSchema: nil, toolEventHandler: { _ in })

        let responses = try XCTUnwrap(chat as? OpenAI.ResponsesRequest)
        XCTAssertTrue(responses.model.belongs(to: Perplexity.providerID))
        XCTAssertFalse(Perplexity.supportsModelListing)
        XCTAssertEqual(Perplexity.knownModels.map(\.rawValue), ["fast", "low", "medium", "high", "xhigh", "perplexity/sonar"])
    }

    // MARK: - Responses

    func testCompleteResponseSkipsSearchResults() async throws {
        let response = """
        {"id":"resp_1","object":"response","created_at":1,"model":"perplexity/sonar","status":"completed","output":[{"type":"search_results","results":[{"title":"T","url":"https://example.com"}]},{"type":"message","id":"msg_1","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Answer","annotations":[{"type":"url_citation","url":"https://example.com"}]}]}],"usage":{"input_tokens":3,"output_tokens":1,"total_tokens":4,"cost":{"currency":"USD","total_cost":0.001}}}
        """
        MockURLProtocol.setHandler(for: "agent") { _ in (.success(Data(response.utf8)), 200) }

        let result = try await Perplexity(apiKey: "key", session: session).perform(request: request(.sonar))

        XCTAssertEqual(result.message?.content.string, "Answer")
        XCTAssertEqual(result.usage?.total_tokens, 4)
    }

    func testStreamAccumulatesTextAndTakesFunctionCallsFromDoneItems() async throws {
        let stream = """
        event: response.created
        data: {"type":"response.created","response":{"id":"resp_1","object":"response","created_at":1,"model":"perplexity/sonar","status":"in_progress","output":[]}}

        data: {"type":"response.output_text.delta","output_index":0,"content_index":0,"delta":"Hel"}

        data: {"type":"response.output_text.delta","output_index":0,"content_index":0,"delta":"lo"}

        data: {"type":"response.output_item.done","output_index":1,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"lookup","arguments":"{\\"q\\":\\"x\\"}"}}

        """
        MockURLProtocol.setHandler(for: "agent") { _ in (.success(Data(stream.utf8)), 200) }

        var text = ""
        var accumulated = OpenAI.ResponsesResponse.empty
        for try await chunk in Perplexity(apiKey: "key", session: session).stream(request: request(.sonar, stream: true)) {
            text += chunk.delta?.content ?? ""
            accumulated = accumulated.combining(with: chunk)
        }

        XCTAssertEqual(text, "Hello")
        let call = try XCTUnwrap(accumulated.message?.tool_calls?.first)
        XCTAssertEqual(call.id, "call_1")
        XCTAssertEqual(call.name, "lookup")
        XCTAssertEqual(call.arguments, #"{"q":"x"}"#)
    }

    func testFailedResponseThrowsItsError() async throws {
        let failed = """
        {"id":"resp_1","object":"response","created_at":1,"model":"perplexity/sonar","status":"failed","output":[],"error":{"code":"server_error","message":"Upstream failed"}}
        """
        MockURLProtocol.setHandler(for: "agent") { _ in (.success(Data(failed.utf8)), 200) }

        do {
            _ = try await Perplexity(apiKey: "key", session: session).perform(request: request(.sonar))
            XCTFail("Expected the in-band failure to throw")
        } catch LangToolsError.apiError(let error as OpenAI.ChatCompletionResponse.ResponseError) {
            XCTAssertEqual(error.message, "Upstream failed")
            XCTAssertEqual(error.code, "server_error")
        }
    }

    func testFailedStreamEventEndsTheStreamWithItsError() async throws {
        let stream = """
        data: {"type":"response.output_text.delta","output_index":0,"content_index":0,"delta":"Partial"}

        data: {"type":"response.failed","response":{"id":"resp_1","object":"response","created_at":1,"model":"perplexity/sonar","status":"failed","output":[],"error":{"message":"Rate limited"}}}

        """
        MockURLProtocol.setHandler(for: "agent") { _ in (.success(Data(stream.utf8)), 200) }

        var text = ""
        do {
            for try await chunk in Perplexity(apiKey: "key", session: session).stream(request: request(.sonar, stream: true)) {
                text += chunk.delta?.content ?? ""
            }
            XCTFail("Expected the failed event to throw")
        } catch LangToolsError.apiError(let error as OpenAI.ChatCompletionResponse.ResponseError) {
            XCTAssertEqual(error.message, "Rate limited")
        }
        XCTAssertEqual(text, "Partial")
    }

    func testHTTPErrorDecodesPerplexityErrorShapes() async throws {
        MockURLProtocol.setHandler(for: "agent") { _ in (.success(Data(#"{"error":{"message":"Invalid API key","type":"invalid_api_key","code":401}}"#.utf8)), 401) }

        do {
            _ = try await Perplexity(apiKey: "key", session: session).perform(request: request(.sonar))
            XCTFail("Expected a 401 error")
        } catch LangToolsError.responseUnsuccessful(let status, let error as OpenAICompatibleErrorResponse) {
            XCTAssertEqual(status, 401)
            XCTAssertEqual(error.message, "Invalid API key")
        }
    }
}
