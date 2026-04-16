//
//  AnthropicBenchmarkTests.swift
//  LangTools
//
//  Benchmarks comparing LangTools.Anthropic encoding/decoding performance
//  against SwiftAnthropic (jamesrochabrun/SwiftAnthropic) and raw Foundation
//  JSON operations as a baseline.
//

import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LangTools
@testable import Anthropic
@testable import TestUtils
import SwiftAnthropic

final class AnthropicBenchmarkTests: XCTestCase {

    // MARK: - Standard Anthropic Message JSON (shared across benchmarks)

    static let messageResponseJSON = """
    {
        "content": [{"text": "The weather in San Francisco is currently 72°F with partly cloudy skies. The humidity is at 65% and winds are coming from the west at 12 mph. It's a pleasant day overall, perfect for outdoor activities. I'd recommend wearing light layers as it may cool down in the evening.", "type": "text"}],
        "id": "msg_bench_001",
        "model": "claude-sonnet-4-6",
        "role": "assistant",
        "stop_reason": "end_turn",
        "stop_sequence": null,
        "type": "message",
        "usage": {"input_tokens": 25, "output_tokens": 60}
    }
    """.data(using: .utf8)!

    static let toolUseResponseJSON = """
    {
        "content": [
            {"text": "I'll check the weather for you.", "type": "text"},
            {"type": "tool_use", "id": "toolu_bench_001", "name": "get_weather", "input": {"location": "San Francisco, CA", "unit": "fahrenheit"}}
        ],
        "id": "msg_bench_tools",
        "model": "claude-sonnet-4-6",
        "role": "assistant",
        "stop_reason": "tool_use",
        "stop_sequence": null,
        "type": "message",
        "usage": {"input_tokens": 50, "output_tokens": 30}
    }
    """.data(using: .utf8)!

    static let multiBlockResponseJSON: Data = {
        var blocks = [String]()
        for i in 0..<5 {
            blocks.append("{\"text\": \"Response block \(i): This is a detailed response with enough content to represent a realistic model output. It includes multiple sentences to ensure meaningful payload size.\", \"type\": \"text\"}")
        }
        let content = blocks.joined(separator: ",")
        return """
        {
            "content": [\(content)],
            "id": "msg_bench_multi",
            "model": "claude-sonnet-4-6",
            "role": "assistant",
            "stop_reason": "end_turn",
            "stop_sequence": null,
            "type": "message",
            "usage": {"input_tokens": 50, "output_tokens": 300}
        }
        """.data(using: .utf8)!
    }()

    // MARK: - Foundation Baseline (JSONSerialization)

    func testBaseline_JSONSerialization_DecodeResponse() {
        measure {
            for _ in 0..<500 {
                _ = try! JSONSerialization.jsonObject(with: Self.messageResponseJSON, options: [])
            }
        }
    }

    func testBaseline_JSONSerialization_DecodeToolUseResponse() {
        measure {
            for _ in 0..<500 {
                _ = try! JSONSerialization.jsonObject(with: Self.toolUseResponseJSON, options: [])
            }
        }
    }

    func testBaseline_JSONSerialization_DecodeMultiBlock() {
        measure {
            for _ in 0..<200 {
                _ = try! JSONSerialization.jsonObject(with: Self.multiBlockResponseJSON, options: [])
            }
        }
    }

    // MARK: - LangTools.Anthropic Decode Benchmarks

    func testLangTools_DecodeResponse() {
        let decoder = JSONDecoder()
        measure {
            for _ in 0..<500 {
                _ = try! decoder.decode(Anthropic.MessageResponse.self, from: Self.messageResponseJSON)
            }
        }
    }

    func testLangTools_DecodeToolUseResponse() {
        let decoder = JSONDecoder()
        measure {
            for _ in 0..<500 {
                _ = try! decoder.decode(Anthropic.MessageResponse.self, from: Self.toolUseResponseJSON)
            }
        }
    }

    func testLangTools_DecodeMultiBlockResponse() {
        let decoder = JSONDecoder()
        measure {
            for _ in 0..<200 {
                _ = try! decoder.decode(Anthropic.MessageResponse.self, from: Self.multiBlockResponseJSON)
            }
        }
    }

    // MARK: - SwiftAnthropic Decode Benchmarks

    func testSwiftAnthropic_DecodeResponse() {
        let decoder = JSONDecoder()
        measure {
            for _ in 0..<500 {
                _ = try! decoder.decode(SwiftAnthropic.MessageResponse.self, from: Self.messageResponseJSON)
            }
        }
    }

    func testSwiftAnthropic_DecodeToolUseResponse() {
        let decoder = JSONDecoder()
        measure {
            for _ in 0..<500 {
                _ = try! decoder.decode(SwiftAnthropic.MessageResponse.self, from: Self.toolUseResponseJSON)
            }
        }
    }

    func testSwiftAnthropic_DecodeMultiBlockResponse() {
        let decoder = JSONDecoder()
        measure {
            for _ in 0..<200 {
                _ = try! decoder.decode(SwiftAnthropic.MessageResponse.self, from: Self.multiBlockResponseJSON)
            }
        }
    }

    // MARK: - LangTools.Anthropic Encode Benchmarks

