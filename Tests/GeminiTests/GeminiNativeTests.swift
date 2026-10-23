//
//  GeminiNativeTests.swift
//  GeminiTests
//

import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LangTools
@testable import TestUtils
@testable import Gemini
import OpenAI
import OpenAICompatible

final class GeminiNativeTests: MockSessionTestCase {



    private var gemini: Gemini { Gemini(apiKey: "key", session: session) }

    private let weatherTool = OpenAI.Tool(
        name: "get_weather",
        description: "Current weather",
        tool_schema: .init(properties: ["city": .init(type: "string")], required: ["city"]),
        callback: { _, args in "Sunny in \(args["city"]?.stringValue ?? "?")" }
    )

    // MARK: - Requests

    func testRequestTargetsGenerateContentWithGeminiShape() throws {
        var request = Gemini.GenerateContentRequest(
            model: .gemini3Flash,
            messages: [.init(role: .system, content: "Be brief."), .init(role: .user, content: "Hi")],
            tools: [weatherTool],
            googleSearch: true,
            functionCallingMode: .auto,
            generationConfig: .init(temperature: 0.2, topK: 40, thinkingConfig: ["thinkingLevel": .string("low")]),
            safetySettings: [.init(category: "HARM_CATEGORY_HARASSMENT", threshold: "BLOCK_ONLY_HIGH")]
        )
        request.responseSchema = .object(properties: ["answer": .string()])

        let urlRequest = try Gemini(apiKey: "key").prepare(request: request)

        XCTAssertEqual(urlRequest.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models/gemini-3-flash:generateContent")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "x-goog-api-key"), "key")
        XCTAssertNil(urlRequest.value(forHTTPHeaderField: "Authorization"))
        let body = try body(of: urlRequest)
        let system = try XCTUnwrap(body["systemInstruction"] as? [String: Any])
        XCTAssertEqual((system["parts"] as? [[String: Any]])?.first?["text"] as? String, "Be brief.")
        let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
        XCTAssertEqual(contents.count, 1)
        XCTAssertEqual(contents[0]["role"] as? String, "user")
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        let declarations = try XCTUnwrap(tools.first?["functionDeclarations"] as? [[String: Any]])
        XCTAssertEqual(declarations.first?["name"] as? String, "get_weather")
        XCTAssertNotNil(declarations.first?["parametersJsonSchema"] as? [String: Any])
        XCTAssertNotNil(tools.last?["googleSearch"])
        XCTAssertEqual(((body["toolConfig"] as? [String: Any])?["functionCallingConfig"] as? [String: Any])?["mode"] as? String, "AUTO")
        let config = try XCTUnwrap(body["generationConfig"] as? [String: Any])
        XCTAssertEqual(config["topK"] as? Int, 40)
        XCTAssertEqual(config["responseMimeType"] as? String, "application/json")
        XCTAssertNotNil(config["responseJsonSchema"] as? [String: Any])
        XCTAssertEqual((config["thinkingConfig"] as? [String: Any])?["thinkingLevel"] as? String, "low")
        XCTAssertEqual((body["safetySettings"] as? [[String: Any]])?.first?["threshold"] as? String, "BLOCK_ONLY_HIGH")
    }

    func testStreamingAndModelIDsOutsideTheEnum() throws {
        let streaming = Gemini.GenerateContentRequest(modelID: "gemini-3.5-flash-preview", messages: [.init(role: .user, content: "Hi")], stream: true)
        let tuned = Gemini.GenerateContentRequest(modelID: "tunedModels/my-model", messages: [.init(role: .user, content: "Hi")])

        XCTAssertEqual(try Gemini(apiKey: "key").prepare(request: streaming).url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash-preview:streamGenerateContent?alt=sse")
        XCTAssertEqual(try Gemini(apiKey: "key").prepare(request: tuned).url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/tunedModels/my-model:generateContent")
    }

    func testFunctionResponsesCarryTheCallNameAndReplayedCallsGetASignature() throws {
        // A call replayed from another provider's history has no signature.
        let call = Gemini.ToolCall(id: "call_1", name: "get_weather", args: .object(["city": .string("Paris")]))
        let request = Gemini.GenerateContentRequest(model: .gemini3Flash, messages: [
            .init(role: .user, content: "Weather?"),
            .init(tool_selection: [call]),
        ] + Gemini.Message.messages(for: [.init(tool_selection_id: "call_1", result: "Sunny")]))

        let contents = try XCTUnwrap(body(of: Gemini(apiKey: "key").prepare(request: request))["contents"] as? [[String: Any]])

        XCTAssertEqual(contents.map { $0["role"] as? String }, ["user", "model", "user"])
        let callPart = try XCTUnwrap((contents[1]["parts"] as? [[String: Any]])?.first)
        XCTAssertEqual(callPart["thoughtSignature"] as? String, Gemini.Part.skipThoughtSignatureValidator)
        XCTAssertEqual((callPart["functionCall"] as? [String: Any])?["id"] as? String, "call_1")
        let response = try XCTUnwrap(((contents[2]["parts"] as? [[String: Any]])?.first)?["functionResponse"] as? [String: Any])
        XCTAssertEqual(response["name"] as? String, "get_weather")
        XCTAssertEqual(response["id"] as? String, "call_1")
        XCTAssertEqual((response["response"] as? [String: Any])?["output"] as? String, "Sunny")
    }

    func testRecordedSignaturesAreKeptAndOlderModelsGetNoPlaceholder() throws {
        let signed = Gemini.ToolCall(id: "call_1", name: "get_weather", args: nil, thoughtSignature: "sig-abc")
        let unsigned = Gemini.ToolCall(id: "call_2", name: "get_weather", args: nil)
        func callPart(_ request: Gemini.GenerateContentRequest) throws -> [String: Any] {
            let contents = try XCTUnwrap(body(of: Gemini(apiKey: "key").prepare(request: request))["contents"] as? [[String: Any]])
            return try XCTUnwrap((contents.last?["parts"] as? [[String: Any]])?.first)
        }

        XCTAssertEqual(try callPart(.init(model: .gemini3Pro, messages: [.init(tool_selection: [signed])]))["thoughtSignature"] as? String, "sig-abc")
        XCTAssertNil(try callPart(.init(modelID: "gemini-2.5-flash", messages: [.init(tool_selection: [unsigned])]))["thoughtSignature"])
    }

    func testNativeAndCompatibleRequestsBothRouteToGemini() throws {
        var toolchain = LangToolchain()
        toolchain.register(OpenAI(apiKey: "openai"))
        toolchain.register(Gemini(apiKey: "gemini"))
        let native = try XCTUnwrap(Gemini.chatRequest(model: Gemini.Model.gemini3Flash, messages: [OpenAI.Message(role: .user, content: "Hi")], tools: nil, responseSchema: nil, toolEventHandler: { _ in }) as? Gemini.GenerateContentRequest)

        XCTAssertTrue(Gemini(apiKey: "key").canHandleRequest(native))
        XCTAssertFalse(OpenAI(apiKey: "key").canHandleRequest(native))
        XCTAssertEqual(native.model, .gemini3Flash)
        XCTAssertEqual(try Gemini(apiKey: "key").prepare(request: OpenAI.ChatCompletionRequest(model: Gemini.Model.gemini3Flash, messages: [.init(role: .user, content: "Hi")])).url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
    }

    func testOpenAIHistoryConvertsAndParallelResponsesShareATurn() throws {
        let calls = ["Paris", "Rome"].enumerated().map { OpenAI.Message.ToolCall(index: $0, id: "call_\($0)", type: .function, function: .init(name: "get_weather", arguments: #"{"city":"\#($1)"}"#)) }
        let history = [OpenAI.Message(role: .system, content: "Be brief."), OpenAI.Message(role: .user, content: "Weather?"), OpenAI.Message(tool_selection: calls)]
            + calls.map { OpenAI.Message(tool_selection_id: $0.id!, result: "Sunny") }
        let request = Gemini.GenerateContentRequest(model: .gemini3Flash, messages: history.map { Gemini.Message($0) })

        let body = try body(of: Gemini(apiKey: "key").prepare(request: request))
        let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])

        XCTAssertNotNil(body["systemInstruction"])
        XCTAssertEqual(contents.map { $0["role"] as? String }, ["user", "model", "user"])
        let callParts = try XCTUnwrap(contents[1]["parts"] as? [[String: Any]])
        XCTAssertEqual((callParts[1]["functionCall"] as? [String: Any])?["args"] as? [String: String], ["city": "Rome"])
        let responses = try XCTUnwrap(contents[2]["parts"] as? [[String: Any]]).compactMap { $0["functionResponse"] as? [String: Any] }
        XCTAssertEqual(responses.map { $0["id"] as? String }, ["call_0", "call_1"])
        XCTAssertEqual(responses.map { $0["name"] as? String }, ["get_weather", "get_weather"])
    }

    // MARK: - Responses

    func testCompleteResponseSkipsThoughtsAndKeepsGrounding() async throws {
        let response = """
        {"candidates":[{"content":{"role":"model","parts":[{"text":"Thinking it over","thought":true},{"text":"Paris is in France.","thoughtSignature":"sig"}]},"finishReason":"STOP","groundingMetadata":{"webSearchQueries":["where is paris"],"groundingChunks":[{"web":{"uri":"https://example.com","title":"Example"}}]}}],"usageMetadata":{"promptTokenCount":5,"candidatesTokenCount":4,"thoughtsTokenCount":3,"totalTokenCount":12},"modelVersion":"gemini-3-flash","responseId":"r1"}
        """
        MockURLProtocol.setHandler(for: ":generateContent") { _ in (.success(Data(response.utf8)), 200) }

        let result = try await gemini.perform(request: Gemini.GenerateContentRequest(model: .gemini3Flash, messages: [.init(role: .user, content: "Where is Paris?")]))

        XCTAssertEqual(result.message?.content.text, "Paris is in France.")
        XCTAssertEqual(result.usageMetadata?.thoughtsTokenCount, 3)
        XCTAssertEqual(result.candidates?.first?.groundingMetadata?["webSearchQueries"]?.arrayValue?.first?.stringValue, "where is paris")
        XCTAssertEqual(result.responseId, "r1")
    }

    func testStreamedFunctionCallRunsTheToolAndContinues() async throws {
        let callStream = """
        data: {"candidates":[{"content":{"role":"model","parts":[{"functionCall":{"name":"get_weather","args":{"city":"Paris"}},"thoughtSignature":"sig-1"}]},"finishReason":"STOP"}],"responseId":"r1"}

        """
        let answerStream = """
        data: {"candidates":[{"content":{"role":"model","parts":[{"text":"Sunny "}]}}]}

        data: {"candidates":[{"content":{"role":"model","parts":[{"text":"today."}]},"finishReason":"STOP"}],"usageMetadata":{"totalTokenCount":9}}

        """
        var secondBody: [String: Any]?
        MockURLProtocol.setHandler(for: ":streamGenerateContent") { _ in
            MockURLProtocol.setHandler(for: ":streamGenerateContent") { request in
                secondBody = try? JSONSerialization.jsonObject(with: request.bodyData ?? Data()) as? [String: Any]
                return (.success(Data(answerStream.utf8)), 200)
            }
            return (.success(Data(callStream.utf8)), 200)
        }

        let request = Gemini.GenerateContentRequest(model: .gemini3Flash, messages: [.init(role: .user, content: "Weather in Paris?")], stream: true, tools: [weatherTool])
        var text = ""
        for try await chunk in gemini.stream(request: request) {
            text += chunk.delta?.content ?? ""
        }

        XCTAssertEqual(text, "Sunny today.")
        let contents = try XCTUnwrap(secondBody?["contents"] as? [[String: Any]])
        XCTAssertEqual(contents.count, 3)
        let replayedCall = try XCTUnwrap((contents[1]["parts"] as? [[String: Any]])?.first)
        // The signature Gemini returned goes back with the call.
        XCTAssertEqual(replayedCall["thoughtSignature"] as? String, "sig-1")
        let response = try XCTUnwrap(((contents[2]["parts"] as? [[String: Any]])?.first)?["functionResponse"] as? [String: Any])
        XCTAssertEqual(response["name"] as? String, "get_weather")
        XCTAssertEqual(response["id"] as? String, (replayedCall["functionCall"] as? [String: Any])?["id"] as? String)
        XCTAssertEqual((response["response"] as? [String: Any])?["output"] as? String, "Sunny in Paris")
    }

    func testStreamCombinesTextAcrossChunks() throws {
        let first = try JSONDecoder().decode(Gemini.GenerateContentResponse.self, from: Data(#"{"candidates":[{"content":{"role":"model","parts":[{"text":"Hel"}]}}]}"#.utf8))
        let second = try JSONDecoder().decode(Gemini.GenerateContentResponse.self, from: Data(#"{"candidates":[{"content":{"role":"model","parts":[{"text":"lo","thoughtSignature":"sig"}]},"finishReason":"STOP"}]}"#.utf8))

        let combined = Gemini.GenerateContentResponse.empty.combining(with: first).combining(with: second)

        XCTAssertEqual(combined.message?.parts.count, 1)
        XCTAssertEqual(combined.message?.content.text, "Hello")
        XCTAssertEqual(combined.message?.parts.first?.thoughtSignature, "sig")
        XCTAssertEqual(combined.finishReason, "STOP")
        XCTAssertNoThrow(try combined.validateStreamCompletion())
        XCTAssertThrowsError(try Gemini.GenerateContentResponse.empty.combining(with: first).validateStreamCompletion())
    }

    func testSafetyStopsAndBlockedPromptsThrow() async throws {
        let blocked = try JSONDecoder().decode(Gemini.GenerateContentResponse.self, from: Data(#"{"promptFeedback":{"blockReason":"SAFETY"}}"#.utf8))
        XCTAssertThrowsError(try blocked.validateStreamChunk())
        let stopped = try JSONDecoder().decode(Gemini.GenerateContentResponse.self, from: Data(#"{"candidates":[{"content":{},"finishReason":"SAFETY"}]}"#.utf8))
        XCTAssertThrowsError(try stopped.validateStreamChunk())
        let maxTokens = try JSONDecoder().decode(Gemini.GenerateContentResponse.self, from: Data(#"{"candidates":[{"content":{"role":"model","parts":[{"text":"Partial"}]},"finishReason":"MAX_TOKENS"}]}"#.utf8))
        XCTAssertNoThrow(try maxTokens.validateStreamChunk())

        let stream = """
        data: {"candidates":[{"content":{"role":"model","parts":[{"text":"Par"}]}}]}

        data: {"error":{"code":503,"message":"The model is overloaded.","status":"UNAVAILABLE"}}

        """
        MockURLProtocol.setHandler(for: ":streamGenerateContent") { _ in (.success(Data(stream.utf8)), 200) }
        do {
            for try await _ in gemini.stream(request: Gemini.GenerateContentRequest(model: .gemini3Flash, messages: [.init(role: .user, content: "Hi")])) {}
            XCTFail("Expected the in-stream error to throw")
        } catch LangToolsError.apiError(let error as Gemini.NativeError) {
            XCTAssertEqual(error.status, "UNAVAILABLE")
            XCTAssertEqual(error.code, 503)
        }
    }

    func testHTTPErrorDecodesTheNativeShape() async throws {
        MockURLProtocol.setHandler(for: ":generateContent") { _ in
            (.success(Data(#"{"error":{"code":400,"message":"API key not valid.","status":"INVALID_ARGUMENT"}}"#.utf8)), 400)
        }

        do {
            _ = try await gemini.perform(request: Gemini.GenerateContentRequest(model: .gemini3Flash, messages: [.init(role: .user, content: "Hi")]))
            XCTFail("Expected a 400")
        } catch LangToolsError.responseUnsuccessful(let status, let error as GeminiErrorResponse) {
            XCTAssertEqual(status, 400)
            XCTAssertEqual(error.error.message, "API key not valid.")
            XCTAssertEqual(error.error.type, "INVALID_ARGUMENT")
            XCTAssertEqual(error.error.code, "400")
        }
    }

    // MARK: - Models

    func testListModelsReadsTheNativeCatalogAcrossPages() async throws {
        let firstPage = """
        {"models":[{"name":"models/gemini-3-flash","displayName":"Gemini 3 Flash","inputTokenLimit":1048576,"outputTokenLimit":65536,"supportedGenerationMethods":["generateContent","countTokens"]},{"name":"models/text-embedding-004","supportedGenerationMethods":["embedContent"]}],"nextPageToken":"page2"}
        """
        let secondPage = """
        {"models":[{"name":"models/gemini-3-pro","supportedGenerationMethods":["generateContent"]},{"displayName":"no name"}]}
        """
        MockURLProtocol.setHandler(for: "v1beta/models") { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "key")
            XCTAssertEqual(request.httpMethod, "GET")
            MockURLProtocol.setHandler(for: "v1beta/models") { request in
                XCTAssertTrue(request.url?.query?.contains("pageToken=page2") ?? false)
                return (.success(Data(secondPage.utf8)), 200)
            }
            return (.success(Data(firstPage.utf8)), 200)
        }

        // Called through the protocol, as the CLI and app do.
        func list<P: OpenAICompatibleProvider>(_ provider: P) async throws -> [OpenAICompatibleModelInfo] { try await provider.listModels() }
        let models = try await list(gemini)

        XCTAssertEqual(models.map(\.id), ["gemini-3-flash", "text-embedding-004", "gemini-3-pro"])
        XCTAssertEqual(models.map(\.isChatModel), [true, false, true])
        XCTAssertEqual(models[0].contextWindow, 1_048_576)
        XCTAssertEqual(models[0].maxOutputTokens, 65_536)
        XCTAssertEqual(models[0].name, "Gemini 3 Flash")
    }
}
