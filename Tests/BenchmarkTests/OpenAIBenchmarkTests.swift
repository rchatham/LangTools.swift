//
//  OpenAIBenchmarkTests.swift
//  LangTools
//
//  Benchmarks comparing LangTools.OpenAI encoding/decoding performance
//  against SwiftOpenAI and raw Foundation JSON operations as a baseline.
//
//  To enable competitor benchmarks, uncomment the SwiftOpenAI dependency
//  in Package.swift.
//

import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LangTools
@testable import OpenAI
@testable import TestUtils
#if canImport(SwiftOpenAI)
import SwiftOpenAI
#endif

final class OpenAIBenchmarkTests: XCTestCase {

    static let chatCompletionJSON = """
    {"id":"chatcmpl-bench","object":"chat.completion","created":1700000000,"model":"gpt-4o-2024-08-06","system_fingerprint":"fp_bench","choices":[{"index":0,"message":{"role":"assistant","content":"The weather in San Francisco is currently 72°F with partly cloudy skies. The humidity is at 65% and winds are coming from the west at 12 mph."},"finish_reason":"stop"}],"usage":{"prompt_tokens":25,"completion_tokens":60,"total_tokens":85}}
    """.data(using: .utf8)!

    static let toolCallJSON = """
    {"id":"chatcmpl-bench-tool","object":"chat.completion","created":1700000000,"model":"gpt-4o-2024-08-06","choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"get_weather","arguments":"{\\"location\\":\\"San Francisco\\",\\"unit\\":\\"fahrenheit\\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":50,"completion_tokens":30,"total_tokens":80}}
    """.data(using: .utf8)!

    static let streamChunkJSON = """
    {"id":"chatcmpl-bench","object":"chat.completion.chunk","created":1700000000,"model":"gpt-4o","choices":[{"index":0,"delta":{"content":"Hello "},"finish_reason":null}]}
    """.data(using: .utf8)!

    // MARK: - Decode: Foundation Baseline

    func testBaseline_DecodeResponse() {
        measure {
            for _ in 0..<500 {
                _ = try! JSONSerialization.jsonObject(with: Self.chatCompletionJSON)
            }
        }
    }

    // MARK: - Decode: LangTools.OpenAI

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
                _ = try! decoder.decode(OpenAI.ChatCompletionResponse.self, from: Self.toolCallJSON)
            }
        }
    }

    func testLangTools_DecodeStreamChunk() {
        let decoder = JSONDecoder()
        measure {
            for _ in 0..<1000 {
                _ = try! decoder.decode(OpenAI.ChatCompletionResponse.self, from: Self.streamChunkJSON)
            }
        }
    }

    // MARK: - Decode: SwiftOpenAI

    #if canImport(SwiftOpenAI)
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
                _ = try! decoder.decode(ChatCompletionObject.self, from: Self.toolCallJSON)
            }
        }
    }

    func testSwiftOpenAI_DecodeStreamChunk() {
        let decoder = JSONDecoder()
        measure {
            for _ in 0..<1000 {
                _ = try! decoder.decode(ChatCompletionChunkObject.self, from: Self.streamChunkJSON)
            }
        }
    }
    #endif

    // MARK: - Encode: LangTools.OpenAI

    func testLangTools_EncodeRequest() {
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

    func testLangTools_EncodeRequest_LargeConversation() {
        let messages: [OpenAI.Message] = (0..<50).map { i in
            OpenAI.Message(role: i % 2 == 0 ? .user : .assistant,
                           content: "Message \(i) with realistic content for benchmarking.")
        }
        let request = OpenAI.ChatCompletionRequest(model: .gpt4o, messages: messages)
        let encoder = JSONEncoder()
        measure {
            for _ in 0..<100 {
                _ = try! encoder.encode(request)
            }
        }
    }

    // MARK: - Encode: SwiftOpenAI

    #if canImport(SwiftOpenAI)
    func testSwiftOpenAI_EncodeRequest() {
        let params = ChatCompletionParameters(
            messages: [.init(role: .user, content: .text("What's the weather in SF?"))],
            model: .gpt4o
        )
        let encoder = JSONEncoder()
        measure {
            for _ in 0..<500 {
                _ = try! encoder.encode(params)
            }
        }
    }

    func testSwiftOpenAI_EncodeRequest_LargeConversation() {
        let messages: [ChatCompletionParameters.Message] = (0..<50).map { i in
            .init(role: i % 2 == 0 ? .user : .assistant,
                  content: .text("Message \(i) with realistic content for benchmarking."))
        }
        let params = ChatCompletionParameters(messages: messages, model: .gpt4o)
        let encoder = JSONEncoder()
        measure {
            for _ in 0..<100 {
                _ = try! encoder.encode(params)
            }
        }
    }
    #endif

    // MARK: - Message Construction

    func testLangTools_MessageConstruction() {
        measure {
            for _ in 0..<1000 {
                _ = OpenAI.Message(role: .user, content: "Hello, what's the weather?")
                _ = OpenAI.Message(role: .assistant, content: "It's sunny and 72°F.")
                _ = OpenAI.Message(role: .system, content: "You are a helpful assistant.")
            }
        }
    }

    #if canImport(SwiftOpenAI)
    func testSwiftOpenAI_MessageConstruction() {
        measure {
            for _ in 0..<1000 {
                _ = ChatCompletionParameters.Message(role: .user, content: .text("Hello, what's the weather?"))
                _ = ChatCompletionParameters.Message(role: .assistant, content: .text("It's sunny and 72°F."))
                _ = ChatCompletionParameters.Message(role: .system, content: .text("You are a helpful assistant."))
            }
        }
    }
    #endif

    // MARK: - Round-Trip

    func testLangTools_RoundTrip() {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let request = OpenAI.ChatCompletionRequest(
            model: .gpt4o,
            messages: [.init(role: .user, content: "Round-trip benchmark")]
        )
        measure {
            for _ in 0..<200 {
                let data = try! encoder.encode(request)
                _ = try! decoder.decode(OpenAI.ChatCompletionRequest.self, from: data)
            }
        }
    }
}
