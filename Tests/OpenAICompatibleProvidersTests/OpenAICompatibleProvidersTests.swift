//
//  OpenAICompatibleProvidersTests.swift
//  OpenAICompatibleProvidersTests
//

import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LangTools
@testable import TestUtils
@testable import OpenAI
import OpenAICompatible
import VercelAIGateway
import Groq
import Mistral
import DeepSeek
import Cerebras
import TogetherAI
import Fireworks
import Cohere

final class OpenAICompatibleProvidersTests: XCTestCase {

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

    private func body(of urlRequest: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(urlRequest.httpBody)) as? [String: Any])
    }

    private func messages(of urlRequest: URLRequest) throws -> [[String: Any]] {
        try XCTUnwrap(body(of: urlRequest)["messages"] as? [[String: Any]])
    }

    // MARK: - Request preparation and routing

    func testEachProviderTargetsItsEndpointWithBearerAuth() throws {
        func check<P: OpenAICompatibleProvider>(_ provider: P, _ model: OpenAICompatibleModel<P>, _ url: String, file: StaticString = #filePath, line: UInt = #line) throws {
            let request = OpenAI.ChatCompletionRequest(model: model, messages: [.init(role: .user, content: "Hi")])
            let urlRequest = try provider.prepare(request: request)
            XCTAssertEqual(urlRequest.url?.absoluteString, url, file: file, line: line)
            XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer key", file: file, line: line)
            XCTAssertEqual(try body(of: urlRequest)["model"] as? String, model.rawValue, file: file, line: line)
        }
        try check(VercelAIGateway(apiKey: "key"), "anthropic/claude-sonnet-4.5", "https://ai-gateway.vercel.sh/v1/chat/completions")
        try check(Groq(apiKey: "key"), "llama-3.3-70b-versatile", "https://api.groq.com/openai/v1/chat/completions")
        try check(Mistral(apiKey: "key"), "mistral-large-latest", "https://api.mistral.ai/v1/chat/completions")
        try check(DeepSeek(apiKey: "key"), "deepseek-v4-flash", "https://api.deepseek.com/chat/completions")
        try check(Cerebras(apiKey: "key"), "gpt-oss-120b", "https://api.cerebras.ai/v1/chat/completions")
        try check(TogetherAI(apiKey: "key"), "meta-llama/Llama-3.3-70B-Instruct-Turbo", "https://api.together.xyz/v1/chat/completions")
        try check(Fireworks(apiKey: "key"), "accounts/fireworks/models/deepseek-v3", "https://api.fireworks.ai/inference/v1/chat/completions")
        try check(Cohere(apiKey: "key"), "command-a-03-2025", "https://api.cohere.com/compatibility/v1/chat/completions")
    }

    func testToolchainRoutesTaggedModelsToTheirProvider() throws {
        var toolchain = LangToolchain()
        toolchain.register(OpenAI(apiKey: "openai"))
        toolchain.register(VercelAIGateway(apiKey: "vercel"))
        toolchain.register(Groq(apiKey: "groq"))
        toolchain.register(TogetherAI(apiKey: "together"))

        // The same `openai/gpt-oss-120b` ID is served by several providers.
        let viaGroq = OpenAI.ChatCompletionRequest(model: "openai/gpt-oss-120b" as Groq.Model, messages: [.init(role: .user, content: "Hi")])
        let viaVercel = OpenAI.ChatCompletionRequest(model: "openai/gpt-oss-120b" as VercelAIGateway.Model, messages: [.init(role: .user, content: "Hi")])
        let viaOpenAI = OpenAI.ChatCompletionRequest(model: .gpt4o, messages: [.init(role: .user, content: "Hi")])

        XCTAssertEqual(try toolchain.prepare(request: viaGroq).url?.host, "api.groq.com")
        XCTAssertEqual(try toolchain.prepare(request: viaVercel).url?.host, "ai-gateway.vercel.sh")
        XCTAssertEqual(try toolchain.prepare(request: viaOpenAI).url?.host, "api.openai.com")
        XCTAssertFalse(Groq(apiKey: "groq").canHandleRequest(viaOpenAI))
        XCTAssertFalse(Groq(apiKey: "groq").canHandleRequest(viaVercel))
    }

    func testChatRequestTagsTheModelAndRejectsOtherModels() throws {
        let request = try Mistral.chatRequest(model: "mistral-small-latest" as Mistral.Model, messages: [], tools: nil, responseSchema: nil, toolEventHandler: { _ in })
        let chat = try XCTUnwrap(request as? OpenAI.ChatCompletionRequest)
        XCTAssertTrue(chat.model.belongs(to: Mistral.providerID))
        XCTAssertThrowsError(try Mistral.chatRequest(model: "llama" as Groq.Model, messages: [], tools: nil, responseSchema: nil, toolEventHandler: { _ in }))
    }

    func testModelIDsRejectEmptyAndPaddedValues() {
        XCTAssertNil(Groq.Model(rawValue: ""))
        XCTAssertNil(Groq.Model(rawValue: " llama"))
        XCTAssertEqual(Groq.Model(rawValue: "llama")?.rawValue, "llama")
        XCTAssertThrowsError(try JSONDecoder().decode(Groq.Model.self, from: Data(#""""#.utf8)))
    }

    func testKnownModelsAreValidIDs() {
        let all: [[String]] = [
            VercelAIGateway.knownModels.map(\.rawValue), Groq.knownModels.map(\.rawValue),
            Mistral.knownModels.map(\.rawValue), DeepSeek.knownModels.map(\.rawValue),
            Cerebras.knownModels.map(\.rawValue), TogetherAI.knownModels.map(\.rawValue),
            Fireworks.knownModels.map(\.rawValue), Cohere.knownModels.map(\.rawValue),
        ]
        for ids in all {
            XCTAssertFalse(ids.isEmpty)
            XCTAssertEqual(ids.compactMap { Groq.Model(rawValue: $0) }.count, ids.count)
        }
    }

    // MARK: - Body adaptation

    func testUnadaptedProvidersSendTheEncodedBodyUnchanged() throws {
        let request = OpenAI.ChatCompletionRequest(model: "gpt-oss-120b" as Cerebras.Model, messages: [.init(role: .user, content: "Hi")], max_tokens: 100, seed: 7)
        // Compare parsed JSON: key order differs between JSONEncoder runs on Darwin.
        let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? NSDictionary)

        XCTAssertEqual(try body(of: Cerebras(apiKey: "key").prepare(request: request)) as NSDictionary, expected)
    }

    func testMistralRemovesAndRenamesFieldsItRejects() throws {
        let request = OpenAI.ChatCompletionRequest(
            model: "mistral-large-latest" as Mistral.Model,
            messages: [try .init(role: .user, content: .string("Hi"), name: "reid")],
            stream_options: .init(include_usage: true), max_completion_tokens: 100, user: "user-1", seed: 7)

        let urlRequest = try Mistral(apiKey: "key").prepare(request: request)
        let body = try body(of: urlRequest)

        XCTAssertNil(body["stream_options"])
        XCTAssertNil(body["user"])
        XCTAssertNil(body["seed"])
        XCTAssertNil(body["max_completion_tokens"])
        XCTAssertEqual(body["random_seed"] as? Int, 7)
        XCTAssertEqual(body["max_tokens"] as? Int, 100)
        XCTAssertNil(try messages(of: urlRequest).first?["name"])
        // Re-encoding keeps integers integral.
        let text = try XCTUnwrap(String(data: XCTUnwrap(urlRequest.httpBody), encoding: .utf8))
        XCTAssertTrue(text.contains(#""max_tokens":100"#), text)
    }

    func testGroqRemovesLogProbabilityOptionsAndMessageNames() throws {
        let request = OpenAI.ChatCompletionRequest(
            model: "llama-3.3-70b-versatile" as Groq.Model,
            messages: [try .init(role: .user, content: .string("Hi"), name: "reid")],
            logit_bias: ["50256": -100], logprobs: true, top_logprobs: 2)

        let urlRequest = try Groq(apiKey: "key").prepare(request: request)
        let body = try body(of: urlRequest)

        XCTAssertNil(body["logprobs"])
        XCTAssertNil(body["top_logprobs"])
        XCTAssertNil(body["logit_bias"])
        XCTAssertNil(try messages(of: urlRequest).first?["name"])
    }

    func testDeepSeekBackfillsReasoningContentAndDowngradesJSONSchema() throws {
        var request = OpenAI.ChatCompletionRequest(
            model: "deepseek-v4-flash" as DeepSeek.Model,
            messages: [.init(role: .user, content: "Hi"), .init(role: .assistant, content: "Hello"), .init(role: .user, content: "Again")],
            seed: 3)
        request.responseSchema = JSONSchema.object(properties: ["answer": .string()], required: ["answer"])

        let urlRequest = try DeepSeek(apiKey: "key").prepare(request: request)
        let body = try body(of: urlRequest)
        let messages = try messages(of: urlRequest)

        XCTAssertNil(body["seed"])
        XCTAssertEqual(messages[1]["reasoning_content"] as? String, "")
        XCTAssertNil(messages[0]["reasoning_content"])
        XCTAssertEqual(body["response_format"] as? [String: String], ["type": "json_object"])
    }

    func testTogetherSendsLogprobsAsACount() throws {
        let request = OpenAI.ChatCompletionRequest(model: "deepseek-ai/DeepSeek-V3" as TogetherAI.Model, messages: [.init(role: .user, content: "Hi")], logprobs: true, top_logprobs: 3)

        let body = try body(of: TogetherAI(apiKey: "key").prepare(request: request))

        XCTAssertEqual(body["logprobs"] as? Int, 3)
        XCTAssertNil(body["top_logprobs"])
    }

    func testCohereRemovesUnsupportedOptionsAndUnwrapsTheSchema() throws {
        var request = OpenAI.ChatCompletionRequest(
            model: "command-a-03-2025" as Cohere.Model, messages: [.init(role: .user, content: "Hi")],
            n: 1, stream_options: .init(include_usage: true), parallel_tool_calls: true)
        request.responseSchema = JSONSchema.object(properties: ["answer": .string()], required: ["answer"])

        let body = try body(of: Cohere(apiKey: "key").prepare(request: request))

        XCTAssertNil(body["n"])
        XCTAssertNil(body["stream_options"])
        XCTAssertNil(body["parallel_tool_calls"])
        let format = try XCTUnwrap(body["response_format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        let schema = try XCTUnwrap(format["json_schema"] as? [String: Any])
        XCTAssertEqual(schema["type"] as? String, "object")
        XCTAssertNil(schema["strict"])
    }

    func testVercelSendsMaxCompletionTokensAsMaxTokens() throws {
        let request = OpenAI.ChatCompletionRequest(model: "openai/gpt-5" as VercelAIGateway.Model, messages: [.init(role: .user, content: "Hi")], max_completion_tokens: 50)

        let body = try body(of: VercelAIGateway(apiKey: "key").prepare(request: request))

        XCTAssertEqual(body["max_tokens"] as? Int, 50)
        XCTAssertNil(body["max_completion_tokens"])
    }

    // MARK: - Responses

    func testStreamingConcatenatesTextPartsOfArrayContent() async throws {
        // Mistral reasoning models stream content as typed parts.
        let stream = """
        data: {"id":"1","object":"chat.completion.chunk","created":1,"model":"magistral-medium-latest","choices":[{"index":0,"delta":{"role":"assistant","content":[{"type":"thinking","thinking":[{"type":"text","text":"hmm"}]}]},"finish_reason":null}]}

        data: {"id":"1","object":"chat.completion.chunk","created":1,"model":"magistral-medium-latest","choices":[{"index":0,"delta":{"content":[{"type":"text","text":"Hello"}]},"finish_reason":null}]}

        data: {"id":"1","object":"chat.completion.chunk","created":1,"model":"magistral-medium-latest","choices":[{"index":0,"delta":{"content":", world"},"finish_reason":"stop"}]}

        data: [DONE]
        """
        MockURLProtocol.setHandler(for: OpenAI.ChatCompletionRequest.endpoint) { request in
            XCTAssertEqual(request.url?.host, "api.mistral.ai")
            return (.success(Data(stream.utf8)), 200)
        }
        let mistral = Mistral(apiKey: "key", session: session)
        let request = OpenAI.ChatCompletionRequest(model: "magistral-medium-latest" as Mistral.Model, messages: [.init(role: .user, content: "Hi")], stream: true)

        var content = ""
        for try await chunk in mistral.stream(request: request) {
            content += chunk.choices.first?.delta?.content ?? ""
        }

        XCTAssertEqual(content, "Hello, world")
    }

    func testCompletionSkipsUnknownContentParts() async throws {
        let response = """
        {"id":"1","object":"chat.completion","created":1,"model":"magistral-medium-latest","choices":[{"index":0,"message":{"role":"assistant","content":[{"type":"thinking","thinking":[{"type":"text","text":"hmm"}]},{"type":"text","text":"Answer"}]},"finish_reason":"stop"}]}
        """
        MockURLProtocol.setHandler(for: OpenAI.ChatCompletionRequest.endpoint) { _ in (.success(Data(response.utf8)), 200) }

        let result = try await Mistral(apiKey: "key", session: session).perform(request: OpenAI.ChatCompletionRequest(model: "magistral-medium-latest" as Mistral.Model, messages: [.init(role: .user, content: "Hi")]))

        let parts = try XCTUnwrap(result.choices.first?.message?.content.array)
        XCTAssertEqual(parts.count, 1)
        guard case .text(let text)? = parts.first else { return XCTFail("Expected a text part, got \(parts)") }
        XCTAssertEqual(text.text, "Answer")
    }

    // MARK: - Errors

    func testErrorResponseDecodesEachProviderShape() throws {
        func decode(_ json: String) throws -> OpenAICompatibleErrorResponse {
            try JSONDecoder().decode(OpenAICompatibleErrorResponse.self, from: Data(json.utf8))
        }

        let nested = try decode(#"{"error":{"message":"Invalid API Key","type":"invalid_request_error","code":"invalid_api_key"}}"#)
        XCTAssertEqual(nested, .init(message: "Invalid API Key", type: "invalid_request_error", code: "invalid_api_key"))
        XCTAssertEqual(try decode(#"{"error":{"message":"Busy","code":429}}"#).code, "429")
        XCTAssertEqual(try decode(#"{"error":"Unauthorized"}"#).message, "Unauthorized")
        let topLevel = try decode(#"{"message":"Wrong API key","type":"invalid_request_error","param":"api_key","code":"wrong_api_key"}"#)
        XCTAssertEqual(topLevel, .init(message: "Wrong API key", type: "invalid_request_error", code: "wrong_api_key", param: "api_key"))
        let mistral422 = try decode(#"{"object":"error","message":{"detail":[{"type":"extra_forbidden","loc":["body","seed"],"msg":"Extra inputs are not permitted"}]},"type":"invalid_request_message_error","param":null,"code":null}"#)
        XCTAssertEqual(mistral422, .init(message: "Extra inputs are not permitted", type: "invalid_request_message_error"))
        XCTAssertEqual(try decode(#"{"detail":[{"msg":"field required"},{"msg":"bad value"}]}"#).message, "field required; bad value")
        XCTAssertEqual(try decode(#"{"detail":"Not Found"}"#).message, "Not Found")
        XCTAssertThrowsError(try decode(#"{"choices":[]}"#))
    }

    func testErrorResponseRoundTripsInTheOpenAIShape() throws {
        let error = OpenAICompatibleErrorResponse(message: "Nope", type: "auth", code: "401")
        let data = try JSONEncoder().encode(error)
        XCTAssertEqual(try JSONDecoder().decode(OpenAICompatibleErrorResponse.self, from: data), error)
        XCTAssertEqual(error.localizedDescription, "Nope")
    }

    func testHTTPErrorDecodesTheProviderError() async throws {
        MockURLProtocol.setHandler(for: OpenAI.ChatCompletionRequest.endpoint) { _ in
            (.success(Data(#"{"message":"Wrong API key","type":"invalid_request_error","code":"wrong_api_key"}"#.utf8)), 401)
        }

        do {
            _ = try await Cerebras(apiKey: "key", session: session).perform(request: OpenAI.ChatCompletionRequest(model: "gpt-oss-120b" as Cerebras.Model, messages: [.init(role: .user, content: "Hi")]))
            XCTFail("Expected a 401 error")
        } catch LangToolsError.responseUnsuccessful(let status, let error as OpenAICompatibleErrorResponse) {
            XCTAssertEqual(status, 401)
            XCTAssertEqual(error.code, "wrong_api_key")
        }
    }

    // MARK: - Model listing

    func testListModelsReadsVercelTypesAndTags() async throws {
        let catalog = """
        {"object":"list","data":[
          {"id":"anthropic/claude-sonnet-4.5","object":"model","owned_by":"anthropic","name":"Claude Sonnet 4.5","type":"language","context_window":200000,"max_tokens":64000,"tags":["reasoning","tool-use","vision"]},
          {"id":"openai/text-embedding-3-small","object":"model","type":"embedding","tags":[]},
          {"id":"meta/llama-3.3-70b","object":"model","type":"language","tags":["reasoning"]},
          {"object":"model","type":"language"}
        ]}
        """
        MockURLProtocol.setHandler(for: "models") { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.absoluteString, "https://ai-gateway.vercel.sh/v1/models")
            return (.success(Data(catalog.utf8)), 200)
        }

        let models = try await VercelAIGateway(apiKey: "key", session: session).listModels()

        XCTAssertEqual(models.map(\.id), ["anthropic/claude-sonnet-4.5", "openai/text-embedding-3-small", "meta/llama-3.3-70b"])
        XCTAssertEqual(models[0].name, "Claude Sonnet 4.5")
        XCTAssertEqual(models[0].ownedBy, "anthropic")
        XCTAssertEqual(models[0].contextWindow, 200_000)
        XCTAssertEqual(models[0].maxOutputTokens, 64_000)
        XCTAssertEqual(models.map(\.supportsTools), [true, false, false])
        XCTAssertEqual(models.map(\.isChatModel), [true, false, true])
    }

    func testListModelsReadsTogethersBareArray() async throws {
        let catalog = """
        [{"id":"meta-llama/Llama-3.3-70B-Instruct-Turbo","object":"model","type":"chat","display_name":"Llama 3.3 70B","organization":"Meta","context_length":131072},
         {"id":"BAAI/bge-large-en-v1.5","object":"model","type":"embedding","context_length":512}]
        """
        MockURLProtocol.setHandler(for: "models") { _ in (.success(Data(catalog.utf8)), 200) }

        let models = try await TogetherAI(apiKey: "key", session: session).listModels()

        XCTAssertEqual(models.map(\.id), ["meta-llama/Llama-3.3-70B-Instruct-Turbo", "BAAI/bge-large-en-v1.5"])
        XCTAssertEqual(models[0].name, "Llama 3.3 70B")
        XCTAssertEqual(models[0].ownedBy, "Meta")
        XCTAssertEqual(models[0].contextWindow, 131_072)
        XCTAssertNil(models[0].supportsTools)
        XCTAssertEqual(models.map(\.isChatModel), [true, false])
    }

    func testListModelsReadsMistralCapabilities() async throws {
        let catalog = """
        {"object":"list","data":[
          {"id":"mistral-large-latest","object":"model","owned_by":"mistralai","type":"base","max_context_length":131072,"capabilities":{"completion_chat":true,"function_calling":true}},
          {"id":"mistral-embed","object":"model","owned_by":"mistralai","type":"base","capabilities":{"completion_chat":false,"function_calling":false}}
        ]}
        """
        MockURLProtocol.setHandler(for: "models") { _ in (.success(Data(catalog.utf8)), 200) }

        let models = try await Mistral(apiKey: "key", session: session).listModels()

        XCTAssertEqual(models.map(\.isChatModel), [true, false])
        XCTAssertEqual(models.map(\.supportsTools), [true, false])
        XCTAssertEqual(models[0].contextWindow, 131_072)
    }

    func testListModelsFiltersGroqByActivityAndID() async throws {
        let catalog = """
        {"object":"list","data":[
          {"id":"llama-3.3-70b-versatile","object":"model","owned_by":"Meta","active":true,"context_window":131072,"max_completion_tokens":32768},
          {"id":"whisper-large-v3","object":"model","owned_by":"OpenAI","active":true,"context_window":448},
          {"id":"llama3-8b-8192","object":"model","owned_by":"Meta","active":false,"context_window":8192}
        ]}
        """
        MockURLProtocol.setHandler(for: "models") { _ in (.success(Data(catalog.utf8)), 200) }

        let models = try await Groq(apiKey: "key", session: session).listModels()

        XCTAssertEqual(models.map(\.isChatModel), [true, false, false])
        XCTAssertEqual(models[0].maxOutputTokens, 32_768)
        XCTAssertNil(models[0].supportsTools)
    }

    func testListModelsReadsFireworksFlagsAndExcludesEmbeddings() async throws {
        let catalog = """
        {"object":"list","data":[
          {"id":"accounts/fireworks/models/deepseek-v3","object":"model","owned_by":"fireworks","kind":"HF_BASE_MODEL","supports_chat":true,"supports_tools":true,"context_length":163840},
          {"id":"accounts/fireworks/models/qwen3-embedding-8b","object":"model","kind":"EMBEDDING_MODEL","supports_chat":true,"supports_tools":false}
        ]}
        """
        MockURLProtocol.setHandler(for: "models") { _ in (.success(Data(catalog.utf8)), 200) }

        let models = try await Fireworks(apiKey: "key", session: session).listModels()

        XCTAssertEqual(models.map(\.isChatModel), [true, false])
        XCTAssertEqual(models.map(\.supportsTools), [true, false])
        XCTAssertEqual(models[0].contextWindow, 163_840)
    }

    func testCohereListsModelsFromItsNativeCatalog() async throws {
        let catalog = """
        {"models":[{"name":"command-a-03-2025","endpoints":["generate","chat","summarize"],"features":["json_mode","json_schema","tools","strict_tools"],"context_length":256000,"is_deprecated":false},{"name":"command-light","endpoints":["chat"],"features":null,"context_length":4096,"is_deprecated":true},{"name":"broken"},{"endpoints":["chat"]}],"next_page_token":null}
        """
        MockURLProtocol.setHandler(for: "v1/models") { request in
            XCTAssertEqual(request.url?.host, "api.cohere.com")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(query.first(where: { $0.name == "endpoint" })?.value, "chat")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer key")
            return (.success(Data(catalog.utf8)), 200)
        }

        // Called through the protocol, as the CLI and app do.
        func list<P: OpenAICompatibleProvider>(_ provider: P) async throws -> [OpenAICompatibleModelInfo] { try await provider.listModels() }
        let models = try await list(Cohere(apiKey: "key", session: session))

        XCTAssertTrue(Cohere.supportsModelListing)
        XCTAssertEqual(models.map(\.id), ["command-a-03-2025", "broken"])
        XCTAssertEqual(models[0].contextWindow, 256_000)
        XCTAssertEqual(models[0].supportsTools, true)
        XCTAssertNil(models[1].supportsTools)
    }
}
