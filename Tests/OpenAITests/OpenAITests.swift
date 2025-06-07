//
//  OpenAITests.swift
//  OpenAITests
//
//  Created by Reid Chatham on 12/6/23.
//

import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import TestUtils
@testable import OpenAI

class OpenAITests: XCTestCase {

    var api: OpenAI!

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        api = OpenAI(apiKey: "").configure(testURLSessionConfiguration: config)
    }

    override func tearDown() {
        MockURLProtocol.mockNetworkHandlers.removeAll()
        URLProtocol.unregisterClass(MockURLProtocol.self)
        super.tearDown()
    }

    func testChatStream() async throws {
        MockURLProtocol.mockNetworkHandlers[OpenAI.ChatCompletionRequest.endpoint] = { request in
            return (.success(try OpenAI.ChatCompletionResponse(
                id: "testid",
                object: "chat.completion.chunk",
                created: 0,
                model: "gpt4",
                system_fingerprint: "some-system-fingerprint-klabs9fg72n",
                choices: [.init(
                    index: 0,
                    message: nil,
                    finish_reason: nil,
                    delta: .init(
                        role: .assistant,
                        content: "Hello, how are you?",
                        tool_calls: nil,
                        audio: nil,
                        refusal: nil),
                    logprobs: nil)],
                usage: .init(prompt_tokens: 50, completion_tokens: 50, total_tokens: 100), service_tier: nil, choose: {_ in 0}).streamData()), 200)
        }
        var results: [OpenAI.ChatCompletionResponse] = []
        for try await response in api.stream(request: OpenAI.ChatCompletionRequest(model: .gpt4Turbo, messages: [.init(role: .user, content: "Hi")], stream: true)) {
            results.append(response)
        }
        let content = results.reduce("") { $0 + ($1.choices[0].delta?.content ?? "") }
        XCTAssertEqual(results[0].id, "testid")
        XCTAssertEqual(content, "Hello, how are you?")
    }

    func testChatStreamResponse() async throws {
        MockURLProtocol.mockNetworkHandlers[OpenAI.ChatCompletionRequest.endpoint] = { request in
            return (.success(try self.getData(filename: "assistant_response_stream", fileExtension: "txt")!), 200)
        }
        var results: [OpenAI.ChatCompletionResponse] = []
        for try await response in api.stream(request: OpenAI.ChatCompletionRequest(model: .gpt4Turbo, messages: [.init(role: .user, content: "Hi")], stream: true, logprobs: true, top_logprobs: 2)) {
            results.append(response)
        }

        // Test initial message setup with special tokens
        XCTAssertEqual(results[0].choices[0].delta?.role, .assistant)
        XCTAssertEqual(results[0].choices[0].delta?.content, "")
        XCTAssertEqual(results[0].choices[0].logprobs?.content?.first?.token, "<|im_start|>")
        XCTAssertEqual(results[0].choices[0].logprobs?.content?.first?.logprob, -0.0009)
        XCTAssertNil(results[0].choices[0].logprobs?.content?.first?.bytes)

        // Test content with logprobs for "Sure"
        XCTAssertEqual(results[1].choices[0].delta?.content, "Sure")
        XCTAssertEqual(results[1].choices[0].logprobs?.content?.first?.token, "Sure")
        XCTAssertEqual(results[1].choices[0].logprobs?.content?.first?.logprob, -0.15)
        XCTAssertEqual(results[1].choices[0].logprobs?.content?.first?.bytes, [83,117,114,101])

        // Test top logprobs for "Sure"
        let sureTopLogprobs = results[1].choices[0].logprobs?.content?.first?.top_logprobs
        XCTAssertEqual(sureTopLogprobs?.count, 2)
        XCTAssertEqual(sureTopLogprobs?[0].token, "Certainly")
        XCTAssertEqual(sureTopLogprobs?[0].logprob, -0.8)
        XCTAssertEqual(sureTopLogprobs?[0].bytes, [67,101,114,116,97,105,110,108,121])
        XCTAssertEqual(sureTopLogprobs?[1].token, "Of")
        XCTAssertEqual(sureTopLogprobs?[1].logprob, -1.2)
        XCTAssertEqual(sureTopLogprobs?[1].bytes, [79,102])

        // Test punctuation token with alternatives
        let periodIndex = 8 // Index where "." appears
        XCTAssertEqual(results[periodIndex].choices[0].delta?.content, ".")
        XCTAssertEqual(results[periodIndex].choices[0].logprobs?.content?.first?.token, ".")
        XCTAssertEqual(results[periodIndex].choices[0].logprobs?.content?.first?.logprob, -0.04)
        XCTAssertEqual(results[periodIndex].choices[0].logprobs?.content?.first?.bytes, [46])

        let periodTopLogprobs = results[periodIndex].choices[0].logprobs?.content?.first?.top_logprobs
        XCTAssertEqual(periodTopLogprobs?[0].token, "?")
        XCTAssertEqual(periodTopLogprobs?[0].logprob, -2.8)
        XCTAssertEqual(periodTopLogprobs?[0].bytes, [63])
        XCTAssertEqual(periodTopLogprobs?[1].token, "!")
        XCTAssertEqual(periodTopLogprobs?[1].logprob, -3.1)
        XCTAssertEqual(periodTopLogprobs?[1].bytes, [33])

        // Test "location" token with alternatives
        let locationIndex = 14 // Index where "location" appears
        XCTAssertEqual(results[locationIndex].choices[0].delta?.content, " location")
        XCTAssertEqual(results[locationIndex].choices[0].logprobs?.content?.first?.token, " location")
        XCTAssertEqual(results[locationIndex].choices[0].logprobs?.content?.first?.logprob, -0.14)
        XCTAssertEqual(results[locationIndex].choices[0].logprobs?.content?.first?.bytes, [32,108,111,99,97,116,105,111,110])

        let locationTopLogprobs = results[locationIndex].choices[0].logprobs?.content?.first?.top_logprobs
        XCTAssertEqual(locationTopLogprobs?[0].token, " city")
        XCTAssertEqual(locationTopLogprobs?[0].logprob, -1.4)
        XCTAssertEqual(locationTopLogprobs?[0].bytes, [32,99,105,116,121])

        // Test end of sequence token
        let lastContentIndex = results.count - 2 // Second to last message has the finish token
        XCTAssertEqual(results[lastContentIndex].choices[0].logprobs?.content?.first?.token, "<|im_end|>")
        XCTAssertEqual(results[lastContentIndex].choices[0].logprobs?.content?.first?.logprob, -0.0007)
        XCTAssertNil(results[lastContentIndex].choices[0].logprobs?.content?.first?.bytes)
        XCTAssertEqual(results[lastContentIndex].choices[0].finish_reason, .stop)

        // Test final usage stats
        let finalUsage = results.last?.usage
        XCTAssertEqual(finalUsage?.prompt_tokens, 25)
        XCTAssertEqual(finalUsage?.completion_tokens, 15)
        XCTAssertEqual(finalUsage?.total_tokens, 40)
        XCTAssertEqual(finalUsage?.completion_tokens_details?.reasoning_tokens, 0)
        XCTAssertEqual(finalUsage?.completion_tokens_details?.accepted_prediction_tokens, 0)
        XCTAssertEqual(finalUsage?.completion_tokens_details?.rejected_prediction_tokens, 0)

        // Test final message has system fingerprint and empty choices
        XCTAssertEqual(results.last?.system_fingerprint, "fp_44709d6fcb")
        XCTAssertTrue(results.last?.choices.isEmpty ?? false)
    }

    func testToolCallStreamResponse() async throws {
        MockURLProtocol.mockNetworkHandlers[OpenAI.ChatCompletionRequest.endpoint] = { request in
            return (.success(try self.getData(filename: "tool_call_stream", fileExtension: "txt")!), 200)
        }

        let request = OpenAI.ChatCompletionRequest(
            model: .gpt4Turbo,
            messages: [.init(role: .user, content: "Hi")],
            stream: true,
            tools: [
                .function(.init(
                    name: "getCurrentWeather",
                    description: "Get the current weather",
                    parameters: .init(
                        properties: [
                            "location": .init(type: "string"),
                            "format": .init(type: "string", enumValues: ["celsius", "fahrenheit"])
                        ],
                        required: ["location", "format"]
                    )
                ))
            ]
        )

        var results: [OpenAI.ChatCompletionResponse] = []
        for try await response in api.stream(request: request) {
            results.append(response)
        }

        // Test initial tool call setup
        XCTAssertEqual(results[0].choices[0].delta?.role, .assistant)
        XCTAssertNil(results[0].choices[0].delta?.content)

        let initialToolCall = results[0].choices[0].delta?.tool_calls?.first
        XCTAssertEqual(initialToolCall?.index, 0)
        XCTAssertEqual(initialToolCall?.id, "call_xxxxxxxxxxxxxxxxxxxxxxxx")
        XCTAssertEqual(initialToolCall?.type, .function)
        XCTAssertEqual(initialToolCall?.function.name, "getCurrentWeather")
        XCTAssertEqual(initialToolCall?.function.arguments, "")

        // Test completion
        let lastMessageIndex = results.count - 2 // Second to last message has the finish
        XCTAssertTrue(results[lastMessageIndex].choices[0].delta?.tool_calls == nil)
        XCTAssertEqual(results[lastMessageIndex].choices[0].finish_reason, .tool_calls)

        // Test final usage stats
        let finalUsage = results.last?.usage
        XCTAssertEqual(finalUsage?.prompt_tokens, 30)
        XCTAssertEqual(finalUsage?.completion_tokens, 25)
        XCTAssertEqual(finalUsage?.total_tokens, 55)
        XCTAssertEqual(finalUsage?.completion_tokens_details?.reasoning_tokens, 10)
        XCTAssertEqual(finalUsage?.completion_tokens_details?.accepted_prediction_tokens, 0)
        XCTAssertEqual(finalUsage?.completion_tokens_details?.rejected_prediction_tokens, 0)

        // Verify complete arguments string
        let arguments = results.reduce("") { $0 + (!$1.choices.isEmpty ? ($1.choices[0].delta?.tool_calls?[0].function.arguments ?? "") : "") }
        XCTAssertEqual(arguments, "{\n  \"format\": \"fahrenheit\",\n  \"location\": \"Bangkok\"\n}")

        // Test final message has system fingerprint
        XCTAssertEqual(results.last?.system_fingerprint, "fp_44709d6fcb")
        XCTAssertTrue(results.last?.choices.isEmpty ?? false)
    }

    func testAudioStreamResponse() async throws {
        MockURLProtocol.mockNetworkHandlers[OpenAI.ChatCompletionRequest.endpoint] = { request in
            return (.success(try self.getData(filename: "audio_response_stream", fileExtension: "txt")!), 200)
        }

        var results: [OpenAI.ChatCompletionResponse] = []
        let request = OpenAI.ChatCompletionRequest(
            model: .gpt4Turbo,
            messages: [.init(role: .user, content: "Hi")],
            stream: true,
            modalities: [.text, .audio],
            audio: .init(voice: .ash, format: .mp3)
        )

        for try await response in api.stream(request: request) {
            results.append(response)
        }

        // Test initial setup
        XCTAssertEqual(results[0].choices[0].delta?.role, .assistant)
        XCTAssertNil(results[0].choices[0].delta?.audio)

        // Test text content with logprobs
        XCTAssertEqual(results[1].choices[0].delta?.content, "Here is my response")
        XCTAssertEqual(results[1].choices[0].logprobs?.content?.first?.token, "Here")
        XCTAssertEqual(results[1].choices[0].logprobs?.content?.first?.logprob, -0.2)

        // Test audio response
        let audioResponse = results[2].choices[0].delta?.audio
        XCTAssertEqual(audioResponse?.id, "audio-123")
        XCTAssertEqual(audioResponse?.transcript, "Here is my response")

        // Test final usage stats with audio tokens
        let finalUsage = results.last?.usage
        XCTAssertEqual(finalUsage?.completion_tokens_details?.audio_tokens, 10)
        XCTAssertEqual(finalUsage?.total_tokens, 45)
        XCTAssertEqual(finalUsage?.completion_tokens_details?.reasoning_tokens, 0)
    }

    func testToolCallWithFunctionCallbackStreamResponse() async throws {
        MockURLProtocol.mockNetworkHandlers[OpenAI.ChatCompletionRequest.endpoint] = { request in
            return (.success(try self.getData(filename: "tool_call_stream", fileExtension: "txt")!), 200)
        }
        let tools: [OpenAI.Tool] = [.function(.init(
            name: "getCurrentWeather",
            description: "Get the current weather",
            parameters: .init(
                properties: [
                    "location": .init(
                        type: "string",
                        description: "The city and state, e.g. San Francisco, CA"),
                    "format": .init(
                        type: "string",
                        enumValues: ["celsius", "fahrenheit"],
                        description: "The temperature unit to use. Infer this from the users location.")
                ],
                required: ["location", "format"]),
            callback: { _ in
                MockURLProtocol.mockNetworkHandlers[OpenAI.ChatCompletionRequest.endpoint] = { request in
                    return (.success(try self.getData(filename: "tool_call_stream_response", fileExtension: "txt")!), 200)
                }
                return "27"
            }))]
        let request = OpenAI.ChatCompletionRequest(model: .gpt4Turbo, messages: [.init(role: .user, content: "Hi")], stream: true, tools: tools)
        var results: [OpenAI.ChatCompletionResponse] = []
        for try await response in api.stream(request: request) {
            results.append(response)
        }
        XCTAssertEqual(results[0].choices[0].delta?.role, .assistant)
        XCTAssertEqual(results[0].choices[0].delta?.tool_calls?[0].function.name, "getCurrentWeather")
        let arguments = results.reduce("") { $0 + (!$1.choices.isEmpty ? ($1.choices[0].delta?.tool_calls?[0].function.arguments ?? "") : "") }
        XCTAssertEqual(arguments, "{\n  \"format\": \"fahrenheit\",\n  \"location\": \"Bangkok\"\n}")
        XCTAssertEqual(results[19].choices[0].finish_reason, .tool_calls)
        let content = results.reduce("") { $0 + (!$1.choices.isEmpty ? ($1.choices[0].delta?.content ?? "") : "") }
        XCTAssertEqual(content, "The current weather in Bangkok, Thailand is 27°C.")
    }
}

