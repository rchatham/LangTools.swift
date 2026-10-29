//
//  OpenRouterTests.swift
//  OpenRouterTests
//

import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LangTools
@testable import TestUtils
@testable import OpenRouter
import OpenAICompatible
@testable import OpenAI
import Anthropic

final class OpenRouterTests: MockSessionTestCase {
    private var api: OpenRouter { OpenRouter(apiKey: "or-key", session: session) }

    private func chatRequest(_ model: OpenRouter.Model = "anthropic/claude-sonnet-4.5", stream: Bool? = nil) -> OpenAI.ChatCompletionRequest {
        OpenAI.ChatCompletionRequest(model: model, messages: [.init(role: .user, content: "Hi")], stream: stream)
    }

    private func messagesRequest() -> Anthropic.MessageRequest {
        Anthropic.MessageRequest(model: .claude45Sonnet_20250929, messages: [.init(role: .user, content: "Hi")]).routed(to: OpenRouter.providerID)
    }

    // MARK: - Request preparation

    func testPrepareTargetsOpenRouterWithOptionalAttributionHeaders() throws {
        let urlRequest = try OpenRouter(apiKey: "or-key", appURL: URL(string: "https://example.com"), appTitle: "LangTools").prepare(request: chatRequest())

        XCTAssertEqual(urlRequest.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(urlRequest.httpMethod, "POST")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer or-key")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "HTTP-Referer"), "https://example.com")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "X-OpenRouter-Title"), "LangTools")
        XCTAssertEqual(try body(of: urlRequest)["model"] as? String, "anthropic/claude-sonnet-4.5")

        let plain = try OpenRouter(apiKey: "or-key", appTitle: "").prepare(request: chatRequest())
        XCTAssertNil(plain.value(forHTTPHeaderField: "HTTP-Referer"))
        XCTAssertNil(plain.value(forHTTPHeaderField: "X-OpenRouter-Title"))
    }

    func testMessagesRequestsTargetTheMessagesEndpointWithBearerAuth() throws {
        let urlRequest = try OpenRouter(apiKey: "or-key", appTitle: "LangTools").prepare(request: messagesRequest())

        XCTAssertEqual(urlRequest.url?.absoluteString, "https://openrouter.ai/api/v1/messages")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer or-key")
        XCTAssertNil(urlRequest.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "X-OpenRouter-Title"), "LangTools", "attribution applies to every format")
        XCTAssertEqual(try body(of: urlRequest)["model"] as? String, "anthropic/claude-sonnet-4.5")
    }

    // MARK: - Chat

    func testPerformAndStreamDecodeGatewayResponses() async throws {
        MockURLProtocol.setHandler(for: OpenAI.ChatCompletionRequest.endpoint) { request in
            XCTAssertEqual(request.url?.host, "openrouter.ai")
            return (.success(try self.getData(filename: "chat_completion_response-openrouter")!), 200)
        }
        let response = try await api.perform(request: chatRequest())
        XCTAssertEqual(response.choices.first?.message?.content.string, "Hello from a gateway.")
        XCTAssertEqual(response.usage?.completion_tokens_details?.reasoning_tokens, 12)

        MockURLProtocol.setHandler(for: OpenAI.ChatCompletionRequest.endpoint) { _ in (.success(try self.getData(filename: "chat_completion_stream-openrouter", fileExtension: "txt")!), 200) }
        var content = "", usage: OpenAI.ChatCompletionResponse.Usage?
        for try await chunk in api.stream(request: chatRequest(stream: true)) {
            content += chunk.choices.first?.delta?.content ?? ""
            usage = chunk.usage ?? usage
        }
        XCTAssertEqual(content, "Hello, world")
        XCTAssertEqual(usage?.completion_tokens_details?.reasoning_tokens, 24)
    }

