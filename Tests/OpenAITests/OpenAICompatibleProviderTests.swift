//
//  OpenAICompatibleProviderTests.swift
//  OpenAITests
//
//  The OpenAI target's hooks for compatible providers: lenient decoding,
//  in-band errors, `additionalParameters`, and provider-tagged routing.
//

import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LangTools
@testable import TestUtils
@testable import OpenAI

final class OpenAICompatibleProviderTests: MockSessionTestCase {
    private var api: OpenAI { OpenAI(apiKey: "", session: session) }
    private let gateway = LangToolsProviderID(rawValue: "example.gateway")

    private func decodeResponse(_ json: String) throws -> OpenAI.ChatCompletionResponse {
        try JSONDecoder().decode(OpenAI.ChatCompletionResponse.self, from: Data(json.utf8))
    }

    private func decodeError(_ json: String) throws -> OpenAI.ChatCompletionResponse.ResponseError {
        try JSONDecoder().decode(OpenAI.ChatCompletionResponse.ResponseError.self, from: Data(json.utf8))
    }

    private func makeRequest(model: OpenAI.Model = .gpt4o, stream: Bool? = nil) -> OpenAI.ChatCompletionRequest {
        OpenAI.ChatCompletionRequest(model: model, messages: [.init(role: .user, content: "Hi")], stream: stream)
    }

    private func encodedBody(_ request: OpenAI.ChatCompletionRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
    }

    // MARK: - Lenient response decoding

    func testDecodesGatewayResponseWithPartialUsageDetails() throws {
        let response = try decodeResponse(try XCTUnwrap(getData(filename: "chat_completion_response-openrouter")).string)

        XCTAssertEqual(response.choices.first?.message?.content.string, "Hello from a gateway.")
        let usage = try XCTUnwrap(response.usage)
        XCTAssertEqual(usage.completion_tokens_details?.reasoning_tokens, 12)
        XCTAssertEqual(usage.completion_tokens_details?.accepted_prediction_tokens, 0, "absent counts decode as zero")
        XCTAssertNil(usage.completion_tokens_details?.audio_tokens)
        XCTAssertEqual(usage.prompt_tokens_details?.cached_tokens, 4)
        XCTAssertEqual(usage.prompt_tokens_details?.audio_tokens, 0)
        XCTAssertNil(response.error)
    }

