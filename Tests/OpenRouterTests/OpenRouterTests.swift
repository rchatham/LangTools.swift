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
@testable import OpenAI

final class OpenRouterTests: XCTestCase {

    var api: OpenRouter!
    var mockConfiguration: URLSessionConfiguration!

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
        mockConfiguration = URLSessionConfiguration.ephemeral
        mockConfiguration.protocolClasses = [MockURLProtocol.self]
        api = OpenRouter(apiKey: "or-key").configure(testURLSessionConfiguration: mockConfiguration)
    }

    override func tearDown() {
        MockURLProtocol.resetHandlers()
        URLProtocol.unregisterClass(MockURLProtocol.self)
        super.tearDown()
    }

    private func chatRequest(_ model: OpenRouter.Model = "anthropic/claude-sonnet-4.5", stream: Bool? = nil) -> OpenAI.ChatCompletionRequest {
        OpenAI.ChatCompletionRequest(model: model, messages: [.init(role: .user, content: "Hi")], stream: stream)
    }

    private func body(of urlRequest: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(urlRequest.httpBody)) as? [String: Any])
    }

    // MARK: - Request preparation

    func testPrepareTargetsOpenRouterWithAttributionHeaders() throws {
        let openRouter = OpenRouter(apiKey: "or-key", appURL: URL(string: "https://example.com"), appTitle: "LangTools")

        let urlRequest = try openRouter.prepare(request: chatRequest())

        XCTAssertEqual(urlRequest.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(urlRequest.httpMethod, "POST")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer or-key")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "HTTP-Referer"), "https://example.com")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "X-OpenRouter-Title"), "LangTools")
        XCTAssertEqual(try body(of: urlRequest)["model"] as? String, "anthropic/claude-sonnet-4.5")
    }

    func testAttributionHeadersAreOmittedWhenNotConfigured() throws {
        let urlRequest = try OpenRouter(apiKey: "or-key", appTitle: "").prepare(request: chatRequest())

        XCTAssertNil(urlRequest.value(forHTTPHeaderField: "HTTP-Referer"))
        XCTAssertNil(urlRequest.value(forHTTPHeaderField: "X-OpenRouter-Title"))
    }

    // MARK: - Chat

    func testChatCompletionDecodesGatewayResponse() async throws {
        MockURLProtocol.setHandler(for: OpenAI.ChatCompletionRequest.endpoint) { request in
            XCTAssertEqual(request.url?.host, "openrouter.ai")
            return (.success(try self.getData(filename: "chat_completion_response-openrouter")!), 200)
        }

        let response = try await api.perform(request: chatRequest())

        XCTAssertEqual(response.choices.first?.message?.content.string, "Hello from a gateway.")
        XCTAssertEqual(response.usage?.completion_tokens_details?.reasoning_tokens, 12)
    }

    func testStreamingDeliversContentAndUsage() async throws {
        MockURLProtocol.setHandler(for: OpenAI.ChatCompletionRequest.endpoint) { _ in
            (.success(try self.getData(filename: "chat_completion_stream-openrouter", fileExtension: "txt")!), 200)
        }

        var content = ""
        var finalUsage: OpenAI.ChatCompletionResponse.Usage?
        for try await chunk in api.stream(request: chatRequest(stream: true)) {
            content += chunk.choices.first?.delta?.content ?? ""
            finalUsage = chunk.usage ?? finalUsage
        }

        XCTAssertEqual(content, "Hello, world")
        XCTAssertEqual(finalUsage?.completion_tokens_details?.reasoning_tokens, 24)
    }

    func testStreamingErrorWithIntegerCodeEndsTheStream() async throws {
        // OpenRouter's current API reports integer codes on mid-stream error chunks.
        let stream = """
        data: {"id":"gen-1","object":"chat.completion.chunk","created":1,"model":"openai/gpt-5","choices":[{"index":0,"delta":{"role":"assistant","content":"Partial"},"finish_reason":null}]}

        data: {"id":"gen-1","object":"chat.completion.chunk","created":1,"model":"openai/gpt-5","error":{"code":502,"message":"Upstream provider error","metadata":{"provider_name":"OpenAI"}},"choices":[{"index":0,"delta":{"content":""},"finish_reason":"error"}]}

        data: [DONE]
        """
        MockURLProtocol.setHandler(for: OpenAI.ChatCompletionRequest.endpoint) { _ in (.success(Data(stream.utf8)), 200) }

        var received: [String] = []
        do {
            for try await chunk in api.stream(request: chatRequest(stream: true)) {
                received.append(chunk.choices.first?.delta?.content ?? "")
            }
            XCTFail("Expected the error chunk to end the stream")
        } catch LangToolsError.apiError(let error as OpenAI.ChatCompletionResponse.ResponseError) {
            XCTAssertEqual(error.code, "502")
            XCTAssertEqual(error.metadata?["provider_name"]?.stringValue, "OpenAI")
        }
        XCTAssertEqual(received, ["Partial"])
    }

    func testHTTPErrorDecodesOpenRouterErrorResponse() async throws {
        MockURLProtocol.setHandler(for: OpenAI.ChatCompletionRequest.endpoint) { _ in
            (.success(Data(#"{"error":{"code":402,"message":"Insufficient credits"},"user_id":"user_1"}"#.utf8)), 402)
        }

        do {
            _ = try await api.perform(request: chatRequest())
            XCTFail("Expected a 402 error")
        } catch LangToolsError.responseUnsuccessful(let status, let error as OpenRouterErrorResponse) {
            XCTAssertEqual(status, 402)
            XCTAssertEqual(error.error.message, "Insufficient credits")
            XCTAssertEqual(error.error.code, "402")
            XCTAssertEqual(error.localizedDescription, "Insufficient credits (402)")
        }
    }

    // MARK: - Models

    func testListModelsDecodesCatalogAndSkipsMalformedEntries() async throws {
        MockURLProtocol.setHandler(for: OpenRouter.ListModelsRequest.endpoint) { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/models")
            return (.success(try self.getData(filename: "models_list_response-openrouter")!), 200)
        }

        let models = try await api.listModels()

        XCTAssertEqual(models.map(\.id), ["anthropic/claude-sonnet-4.5", "meta-llama/llama-3.2-3b-instruct:free"])
        let sonnet = models[0]
        XCTAssertEqual(sonnet.model, "anthropic/claude-sonnet-4.5")
        XCTAssertEqual(sonnet.contextLength, 1_000_000)
        XCTAssertEqual(sonnet.pricing?.prompt, "0.000003")
        XCTAssertEqual(sonnet.pricing?.inputCacheRead, "0.0000003")
        XCTAssertEqual(sonnet.architecture?.inputModalities, ["text", "image", "file"])
        XCTAssertEqual(sonnet.topProvider?.maxCompletionTokens, 64000)
        XCTAssertTrue(sonnet.supportsTools)
        XCTAssertTrue(sonnet.supportsStructuredOutput)
        let llama = models[1]
        XCTAssertNil(llama.contextLength)
        XCTAssertFalse(llama.supportsTools)
        XCTAssertFalse(llama.supportsStructuredOutput)
    }

    func testListModelsFiltersBecomeQueryItems() throws {
        let request = OpenRouter.ListModelsRequest(supportedParameters: ["tools", "structured_outputs"], outputModalities: ["text"], category: "programming")

        let url = try XCTUnwrap(api.prepare(request: request).url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.path, "/api/v1/models")
        XCTAssertEqual(components.queryItems, [
            URLQueryItem(name: "supported_parameters", value: "tools,structured_outputs"),
            URLQueryItem(name: "output_modalities", value: "text"),
            URLQueryItem(name: "category", value: "programming"),
        ])
    }

    // MARK: - Routing options

    func testProviderPreferencesAndFallbackModelsAreEncoded() throws {
        let request = OpenAI.ChatCompletionRequest(
            model: "meta-llama/llama-3.3-70b-instruct",
            messages: [.init(role: .user, content: "Hi")],
            provider: .init(order: ["groq", "together"], allowFallbacks: false, dataCollection: .deny, sort: .throughput, zeroDataRetention: true),
            fallbackModels: ["mistralai/mistral-large"])

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
    }

    func testRoutingPreservesExistingParametersAndIgnoresNilArguments() {
        var request = chatRequest()
        request.additionalParameters = ["transforms": ["middle-out"]]

        let unchanged = request.routing()
        XCTAssertEqual(unchanged.additionalParameters, ["transforms": ["middle-out"]])

        let routed = request.routing(provider: .init(only: ["anthropic"]))
        XCTAssertEqual(routed.additionalParameters?["transforms"], ["middle-out"])
        XCTAssertEqual(routed.additionalParameters?["provider"], ["only": ["anthropic"]])
        XCTAssertNil(routed.additionalParameters?["models"])

        XCTAssertNil(chatRequest().routing().additionalParameters, "no options means no additional parameters")
    }

    func testProviderPreferencesCodableMatchesWireJSON() throws {
        let preferences = OpenRouter.ProviderPreferences(order: ["a"], requireParameters: true, ignore: ["b"], quantizations: ["fp8"])
        let decoded = try JSONDecoder().decode(JSON.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(decoded, preferences.json)
        XCTAssertEqual(try JSONDecoder().decode(OpenRouter.ProviderPreferences.self, from: JSONEncoder().encode(preferences)), preferences)
    }

    // MARK: - Validation and toolchain routing

    func testValidatorsClaimOnlyOpenRouterTaggedModels() {
        let openRouterRequest = chatRequest("gpt-4o")
        let openAIRequest = OpenAI.ChatCompletionRequest(model: .gpt4o, messages: [.init(role: .user, content: "Hi")])

        XCTAssertTrue(OpenRouter.requestValidators.contains { $0(openRouterRequest) })
        XCTAssertFalse(OpenRouter.requestValidators.contains { $0(openAIRequest) })
        XCTAssertFalse(OpenAI.requestValidators.contains { $0(openRouterRequest) },
                       "an OpenRouter slug that matches an OpenAI ID must not route to OpenAI")
        XCTAssertTrue(OpenRouter.requestValidators.contains { $0(OpenRouter.ListModelsRequest()) })
    }

    func testToolchainRoutesTaggedRequestsToOpenRouterAndUntaggedToOpenAI() async throws {
        var toolchain = LangToolchain()
        toolchain.register(OpenAI(apiKey: "openai-key").configure(testURLSessionConfiguration: mockConfiguration))
        toolchain.register(api!)
        let responseData = try XCTUnwrap(getData(filename: "chat_completion_response-openrouter"))

        var hosts: [String?] = []
        MockURLProtocol.setHandler(for: OpenAI.ChatCompletionRequest.endpoint) { request in
            hosts.append(request.url?.host)
            return (.success(responseData), 200)
        }
        _ = try await toolchain.perform(request: chatRequest("gpt-4o"))

        MockURLProtocol.setHandler(for: OpenAI.ChatCompletionRequest.endpoint) { request in
            hosts.append(request.url?.host)
            return (.success(responseData), 200)
        }
        _ = try await toolchain.perform(request: OpenAI.ChatCompletionRequest(model: .gpt4o, messages: [.init(role: .user, content: "Hi")]))

        XCTAssertEqual(hosts, ["openrouter.ai", "api.openai.com"])
    }

    func testChatRequestFactoryProducesTaggedRequest() throws {
        let request = try OpenRouter.chatRequest(model: OpenRouter.Model.auto, messages: [OpenAI.Message(role: .user, content: "Hi")], tools: nil, responseSchema: nil, toolEventHandler: { _ in })

        let chat = try XCTUnwrap(request as? OpenAI.ChatCompletionRequest)
        XCTAssertEqual(chat.model.id, "openrouter/auto")
        XCTAssertTrue(chat.model.belongs(to: OpenRouter.providerID))
        XCTAssertThrowsError(try OpenRouter.chatRequest(model: OpenAI.Model.gpt4o, messages: [], tools: nil, responseSchema: nil, toolEventHandler: { _ in }))
    }

    // MARK: - Model type

    func testModelSlugValidationAndCoding() throws {
        XCTAssertNil(OpenRouter.Model(rawValue: ""))
        XCTAssertNil(OpenRouter.Model(rawValue: "  "))
        XCTAssertNil(OpenRouter.Model(rawValue: " anthropic/claude-sonnet-4.5 "), "padded slugs are rejected")
        XCTAssertEqual(OpenRouter.Model(rawValue: "openai/gpt-5:free")?.rawValue, "openai/gpt-5:free")

        let encoded = try JSONEncoder().encode(OpenRouter.Model.auto)
        XCTAssertEqual(try JSONDecoder().decode(OpenRouter.Model.self, from: encoded), .auto)
        XCTAssertThrowsError(try JSONDecoder().decode(OpenRouter.Model.self, from: Data(#""""#.utf8)))
    }
}

extension OpenRouter {
    internal func configure(testURLSessionConfiguration: URLSessionConfiguration) -> Self {
        _ = openAI.configure(testURLSessionConfiguration: testURLSessionConfiguration)
        return self
    }
}