    func testStreamingErrorWithIntegerCodeEndsTheStream() async throws {
        let stream = """
        data: {"id":"gen-1","object":"chat.completion.chunk","created":1,"choices":[{"index":0,"delta":{"role":"assistant","content":"Partial"},"finish_reason":null}]}

        data: {"id":"gen-1","object":"chat.completion.chunk","created":1,"error":{"code":502,"message":"Upstream provider error","metadata":{"provider_name":"OpenAI"}},"choices":[{"index":0,"delta":{"content":""},"finish_reason":"error"}]}

        data: [DONE]
        """
        MockURLProtocol.setHandler(for: OpenAI.ChatCompletionRequest.endpoint) { _ in (.success(Data(stream.utf8)), 200) }

        var received: [String] = []
        do {
            for try await chunk in api.stream(request: chatRequest(stream: true)) { received.append(chunk.choices.first?.delta?.content ?? "") }
            XCTFail("Expected the error chunk to end the stream")
        } catch LangToolsError.apiError(let error as OpenAI.ChatCompletionResponse.ResponseError) {
            XCTAssertEqual(error.code, "502")
            XCTAssertEqual(error.metadata?["provider_name"]?.stringValue, "OpenAI")
        }
        XCTAssertEqual(received, ["Partial"])
    }