    func testLangTools_EncodeRequest_Simple() {
        let request = Anthropic.MessageRequest(
            model: .claude46Sonnet,
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
        let tools: [Anthropic.Tool] = [.init(
            name: "get_weather",
            description: "Get the current weather in a given location",
            tool_schema: .init(
                properties: [
                    "location": .init(type: "string", description: "City and state"),
                    "unit": .init(type: "string", enumValues: ["celsius", "fahrenheit"], description: "Temperature unit"),
                ],
                required: ["location"]
            )
        )]
        let request = Anthropic.MessageRequest(
            model: .claude46Sonnet,
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
        let messages: [Anthropic.Message] = (0..<50).map { i in
            Anthropic.Message(role: i % 2 == 0 ? .user : .assistant,
                              content: "Message \(i) with realistic content for benchmarking encoding performance across conversation turns.")
        }
        let request = Anthropic.MessageRequest(model: .claude46Sonnet, messages: messages)
        let encoder = JSONEncoder()
        measure {
            for _ in 0..<100 {
                _ = try! encoder.encode(request)
            }
        }
    }

    // MARK: - SwiftAnthropic Encode Benchmarks

    func testSwiftAnthropic_EncodeRequest_Simple() {
        let parameters = MessageParameter(
            model: .claude46Sonnet,
            messages: [.init(role: .user, content: .text("What's the weather in SF?"))],
            maxTokens: 4096
        )
        let encoder = JSONEncoder()
        measure {
            for _ in 0..<500 {
                _ = try! encoder.encode(parameters)
            }
        }
    }

    func testSwiftAnthropic_EncodeRequest_LargeConversation() {
        let messages: [MessageParameter.Message] = (0..<50).map { i in
            .init(role: i % 2 == 0 ? .user : .assistant,
                  content: .text("Message \(i) with realistic content for benchmarking encoding performance across conversation turns."))
        }
        let parameters = MessageParameter(
            model: .claude46Sonnet,
            messages: messages,
            maxTokens: 4096
        )
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
        let request = Anthropic.MessageRequest(
            model: .claude46Sonnet,
            messages: [.init(role: .user, content: "Round-trip benchmark test")]
        )
        measure {
            for _ in 0..<200 {
                let data = try! encoder.encode(request)
                _ = try! decoder.decode(Anthropic.MessageRequest.self, from: data)
            }
        }
    }

    // MARK: - Message Construction Comparison

    func testLangTools_MessageConstruction() {
        measure {
            for _ in 0..<1000 {
                _ = Anthropic.Message(role: .user, content: "Hello, what's the weather?")
                _ = Anthropic.Message(role: .assistant, content: "The weather is sunny and 72°F.")
            }
        }
    }

    func testSwiftAnthropic_MessageConstruction() {
        measure {
            for _ in 0..<1000 {
                _ = MessageParameter.Message(role: .user, content: .text("Hello, what's the weather?"))
                _ = MessageParameter.Message(role: .assistant, content: .text("The weather is sunny and 72°F."))
            }
        }
    }

    // MARK: - Stream Decode Comparison

    func testLangTools_StreamLineDecode() {
        let lines: [String] = (0..<100).map { i in
            "data: {\"type\": \"content_block_delta\", \"index\": 0, \"delta\": {\"type\": \"text_delta\", \"text\": \"word\(i) \"}}"
        }
        measure {
            for line in lines {
                for _ in 0..<50 {
                    let _: Anthropic.MessageResponse? = try! Anthropic.decodeStream(line)
                }
            }
        }
    }

    // MARK: - Content Block Type Overhead

    func testLangTools_ContentBlockDecoding() {
        let jsonWithMultipleBlockTypes = """
        {
            "content": [
                {"text": "Here's the analysis:", "type": "text"},
                {"type": "tool_use", "id": "toolu_1", "name": "analyze", "input": {"data": "sample"}},
                {"text": "Based on the analysis above...", "type": "text"}
            ],
            "id": "msg_blocks",
            "model": "claude-sonnet-4-6",
            "role": "assistant",
            "stop_reason": "end_turn",
            "stop_sequence": null,
            "type": "message",
            "usage": {"input_tokens": 30, "output_tokens": 40}
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        measure {
            for _ in 0..<500 {
                _ = try! decoder.decode(Anthropic.MessageResponse.self, from: jsonWithMultipleBlockTypes)
            }
        }
    }

    func testSwiftAnthropic_ContentBlockDecoding() {
        let jsonWithMultipleBlockTypes = """
        {
            "content": [
                {"text": "Here's the analysis:", "type": "text"},
                {"type": "tool_use", "id": "toolu_1", "name": "analyze", "input": {"data": "sample"}},
                {"text": "Based on the analysis above...", "type": "text"}
            ],
            "id": "msg_blocks",
            "model": "claude-sonnet-4-6",
            "role": "assistant",
            "stop_reason": "end_turn",
            "stop_sequence": null,
            "type": "message",
            "usage": {"input_tokens": 30, "output_tokens": 40}
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        measure {
            for _ in 0..<500 {
                _ = try! decoder.decode(SwiftAnthropic.MessageResponse.self, from: jsonWithMultipleBlockTypes)
            }
        }
    }
}
