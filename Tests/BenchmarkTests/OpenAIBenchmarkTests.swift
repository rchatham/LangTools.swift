//
//  OpenAIBenchmarkTests.swift
//  LangTools
//
//  Benchmarks comparing LangTools.OpenAI encoding/decoding performance
//  against SwiftOpenAI (jamesrochabrun/SwiftOpenAI) and raw Foundation
//  JSON operations as a baseline.
//
//  These benchmarks use identical JSON payloads across all libraries to
//  ensure a fair comparison of type-safe decoding overhead.
//

import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LangTools
@testable import OpenAI
@testable import TestUtils
import SwiftOpenAI

final class OpenAIBenchmarkTests: XCTestCase {

    // MARK: - Standard OpenAI Chat Completion JSON (shared across benchmarks)

    /// A realistic chat completion response JSON matching the OpenAI API spec.
    static let chatCompletionJSON = """
    {
        "id": "chatcmpl-bench-001",
        "object": "chat.completion",
        "created": 1700000000,
        "model": "gpt-4o-2024-08-06",
        "system_fingerprint": "fp_benchmark_001",
        "choices": [{
            "index": 0,
            "message": {
                "role": "assistant",
                "content": "The weather in San Francisco is currently 72°F with partly cloudy skies. The humidity is at 65% and winds are coming from the west at 12 mph. It's a pleasant day overall, perfect for outdoor activities. I'd recommend wearing light layers as it may cool down in the evening."
            },
            "finish_reason": "stop"
        }],
        "usage": {
            "prompt_tokens": 25,
            "completion_tokens": 60,
            "total_tokens": 85
        }
    }
    """.data(using: .utf8)!

    static let chatCompletionWithToolsJSON = """
    {
        "id": "chatcmpl-bench-tools",
        "object": "chat.completion",
        "created": 1700000000,
        "model": "gpt-4o-2024-08-06",
        "system_fingerprint": "fp_benchmark_002",
        "choices": [{
            "index": 0,
            "message": {
                "role": "assistant",
                "content": null,
                "tool_calls": [{
                    "id": "call_benchmark_001",
                    "type": "function",
                    "function": {
                        "name": "get_weather",
                        "arguments": "{\\"location\\":\\"San Francisco, CA\\",\\"unit\\":\\"fahrenheit\\"}"
                    }
                }]
            },
            "finish_reason": "tool_calls"
        }],
        "usage": {
            "prompt_tokens": 50,
            "completion_tokens": 30,
            "total_tokens": 80
        }
    }
    """.data(using: .utf8)!

    static let multiChoiceJSON: Data = {
        let choices = (0..<5).map { i in
            """
            {
                "index": \(i),
                "message": {
                    "role": "assistant",
                    "content": "Response variant \(i): This is a detailed response with enough content to represent a realistic model output. It includes multiple sentences to ensure the JSON payload has meaningful size."
                },
                "finish_reason": "stop"
            }
            """
        }.joined(separator: ",")
        return """
        {
            "id": "chatcmpl-bench-multi",
            "object": "chat.completion",
            "created": 1700000000,
            "model": "gpt-4o-2024-08-06",
            "choices": [\(choices)],
            "usage": {"prompt_tokens": 25, "completion_tokens": 300, "total_tokens": 325}
        }
        """.data(using: .utf8)!
    }()

    // MARK: - Foundation Baseline (JSONSerialization)

    /// Baseline: raw JSONSerialization decode (no type safety, just parsing).
    func testBaseline_JSONSerialization_DecodeResponse() {
        measure {
            for _ in 0..<500 {
                _ = try! JSONSerialization.jsonObject(with: Self.chatCompletionJSON, options: [])
            }
        }
    }

    func testBaseline_JSONSerialization_DecodeToolCallResponse() {
        measure {
            for _ in 0..<500 {
                _ = try! JSONSerialization.jsonObject(with: Self.chatCompletionWithToolsJSON, options: [])
            }
        }
    }

    func testBaseline_JSONSerialization_DecodeMultiChoice() {
        measure {
            for _ in 0..<200 {
                _ = try! JSONSerialization.jsonObject(with: Self.multiChoiceJSON, options: [])
            }
        }
    }

    // MARK: - LangTools.OpenAI Decode Benchmarks

    func testLangTools_DecodeResponse() {
        let decoder = JSONDecoder()
        measure {
            for _ in 0..<500 {
                _ = try! decoder.decode(OpenAI.ChatCompletionResponse.self, from: Self.chatCompletionJSON)
            }
        }
    }

    func testLangTools_DecodeToolCallResponse() {
        let decoder = JSONDecoder()
        measure {
            for _ in 0..<500 {
                _ = try! decoder.decode(OpenAI.ChatCompletionResponse.self, from: Self.chatCompletionWithToolsJSON)
            }
        }
    }

    func testLangTools_DecodeMultiChoiceResponse() {
        let decoder = JSONDecoder()
        measure {
            for _ in 0..<200 {
                _ = try! decoder.decode(OpenAI.ChatCompletionResponse.self, from: Self.multiChoiceJSON)
            }
        }
    }

    // MARK: - SwiftOpenAI Decode Benchmarks

    func testSwiftOpenAI_DecodeResponse() {
        let decoder = JSONDecoder()
        measure {
            for _ in 0..<500 {
                _ = try! decoder.decode(ChatCompletionObject.self, from: Self.chatCompletionJSON)
            }
        }
    }

    func testSwiftOpenAI_DecodeToolCallResponse() {
        let decoder = JSONDecoder()
        measure {
            for _ in 0..<500 {
                _ = try! decoder.decode(ChatCompletionObject.self, from: Self.chatCompletionWithToolsJSON)
            }
        }
    }