    func testErrorBodiesDecodeAsOpenRouterErrorResponse() async throws {
        MockURLProtocol.setHandler(for: OpenAI.ChatCompletionRequest.endpoint) { _ in (.success(Data(#"{"error":{"code":402,"message":"Insufficient credits"},"user_id":"user_1"}"#.utf8)), 402) }

        do {
            _ = try await api.perform(request: chatRequest())
            XCTFail("Expected a 402 error")
        } catch LangToolsError.responseUnsuccessful(let status, let error as OpenRouterErrorResponse) {
            XCTAssertEqual(status, 402)
            XCTAssertEqual(error.error.code, "402")
            XCTAssertEqual(error.localizedDescription, "Insufficient credits (402)")
        }
        let messagesError = try JSONDecoder().decode(OpenRouterErrorResponse.self, from: Data(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#.utf8))
        XCTAssertEqual(messagesError.error.message, "Overloaded")
        XCTAssertEqual(messagesError.error.type, "overloaded_error")
    }

    // MARK: - Models

    func testListModelsDecodesCatalogAndSkipsMalformedEntries() async throws {
        MockURLProtocol.setHandler(for: "models") { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/models")
            return (.success(try self.getData(filename: "models_list_response-openrouter")!), 200)
        }

        let models = try await api.listModels()

        XCTAssertEqual(models.map(\.id), ["anthropic/claude-sonnet-4.5", "meta-llama/llama-3.2-3b-instruct:free"])
        XCTAssertEqual(models[0].contextWindow, 1_000_000)
        XCTAssertEqual(models[0].metadata["pricing"]?["prompt"], "0.000003")
        XCTAssertEqual(models[0].supportsTools, true)
        XCTAssertNil(models[1].contextWindow)
        XCTAssertEqual(models[1].supportsTools, false)
    }

    func testModelSlugValidationAndCoding() throws {
        for invalid in ["", "  ", " anthropic/claude-sonnet-4.5 "] { XCTAssertNil(OpenRouter.Model(rawValue: invalid), "empty and padded slugs are rejected") }
        XCTAssertEqual(OpenRouter.Model(rawValue: "openai/gpt-5:free")?.rawValue, "openai/gpt-5:free")
        XCTAssertEqual(try JSONDecoder().decode(OpenRouter.Model.self, from: JSONEncoder().encode(OpenRouter.Model.auto)), .auto)
        XCTAssertThrowsError(try JSONDecoder().decode(OpenRouter.Model.self, from: Data(#""""#.utf8)))
    }

    // MARK: - Routing options

    func testProviderPreferencesAndFallbackModelsAreEncoded() throws {
        let request = chatRequest("meta-llama/llama-3.3-70b-instruct")
            .routing(provider: .init(order: ["groq", "together"], allowFallbacks: false, dataCollection: .deny, sort: .throughput, zeroDataRetention: true), fallbackModels: ["mistralai/mistral-large"])

        let body = try body(of: api.prepare(request: request))

        XCTAssertEqual(body["model"] as? String, "meta-llama/llama-3.3-70b-instruct")
        XCTAssertEqual(body["models"] as? [String], ["mistralai/mistral-large"])
        let provider = try XCTUnwrap(body["provider"] as? [String: Any])
        XCTAssertEqual(provider["order"] as? [String], ["groq", "together"])
        XCTAssertEqual(provider["allow_fallbacks"] as? Bool, false)
        XCTAssertEqual(provider["data_collection"] as? String, "deny")
        XCTAssertEqual(provider["sort"] as? String, "throughput")
        XCTAssertEqual(provider["zdr"] as? Bool, true)
        XCTAssertEqual(Set(provider.keys), ["order", "allow_fallbacks", "data_collection", "sort", "zdr"], "unset fields are omitted")

        let preferences = OpenRouter.ProviderPreferences(order: ["a"], requireParameters: true, ignore: ["b"], quantizations: ["fp8"])
        XCTAssertEqual(try JSONDecoder().decode(JSON.self, from: JSONEncoder().encode(preferences)), preferences.json)
        XCTAssertEqual(try JSONDecoder().decode(OpenRouter.ProviderPreferences.self, from: JSONEncoder().encode(preferences)), preferences)
    }

    func testRoutingPreservesExistingParametersAndIgnoresNilArguments() {
        var request = chatRequest()
        request.additionalParameters = ["transforms": ["middle-out"]]

        XCTAssertEqual(request.routing().additionalParameters, ["transforms": ["middle-out"]])
        let routed = request.routing(provider: .init(only: ["anthropic"]))
        XCTAssertEqual(routed.additionalParameters?["transforms"], ["middle-out"])
        XCTAssertEqual(routed.additionalParameters?["provider"], ["only": ["anthropic"]])
        XCTAssertNil(routed.additionalParameters?["models"])
        XCTAssertNil(chatRequest().routing().additionalParameters, "no options means no additional parameters")
    }

    // MARK: - Validation and toolchain routing

    func testValidatorsClaimOnlyOpenRouterTaggedRequests() {
        let openAIRequest = OpenAI.ChatCompletionRequest(model: .gpt4o, messages: [.init(role: .user, content: "Hi")])

        XCTAssertTrue(OpenRouter.requestValidators.contains { $0(self.chatRequest("gpt-4o")) })
        XCTAssertFalse(OpenRouter.requestValidators.contains { $0(openAIRequest) })
        XCTAssertFalse(OpenAI.requestValidators.contains { $0(self.chatRequest("gpt-4o")) }, "an OpenRouter slug that matches an OpenAI ID must not route to OpenAI")
        XCTAssertTrue(OpenRouter.requestValidators.contains { $0(OpenAICompatibleListModelsRequest<OpenRouter>()) })
        XCTAssertFalse(Anthropic(apiKey: "key").canHandleRequest(messagesRequest()))
    }

    func testToolchainRoutesEachFormatToItsProvider() async throws {
        var toolchain = LangToolchain()
        toolchain.register(Anthropic(apiKey: "anthropic"))
        toolchain.register(OpenAI(apiKey: "openai-key", session: session))
        toolchain.register(api)
        let responseData = try XCTUnwrap(getData(filename: "chat_completion_response-openrouter"))
        var hosts: [String?] = []
        for request in [chatRequest("gpt-4o"), OpenAI.ChatCompletionRequest(model: .gpt4o, messages: [.init(role: .user, content: "Hi")])] {
            MockURLProtocol.setHandler(for: OpenAI.ChatCompletionRequest.endpoint) { hosts.append($0.url?.host); return (.success(responseData), 200) }
            _ = try await toolchain.perform(request: request)
        }

        XCTAssertEqual(hosts, ["openrouter.ai", "api.openai.com"])
        XCTAssertEqual(try toolchain.prepare(request: Anthropic.MessageRequest(model: .claude45Sonnet_20250929, messages: [.init(role: .user, content: "Hi")])).url?.host, "api.anthropic.com")
        XCTAssertEqual(try toolchain.prepare(request: messagesRequest()).url?.absoluteString, "https://openrouter.ai/api/v1/messages")
    }

    func testChatRequestBuildsTheFormatOfTheModelType() throws {
        let chat = try XCTUnwrap(OpenRouter.chatRequest(model: OpenRouter.Model.auto, messages: [OpenAI.Message(role: .user, content: "Hi")], tools: nil, responseSchema: nil, toolEventHandler: { _ in }) as? OpenAI.ChatCompletionRequest)
        let messages = try OpenRouter.chatRequest(model: Anthropic.Model.claude46Sonnet, messages: [], tools: nil, responseSchema: nil, toolEventHandler: { _ in })

        XCTAssertEqual(chat.model.id, "openrouter/auto")
        XCTAssertTrue(chat.model.belongs(to: OpenRouter.providerID))
        XCTAssertEqual((messages as? Anthropic.MessageRequest)?.providerID, OpenRouter.providerID)
        XCTAssertThrowsError(try OpenRouter.chatRequest(model: OpenAI.Model.gpt4o, messages: [], tools: nil, responseSchema: nil, toolEventHandler: { _ in }))
    }
}
