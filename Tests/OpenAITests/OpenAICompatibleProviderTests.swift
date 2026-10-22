//
//  OpenAICompatibleProviderTests.swift
//  OpenAITests
//
//  Covers the OpenAI target's tolerance for OpenAI-compatible providers and
//  gateways: lenient response decoding, in-band stream errors, provider-specific
//  body fields and headers, and provider-tagged routing.
//

import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LangTools
@testable import TestUtils
@testable import OpenAI

final class OpenAICompatibleProviderTests: XCTestCase {

    var api: OpenAI!

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        api = OpenAI(apiKey: "").configure(testURLSessionConfiguration: config)
    }

    override func tearDown() {
        MockURLProtocol.resetHandlers()
        URLProtocol.unregisterClass(MockURLProtocol.self)
        super.tearDown()
    }

    private func decodeResponse(_ json: String) throws -> OpenAI.ChatCompletionResponse {
        try JSONDecoder().decode(OpenAI.ChatCompletionResponse.self, from: Data(json.utf8))
    }

    private func makeRequest(model: OpenAI.Model = .gpt4o, stream: Bool? = nil) -> OpenAI.ChatCompletionRequest {
        OpenAI.ChatCompletionRequest(model: model, messages: [.init(role: .user, content: "Hi")], stream: stream)
    }

    private func encodedBody(_ request: OpenAI.ChatCompletionRequest) throws -> [String: Any] {
        let data = try JSONEncoder().encode(request)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func assertInvalidArgument(_ expression: @autoclosure () throws -> Any, containing fragment: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard case LangToolsError.invalidArgument(let message) = error else {
                return XCTFail("Expected invalidArgument, got \(error)", file: file, line: line)
            }
            XCTAssertTrue(message.contains(fragment), "\(message) should mention \(fragment)", file: file, line: line)
        }
    }

    // MARK: - Lenient response decoding

    func testDecodesGatewayResponseWithPartialUsageDetails() throws {
        let response = try decodeResponse(try XCTUnwrap(getData(filename: "chat_completion_response-openrouter")).string)

        XCTAssertEqual(response.model, "anthropic/claude-sonnet-4.5")
        XCTAssertEqual(response.choices.first?.finish_reason, .stop)
        XCTAssertEqual(response.choices.first?.message?.content.string, "Hello from a gateway.")
        let usage = try XCTUnwrap(response.usage)
        XCTAssertEqual(usage.total_tokens, 34)
        XCTAssertEqual(usage.completion_tokens_details?.reasoning_tokens, 12)
        XCTAssertEqual(usage.completion_tokens_details?.accepted_prediction_tokens, 0, "absent counts decode as zero")
        XCTAssertEqual(usage.completion_tokens_details?.rejected_prediction_tokens, 0)
        XCTAssertNil(usage.completion_tokens_details?.audio_tokens)
        XCTAssertEqual(usage.prompt_tokens_details?.cached_tokens, 4)
        XCTAssertEqual(usage.prompt_tokens_details?.audio_tokens, 0)
        XCTAssertNil(response.error)
    }

    func testUnknownFinishReasonAndServiceTierDecodeAsNil() throws {
        let response = try decodeResponse("""
        {"id":"x","object":"chat.completion","created":0,"model":"m","service_tier":"flex",
         "choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"end_turn"}]}
        """)

        XCTAssertNil(response.service_tier)
        XCTAssertNil(response.choices.first?.finish_reason)
        XCTAssertEqual(response.choices.first?.message?.content.string, "ok")
    }

    func testKnownServiceTierAndErrorFinishReasonDecode() throws {
        let response = try decodeResponse("""
        {"id":"x","object":"chat.completion.chunk","created":0,"service_tier":"default",
         "choices":[{"index":0,"delta":{"content":""},"finish_reason":"error"}]}
        """)

        XCTAssertEqual(response.service_tier, .default)
        XCTAssertEqual(response.choices.first?.finish_reason, .error)
    }

    func testResponseErrorAcceptsIntegerAndStringCodes() throws {
        let decoder = JSONDecoder()
        let httpError = try decoder.decode(
            OpenAI.ChatCompletionResponse.ResponseError.self,
            from: Data(#"{"code":402,"message":"Insufficient credits","metadata":{"provider_name":"Example"}}"#.utf8))
        XCTAssertEqual(httpError.code, "402")
        XCTAssertEqual(httpError.metadata?["provider_name"]?.stringValue, "Example")
        XCTAssertEqual(httpError.errorDescription, "Insufficient credits (402)")

        let streamError = try decoder.decode(
            OpenAI.ChatCompletionResponse.ResponseError.self,
            from: Data(#"{"code":"server_error","message":"Provider disconnected"}"#.utf8))
        XCTAssertEqual(streamError.code, "server_error")
        XCTAssertNil(streamError.metadata)

        let bare = try decoder.decode(OpenAI.ChatCompletionResponse.ResponseError.self, from: Data(#"{"message":"Oops"}"#.utf8))
        XCTAssertNil(bare.code)
        XCTAssertEqual(bare.errorDescription, "Oops")
    }

    func testResponseWithoutErrorRoundTripsUnchanged() throws {
        let response = try decodeResponse(try XCTUnwrap(getData(filename: "chat_completion_response")).string)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any])

        XCTAssertNil(encoded["error"], "an absent error must not be encoded")
        XCTAssertNil(encoded["choose"], "the client-side selector is never encoded")
        XCTAssertEqual(encoded["id"] as? String, "chatcmpl-123")
        XCTAssertEqual(encoded["service_tier"] as? String, "default")
    }

    // MARK: - Streaming

    func testStreamIgnoresSSECommentsAndDecodesPartialUsage() async throws {
        MockURLProtocol.setHandler(for: OpenAI.ChatCompletionRequest.endpoint) { _ in
            (.success(try self.getData(filename: "chat_completion_stream-openrouter", fileExtension: "txt")!), 200)
        }

        var results: [OpenAI.ChatCompletionResponse] = []
        for try await response in api.stream(request: makeRequest(stream: true)) {
            results.append(response)
        }

        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results.compactMap { $0.choices.first?.delta?.content }.joined(), "Hello, world")
        let usage = try XCTUnwrap(results.last?.usage)
        XCTAssertEqual(usage.completion_tokens_details?.reasoning_tokens, 24)
        XCTAssertEqual(usage.completion_tokens_details?.accepted_prediction_tokens, 0)
    }

    func testStreamThrowsInBandErrorAfterYieldingEarlierChunks() async throws {
        MockURLProtocol.setHandler(for: OpenAI.ChatCompletionRequest.endpoint) { _ in
            (.success(try self.getData(filename: "chat_completion_stream_error-openrouter", fileExtension: "txt")!), 200)
        }

        var results: [OpenAI.ChatCompletionResponse] = []
        do {
            for try await response in api.stream(request: makeRequest(stream: true)) {
                results.append(response)
            }
            XCTFail("The stream must end by throwing the in-band error")
        } catch LangToolsError.apiError(let error) {
            let responseError = try XCTUnwrap(error as? OpenAI.ChatCompletionResponse.ResponseError)
            XCTAssertEqual(responseError.code, "server_error")
            XCTAssertEqual(responseError.message, "Provider disconnected unexpectedly")
        }

        XCTAssertEqual(results.count, 1, "chunks before the error are still delivered")
        XCTAssertEqual(results.first?.choices.first?.delta?.content, "Hello")
    }

    func testPerformThrowsAnInBandErrorFromACompleteResponse() async throws {
        MockURLProtocol.setHandler(for: OpenAI.ChatCompletionRequest.endpoint) { _ in
            (.success(Data(#"""
            {"id":"gen-1","object":"chat.completion","created":1,"model":"openai/gpt-5",
             "error":{"code":502,"message":"Upstream provider error"},
             "choices":[{"index":0,"message":{"role":"assistant","content":""},"finish_reason":"error"}]}
            """#.utf8)), 200)
        }

        do {
            _ = try await api.perform(request: makeRequest())
            XCTFail("A 200 response carrying an error must throw")
        } catch LangToolsError.apiError(let error as OpenAI.ChatCompletionResponse.ResponseError) {
            XCTAssertEqual(error.code, "502")
            XCTAssertEqual(error.message, "Upstream provider error")
        }
    }

    func testValidateStreamChunkThrowsOnlyWhenErrorIsPresent() throws {
        XCTAssertNoThrow(try OpenAI.ChatCompletionResponse.empty.validateStreamChunk())

        let failing = OpenAI.ChatCompletionResponse(
            id: nil, object: "chat.completion.chunk", created: 0, model: nil, system_fingerprint: nil,
            choices: [], usage: nil, service_tier: nil,
            error: .init(message: "boom", code: "server_error"), choose: nil)
        XCTAssertThrowsError(try failing.validateStreamChunk()) { error in
            guard case LangToolsError.apiError = error else { return XCTFail("Expected apiError, got \(error)") }
        }
        XCTAssertEqual(OpenAI.ChatCompletionResponse.empty.combining(with: failing).error?.message, "boom",
                       "the accumulated response keeps the error")
    }

    // MARK: - additionalParameters

    func testAdditionalParametersAreMergedIntoTheBody() throws {
        var request = makeRequest()
        request.additionalParameters = [
            "provider": ["order": ["anthropic", "openai"], "allow_fallbacks": false],
            "models": ["anthropic/claude-sonnet-4.5", "openai/gpt-5"],
        ]

        let body = try encodedBody(request)

        XCTAssertEqual(body["model"] as? String, "gpt-4o")
        XCTAssertEqual((body["messages"] as? [Any])?.count, 1)
        XCTAssertEqual(body["models"] as? [String], ["anthropic/claude-sonnet-4.5", "openai/gpt-5"])
        let provider = try XCTUnwrap(body["provider"] as? [String: Any])
        XCTAssertEqual(provider["order"] as? [String], ["anthropic", "openai"])
        XCTAssertEqual(provider["allow_fallbacks"] as? Bool, false)
        XCTAssertNil(body["additionalParameters"], "the property itself is never a wire key")
    }

    func testEmptyAdditionalParametersEncodeNothingExtra() throws {
        var request = makeRequest()
        let plain = try encodedBody(request)
        request.additionalParameters = [:]
        XCTAssertEqual(Set(try encodedBody(request).keys), Set(plain.keys))
    }

    func testAdditionalParametersRejectReservedKeysThroughPrepare() throws {
        for key in ["model", "messages", "stream", "tools", "temperature", "response_format"] {
            var request = makeRequest()
            request.additionalParameters = [key: "override"]
            assertInvalidArgument(try OpenAI(apiKey: "k").prepare(request: request), containing: key)
        }
    }

    func testReservedParameterKeysCoverEveryTypedBodyKey() throws {
        let request = OpenAI.ChatCompletionRequest(
            model: .gpt4o, messages: [.init(role: .user, content: "Hi")],
            temperature: 0.5, top_p: 0.9, n: 1, stream: true, stream_options: .init(include_usage: true),
            stop: .string("END"), max_tokens: 10, max_completion_tokens: 10, presence_penalty: 0,
            frequency_penalty: 0, logit_bias: ["1": 1], logprobs: true, top_logprobs: 1, user: "u",
            response_type: .json_object, seed: 1,
            tools: [.init(name: "f", description: "d", tool_schema: .init(properties: [:]))],
            tool_choice: .auto, parallel_tool_calls: true, service_tier: .auto, store: false,
            prediction: .init(content: .string("p")), modalities: [.text],
            audio: .init(voice: .alloy, format: .mp3), reasoning_effort: .low, metadata: ["k": "v"])

        let encodedKeys = Set(try encodedBody(request).keys)
        let reserved = OpenAI.ChatCompletionRequest.reservedParameterKeys

        XCTAssertTrue(encodedKeys.isSubset(of: reserved), "unreserved typed keys: \(encodedKeys.subtracting(reserved))")
        XCTAssertFalse(reserved.contains("_choose"))
        XCTAssertFalse(reserved.contains("toolEventHandler"))
    }

    // MARK: - additionalHeaders

    func testAdditionalHeadersAreSentAlongsideAuthorization() throws {
        let openAI = OpenAI(configuration: .init(
            baseURL: URL(string: "https://openrouter.ai/api/v1/")!, apiKey: "k",
            additionalHeaders: ["HTTP-Referer": "https://example.com", "X-Title": "LangTools"]))

        let urlRequest = try openAI.prepare(request: makeRequest())

        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "HTTP-Referer"), "https://example.com")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "X-Title"), "LangTools")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer k")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(urlRequest.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
    }

    func testReservedHeadersAreRejectedCaseInsensitively() throws {
        for name in ["authorization", "AUTHORIZATION", "Content-Length", "x-api-key", "Transfer-Encoding", "Host"] {
            let openAI = OpenAI(configuration: .init(apiKey: "k", additionalHeaders: [name: "value"]))
            assertInvalidArgument(try openAI.prepare(request: makeRequest()), containing: name)
        }
    }

    // MARK: - Provider tag

    private let gateway = LangToolsProviderID(rawValue: "example.gateway")

    func testProviderTagIsExcludedFromEqualityAndEncoding() throws {
        let tagged = OpenAI.Model(customModelID: "openai/gpt-5", providerID: gateway)
        let untagged = OpenAI.Model(customModelID: "openai/gpt-5")

        XCTAssertEqual(tagged, untagged, "equality is by ID only")
        XCTAssertTrue(tagged.belongs(to: gateway))
        XCTAssertFalse(untagged.belongs(to: gateway))
        XCTAssertFalse(tagged.belongs(to: LangToolsProviderID(rawValue: "other.gateway")))

        let encoded = try JSONEncoder().encode(tagged)
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), #""openai\/gpt-5""#)
        let decoded = try JSONDecoder().decode(OpenAI.Model.self, from: encoded)
        XCTAssertNil(decoded.providerID, "the tag is not encoded")
        XCTAssertEqual(decoded, tagged)
    }

    func testOpenAIClaimsOnlyUntaggedModels() {
        let untagged = makeRequest(model: .gpt4o)
        let tagged = makeRequest(model: OpenAI.Model(customModelID: "gpt-4o", providerID: gateway))

        XCTAssertTrue(OpenAI.requestValidators.contains { $0(untagged) })
        XCTAssertFalse(OpenAI.requestValidators.contains { $0(tagged) },
                       "a model tagged for another provider must not route to OpenAI even when its ID matches")
    }

    func testRoutedRetagsADecodedRequestWithoutChangingIt() throws {
        var original = makeRequest(model: OpenAI.Model(customModelID: "openai/gpt-5", providerID: gateway), stream: true)
        original.additionalParameters = ["models": ["openai/gpt-5"]]
        let decoded = try JSONDecoder().decode(OpenAI.ChatCompletionRequest.self, from: JSONEncoder().encode(original))
        XCTAssertNil(decoded.model.providerID, "decoding drops the tag")

        let routed = decoded.routed(to: gateway)

        XCTAssertTrue(routed.model.belongs(to: gateway))
        XCTAssertEqual(routed.model.id, "openai/gpt-5")
        XCTAssertEqual(routed.messages.count, original.messages.count)
        XCTAssertEqual(routed.stream, true)
        XCTAssertNil(decoded.model.providerID, "routed(to:) returns a copy")
    }
}