    func testSwiftOpenAI_DecodeMultiChoiceResponse() {
        let decoder = JSONDecoder()
        measure {
            for _ in 0..<200 {
                _ = try! decoder.decode(ChatCompletionObject.self, from: Self.multiChoiceJSON)
            }
        }
    }

    // MARK: - LangTools.OpenAI Encode Benchmarks

    func testLangTools_EncodeRequest_Simple() {
        let request = OpenAI.ChatCompletionRequest(
            model: .gpt4o,
            messages: [.init(role: .user, content: "What's the weather in SF?")]
        )
        let encoder = JSONEncoder()
        measure {
            for _ in 0..<500 {
                _ = try! encoder.encode(request)
            }
        }
    }

    func testLangTools_EncodeRequest_WithTools() {
        let tools: [OpenAI.Tool] = [.function(.init(
            name: "get_weather",
            description: "Get the current weather in a given location",
            parameters: .init(
                properties: [
                    "location": .init(type: "string", description: "City and state"),
                    "unit": .init(type: "string", enumValues: ["celsius", "fahrenheit"], description: "Temperature unit"),
                ],
                required: ["location"]
            )
        ))]
        let request = OpenAI.ChatCompletionRequest(
            model: .gpt4o,
            messages: [.init(role: .user, content: "What's the weather?")],
            tools: tools
        )
        let encoder = JSONEncoder()
        measure {
            for _ in 0..<500 {
                _ = try! encoder.encode(request)
            }
        }
    }

    func testLangTools_EncodeRequest_LargeConversation() {
        let messages: [OpenAI.Message] = (0..<50).map { i in
            OpenAI.Message(role: i % 2 == 0 ? .user : .assistant,
                           content: "Message \(i) with realistic content for benchmarking encoding performance across conversation turns.")
        }
        let request = OpenAI.ChatCompletionRequest(model: .gpt4o, messages: messages)
        let encoder = JSONEncoder()
        measure {
            for _ in 0..<100 {
                _ = try! encoder.encode(request)
            }
        }
    }

    // MARK: - SwiftOpenAI Encode Benchmarks

    func testSwiftOpenAI_EncodeRequest_Simple() {
        let parameters = ChatCompletionParameters(
            messages: [.init(role: .user, content: .text("What's the weather in SF?"))],
            model: .gpt4o
        )
        let encoder = JSONEncoder()
        measure {
            for _ in 0..<500 {
                _ = try! encoder.encode(parameters)
            }
        }
    }

    func testSwiftOpenAI_EncodeRequest_LargeConversation() {
        let messages: [ChatCompletionParameters.Message] = (0..<50).map { i in
            .init(role: i % 2 == 0 ? .user : .assistant,
                  content: .text("Message \(i) with realistic content for benchmarking encoding performance across conversation turns."))
        }
        let parameters = ChatCompletionParameters(messages: messages, model: .gpt4o)
        let encoder = JSONEncoder()
        measure {
            for _ in 0..<100 {
                _ = try! encoder.encode(parameters)
            }
        }
    }

    // MARK: - Round-Trip Comparison

    func testLangTools_RoundTrip() {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let request = OpenAI.ChatCompletionRequest(
            model: .gpt4o,
            messages: [.init(role: .user, content: "Round-trip benchmark test message")]
        )
        measure {
            for _ in 0..<200 {
                let data = try! encoder.encode(request)
                _ = try! decoder.decode(OpenAI.ChatCompletionRequest.self, from: data)
            }
        }
    }

    // MARK: - Message Construction Comparison

    func testLangTools_MessageConstruction() {
        measure {
            for _ in 0..<1000 {
                _ = OpenAI.Message(role: .user, content: "Hello, what's the weather?")
                _ = OpenAI.Message(role: .assistant, content: "The weather is sunny and 72°F.")
                _ = OpenAI.Message(role: .system, content: "You are a helpful weather assistant.")
            }
        }
    }

    func testSwiftOpenAI_MessageConstruction() {
        measure {
            for _ in 0..<1000 {
                _ = ChatCompletionParameters.Message(role: .user, content: .text("Hello, what's the weather?"))
                _ = ChatCompletionParameters.Message(role: .assistant, content: .text("The weather is sunny and 72°F."))
                _ = ChatCompletionParameters.Message(role: .system, content: .text("You are a helpful weather assistant."))
            }
        }
    }

    // MARK: - Streaming Chunk Decode Comparison

    func testLangTools_StreamChunkDecode() {
        let chunks: [Data] = (0..<100).map { i in
            """
            {"id":"chatcmpl-bench","object":"chat.completion.chunk","created":1700000000,"model":"gpt-4o","choices":[{"index":0,"delta":{"content":"word\(i) "},"finish_reason":null}]}
            """.data(using: .utf8)!
        }
        let decoder = JSONDecoder()
        measure {
            for chunk in chunks {
                for _ in 0..<50 {
                    _ = try! decoder.decode(OpenAI.ChatCompletionResponse.self, from: chunk)
                }
            }
        }
    }

    func testSwiftOpenAI_StreamChunkDecode() {
        let chunks: [Data] = (0..<100).map { i in
            """
            {"id":"chatcmpl-bench","object":"chat.completion.chunk","created":1700000000,"model":"gpt-4o","choices":[{"index":0,"delta":{"content":"word\(i) "},"finish_reason":null}]}
            """.data(using: .utf8)!
        }
        let decoder = JSONDecoder()
        measure {
            for chunk in chunks {
                for _ in 0..<50 {
                    _ = try! decoder.decode(ChatCompletionChunkObject.self, from: chunk)
                }
            }
        }
    }
}