    func testUnknownEnumValuesDecodeAsNilAndKnownOnesDecode() throws {
        let unknown = try decodeResponse(#"{"id":"x","object":"chat.completion","created":0,"service_tier":"flex","choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"end_turn"}]}"#)
        XCTAssertNil(unknown.service_tier)
        XCTAssertNil(unknown.choices.first?.finish_reason)
        XCTAssertEqual(unknown.choices.first?.message?.content.string, "ok")

        let known = try decodeResponse(#"{"id":"x","object":"chat.completion.chunk","created":0,"service_tier":"default","choices":[{"index":0,"delta":{"content":""},"finish_reason":"error"}]}"#)
        XCTAssertEqual(known.service_tier, .default)
        XCTAssertEqual(known.choices.first?.finish_reason, .error)
    }

    func testResponseErrorCodesDecodeAsText() throws {
        let httpError = try decodeError(#"{"code":402,"message":"Insufficient credits","metadata":{"provider_name":"Example"}}"#)
        XCTAssertEqual(httpError.code, "402")
        XCTAssertEqual(httpError.metadata?["provider_name"]?.stringValue, "Example")
        XCTAssertEqual(httpError.errorDescription, "Insufficient credits (402)")
        XCTAssertEqual(try decodeError(#"{"code":"server_error","message":"Provider disconnected"}"#).code, "server_error")
        XCTAssertEqual(try decodeError(#"{"message":"Oops"}"#).errorDescription, "Oops")
        for body in [#"{"code":402.5,"message":"Float code"}"#, #"{"code":{"value":1},"message":"Object code"}"#] {
            XCTAssertNil(try decodeError(body).code, "an unusual code type degrades to nil")
        }
    }

    func testErrorChunkWithoutChoicesThrowsAndIsKeptWhenCombined() throws {
        XCTAssertNoThrow(try OpenAI.ChatCompletionResponse.empty.validateStreamChunk())
        let chunk = try decodeResponse(#"{"id":"x","object":"chat.completion.chunk","created":0,"error":{"code":502,"message":"Upstream failed"}}"#)

        XCTAssertTrue(chunk.choices.isEmpty)
        XCTAssertThrowsError(try chunk.validateStreamChunk()) { error in
            guard case LangToolsError.apiError(let apiError as OpenAI.ChatCompletionResponse.ResponseError) = error else { return XCTFail("Expected apiError, got \(error)") }
            XCTAssertEqual(apiError.message, "Upstream failed")
        }
        XCTAssertEqual(OpenAI.ChatCompletionResponse.empty.combining(with: chunk).error?.message, "Upstream failed")
    }

    func testResponseWithoutErrorRoundTripsUnchanged() throws {
        let response = try decodeResponse(try XCTUnwrap(getData(filename: "chat_completion_response")).string)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any])

        XCTAssertNil(encoded["error"], "an absent error must not be encoded")
        XCTAssertNil(encoded["choose"], "the client-side selector is never encoded")
        XCTAssertEqual(encoded["service_tier"] as? String, "default")
    }

    // MARK: - Streaming

    func testStreamIgnoresSSECommentsAndDecodesPartialUsage() async throws {
        MockURLProtocol.setHandler(for: OpenAI.ChatCompletionRequest.endpoint) { _ in (.success(try self.getData(filename: "chat_completion_stream-openrouter", fileExtension: "txt")!), 200) }

        var results: [OpenAI.ChatCompletionResponse] = []
        for try await response in api.stream(request: makeRequest(stream: true)) { results.append(response) }

        XCTAssertEqual(results.compactMap { $0.choices.first?.delta?.content }.joined(), "Hello, world")
        XCTAssertEqual(results.last?.usage?.completion_tokens_details?.reasoning_tokens, 24)
    }

    func testStreamThrowsInBandErrorAfterYieldingEarlierChunks() async throws {
        MockURLProtocol.setHandler(for: OpenAI.ChatCompletionRequest.endpoint) { _ in (.success(try self.getData(filename: "chat_completion_stream_error-openrouter", fileExtension: "txt")!), 200) }

        var results: [OpenAI.ChatCompletionResponse] = []
        do {
            for try await response in api.stream(request: makeRequest(stream: true)) { results.append(response) }
            XCTFail("The stream must end by throwing the in-band error")
        } catch LangToolsError.apiError(let error as OpenAI.ChatCompletionResponse.ResponseError) {
            XCTAssertEqual(error.code, "server_error")
        }
        XCTAssertEqual(results.first?.choices.first?.delta?.content, "Hello", "chunks before the error are still delivered")
    }

    func testPerformThrowsAnInBandErrorFromACompleteResponse() async throws {
        MockURLProtocol.setHandler(for: OpenAI.ChatCompletionRequest.endpoint) { _ in
            (.success(Data(#"{"id":"gen-1","object":"chat.completion","created":1,"error":{"code":502,"message":"Upstream provider error"},"choices":[{"index":0,"message":{"role":"assistant","content":""},"finish_reason":"error"}]}"#.utf8)), 200)
        }

        do {
            _ = try await api.perform(request: makeRequest())
            XCTFail("A 200 response carrying an error must throw")
        } catch LangToolsError.apiError(let error as OpenAI.ChatCompletionResponse.ResponseError) {
            XCTAssertEqual(error.code, "502")
        }
    }

    // MARK: - additionalParameters

    func testAdditionalParametersAreMergedIntoTheBody() throws {
        var request = makeRequest()
        let plain = try encodedBody(request)
        request.additionalParameters = [:]
        XCTAssertEqual(Set(try encodedBody(request).keys), Set(plain.keys))
        request.additionalParameters = ["provider": ["order": ["anthropic", "openai"]], "models": ["anthropic/claude-sonnet-4.5"]]

        let body = try encodedBody(request)

        XCTAssertEqual(body["model"] as? String, "gpt-4o")
        XCTAssertEqual(body["models"] as? [String], ["anthropic/claude-sonnet-4.5"])
        XCTAssertEqual((body["provider"] as? [String: Any])?["order"] as? [String], ["anthropic", "openai"])
        XCTAssertNil(body["additionalParameters"])
    }

    func testAdditionalParametersRejectReservedKeysThroughPrepare() throws {
        for key in ["model", "messages", "stream", "tools", "temperature", "response_format"] {
            var request = makeRequest()
            request.additionalParameters = [key: "override"]
            XCTAssertThrowsError(try OpenAI(apiKey: "k").prepare(request: request)) { error in
                guard case LangToolsError.invalidArgument(let message) = error else { return XCTFail("Expected invalidArgument, got \(error)") }
                XCTAssertTrue(message.contains(key))
            }
        }
    }

    func testReservedParameterKeysCoverEveryTypedBodyKey() throws {
        let request = OpenAI.ChatCompletionRequest(
            model: .gpt4o, messages: [.init(role: .user, content: "Hi")], temperature: 0.5, top_p: 0.9, n: 1, stream: true, stream_options: .init(include_usage: true),
            stop: .string("END"), max_tokens: 10, max_completion_tokens: 10, presence_penalty: 0, frequency_penalty: 0, logit_bias: ["1": 1], logprobs: true, top_logprobs: 1, user: "u",
            response_type: .json_object, seed: 1, tools: [.init(name: "f", description: "d", tool_schema: .init(properties: [:]))], tool_choice: .auto, parallel_tool_calls: true,
            service_tier: .auto, store: false, prediction: .init(content: .string("p")), modalities: [.text], audio: .init(voice: .alloy, format: .mp3), reasoning_effort: .low, metadata: ["k": "v"])

        let encodedKeys = Set(try encodedBody(request).keys)
        let reserved = OpenAI.ChatCompletionRequest.reservedParameterKeys

        XCTAssertTrue(encodedKeys.isSubset(of: reserved), "unreserved typed keys: \(encodedKeys.subtracting(reserved))")
        XCTAssertFalse(reserved.contains("_choose") || reserved.contains("toolEventHandler"))
    }

    // MARK: - Provider tag

    func testProviderTagIsExcludedFromEqualityAndEncoding() throws {
        let tagged = OpenAI.Model(customModelID: "openai/gpt-5", providerID: gateway)
        let untagged = OpenAI.Model(customModelID: "openai/gpt-5")

        XCTAssertEqual(tagged, untagged, "equality is by ID only")
        XCTAssertTrue(tagged.belongs(to: gateway))
        XCTAssertFalse(untagged.belongs(to: gateway))
        let encoded = try JSONEncoder().encode(tagged)
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), #""openai\/gpt-5""#)
        XCTAssertNil(try JSONDecoder().decode(OpenAI.Model.self, from: encoded).providerID, "the tag is not encoded")
    }

    func testOpenAIClaimsOnlyUntaggedModels() {
        XCTAssertTrue(OpenAI.requestValidators.contains { $0(self.makeRequest(model: .gpt4o)) })
        XCTAssertFalse(OpenAI.requestValidators.contains { $0(self.makeRequest(model: OpenAI.Model(customModelID: "gpt-4o", providerID: self.gateway))) },
                       "a model tagged for another provider must not route to OpenAI even when its ID matches")
    }

    func testRoutedRetagsADecodedRequestWithoutChangingIt() throws {
        let original = makeRequest(model: OpenAI.Model(customModelID: "openai/gpt-5", providerID: gateway), stream: true)
        let decoded = try JSONDecoder().decode(OpenAI.ChatCompletionRequest.self, from: JSONEncoder().encode(original))
        XCTAssertNil(decoded.model.providerID, "decoding drops the tag")

        let routed = decoded.routed(to: gateway)

        XCTAssertTrue(routed.model.belongs(to: gateway))
        XCTAssertEqual(routed.model.id, "openai/gpt-5")
        XCTAssertEqual(routed.stream, true)
        XCTAssertNil(decoded.model.providerID, "routed(to:) returns a copy")
    }
}
