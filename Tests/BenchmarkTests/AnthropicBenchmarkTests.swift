//
//  AnthropicBenchmarkTests.swift
//  LangTools
//
//  Benchmarks comparing LangTools.Anthropic encoding/decoding performance
//  against SwiftAnthropic and raw Foundation JSON operations as a baseline.
//
//  To enable competitor benchmarks, uncomment the SwiftAnthropic dependency
//  in Package.swift.
//

import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LangTools
@testable import Anthropic
@testable import TestUtils
#if canImport(SwiftAnthropic)
import SwiftAnthropic
#endif

final class AnthropicBenchmarkTests: XCTestCase {

    static let messageResponseJSON = """
    {"content":[{"text":"The weather in San Francisco is currently 72°F with partly cloudy skies. The humidity is at 65% and winds are coming from the west at 12 mph.","type":"text"}],"id":"msg_bench","model":"claude-sonnet-4-6","role":"assistant","stop_reason":"end_turn","stop_sequence":null,"type":"message","usage":{"input_tokens":25,"output_tokens":60}}
    """.data(using: .utf8)!

    static let toolUseResponseJSON = """
    {"content":[{"text":"I'll check the weather.","type":"text"},{"type":"tool_use","id":"toolu_1","name":"get_weather","input":{"location":"San Francisco","unit":"fahrenheit"}}],"id":"msg_bench_tool","model":"claude-sonnet-4-6","role":"assistant","stop_reason":"tool_use","stop_sequence":null,"type":"message","usage":{"input_tokens":50,"output_tokens":30}}
    """.data(using: .utf8)!

    // MARK: - Decode: Foundation Baseline

    func testBaseline_DecodeResponse() {
        measure {
            for _ in 0..<500 {
                _ = try! JSONSerialization.jsonObject(with: Self.messageResponseJSON)
            }
        }
    }

    // MARK: - Decode: LangTools.Anthropic

    func testLangTools_DecodeResponse() {
        let decoder = JSONDecoder()
        XCTAssertNoThrow(try decoder.decode(Anthropic.MessageResponse.self, from: Self.messageResponseJSON), "Fixture validation")
        measure {
            for _ in 0..<500 {
                _ = try! decoder.decode(Anthropic.MessageResponse.self, from: Self.messageResponseJSON)
            }
        }
    }

    func testLangTools_DecodeToolUseResponse() {
        let decoder = JSONDecoder()
        XCTAssertNoThrow(try decoder.decode(Anthropic.MessageResponse.self, from: Self.toolUseResponseJSON), "Fixture validation")
        measure {
            for _ in 0..<500 {
                _ = try! decoder.decode(Anthropic.MessageResponse.self, from: Self.toolUseResponseJSON)
            }
        }
    }

    // MARK: - Decode: SwiftAnthropic

    #if canImport(SwiftAnthropic)
    func testSwiftAnthropic_DecodeResponse() {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        measure {
            for _ in 0..<500 {
                _ = try! decoder.decode(SwiftAnthropic.MessageResponse.self, from: Self.messageResponseJSON)
            }
        }
    }

    func testSwiftAnthropic_DecodeToolUseResponse() {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        measure {
            for _ in 0..<500 {
                _ = try! decoder.decode(SwiftAnthropic.MessageResponse.self, from: Self.toolUseResponseJSON)
            }
        }
    }
    #endif

    // MARK: - Encode: LangTools.Anthropic

    func testLangTools_EncodeRequest() {
        let request = Anthropic.MessageRequest(
            model: .claude46Sonnet,
            messages: [.init(role: .user, content: "What's the weather in SF?")]
        )
        let encoder = JSONEncoder()
        XCTAssertNoThrow(try encoder.encode(request), "Fixture validation")
        measure {
            for _ in 0..<500 {
                _ = try! encoder.encode(request)
            }
        }
    }

    func testLangTools_EncodeRequest_LargeConversation() {
        let messages: [Anthropic.Message] = (0..<50).map { i in
            Anthropic.Message(role: i % 2 == 0 ? .user : .assistant,
                              content: "Message \(i) with realistic content for benchmarking.")
        }
        let request = Anthropic.MessageRequest(model: .claude46Sonnet, messages: messages)
        let encoder = JSONEncoder()
        XCTAssertNoThrow(try encoder.encode(request), "Fixture validation")
        measure {
            for _ in 0..<100 {
                _ = try! encoder.encode(request)
            }
        }
    }

    // MARK: - Encode: SwiftAnthropic

    #if canImport(SwiftAnthropic)
    func testSwiftAnthropic_EncodeRequest() {
        let params = MessageParameter(
            model: .other("claude-sonnet-4-6"),
            messages: [.init(role: .user, content: .text("What's the weather in SF?"))],
            maxTokens: 4096
        )
        let encoder = JSONEncoder()
        measure {
            for _ in 0..<500 {
                _ = try! encoder.encode(params)
            }
        }
    }

    func testSwiftAnthropic_EncodeRequest_LargeConversation() {
        let messages: [MessageParameter.Message] = (0..<50).map { i in
            .init(role: i % 2 == 0 ? .user : .assistant,
                  content: .text("Message \(i) with realistic content for benchmarking."))
        }
        let params = MessageParameter(
            model: .other("claude-sonnet-4-6"),
            messages: messages,
            maxTokens: 4096
        )
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
                _ = Anthropic.Message(role: .user, content: "Hello, what's the weather?")
                _ = Anthropic.Message(role: .assistant, content: "It's sunny and 72°F.")
            }
        }
    }

    #if canImport(SwiftAnthropic)
    func testSwiftAnthropic_MessageConstruction() {
        measure {
            for _ in 0..<1000 {
                _ = MessageParameter.Message(role: .user, content: .text("Hello, what's the weather?"))
                _ = MessageParameter.Message(role: .assistant, content: .text("It's sunny and 72°F."))
            }
        }
    }
    #endif

    // MARK: - Stream Line Decode

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

    // MARK: - Round-Trip

    func testLangTools_RoundTrip() {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let request = Anthropic.MessageRequest(
            model: .claude46Sonnet,
            messages: [.init(role: .user, content: "Round-trip benchmark")]
        )
        measure {
            for _ in 0..<200 {
                let data = try! encoder.encode(request)
                _ = try! decoder.decode(Anthropic.MessageRequest.self, from: data)
            }
        }
    }
}
