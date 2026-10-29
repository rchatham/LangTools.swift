import XCTest
import Foundation
import OpenAI
import Anthropic
#if canImport(SwiftOpenAI)
@testable import SwiftOpenAI
#endif
#if canImport(SwiftAnthropic)
import SwiftAnthropic
#endif

struct PairedEncodeVariant {
    let name: String
    let encode: () throws -> Data

    init<Value: Encodable>(_ name: String, _ value: Value, encoder: JSONEncoder = JSONEncoder()) {
        self.name = name
        encode = { try encoder.encode(value) }
    }
}

struct PairedDecodeVariant {
    let name: String
    let decode: () throws -> Int

    init<Value: Decodable>(_ name: String, _ type: Value.Type, data: Data, decoder: JSONDecoder = JSONDecoder()) {
        self.name = name
        decode = {
            let value = try decoder.decode(type, from: data)
            return withExtendedLifetime(value) { MemoryLayout<Value>.size }
        }
    }
}

/// Optional release experiments, deliberately separate from historical XCTest measure snapshots.
final class PairedCompetitorBenchmarkTests: XCTestCase {
    static func text(_ index: Int, count: Int) -> String {
        count == 1 ? "What's the weather in SF?" : "Message \(index) with realistic content for benchmarking."
    }

    func testNormalizedOpenAIEncode() throws {
        try requireOptIn()
        for count in [1, 50] {
            let messages: [OpenAI.Message] = (0..<count).map {
                .init(role: $0.isMultiple(of: 2) ? .user : .assistant, content: Self.text($0, count: count))
            }
            let baseline = PairedEncodeVariant("LangTools", OpenAI.ChatCompletionRequest(model: .gpt4o, messages: messages, stream: false))
            var variants = Self.additionalEncodeVariants(count: count)
            #if canImport(SwiftOpenAI)
            let swiftMessages: [ChatCompletionParameters.Message] = (0..<count).map {
                .init(role: $0.isMultiple(of: 2) ? .user : .assistant, content: .text(Self.text($0, count: count)))
            }
            var swiftRequest = ChatCompletionParameters(messages: swiftMessages, model: .gpt4o)
            swiftRequest.stream = false
            variants.append(.init("SwiftOpenAI", swiftRequest))
            #endif
            try XCTSkipUnless(!variants.isEmpty, "Enable OpenAI competitor packages")
            for variant in variants {
                try assertEquivalent(baseline, variant)
                try timePair(key: "OpenAI.\(count).encode.LangToolsOver\(variant.name)", iterations: count == 1 ? 10_000 : 1_000,
                             a: { try variant.encode().count }, b: { try baseline.encode().count })
            }
        }
    }

    func testNormalizedAnthropicEncode() throws {
        try requireOptIn()
        #if canImport(SwiftAnthropic)
        for count in [1, 50] {
            let messages: [Anthropic.Message] = (0..<count).map {
                .init(role: $0.isMultiple(of: 2) ? .user : .assistant, content: Self.text($0, count: count))
            }
            let swiftMessages: [SwiftAnthropic.MessageParameter.Message] = (0..<count).map {
                .init(role: $0.isMultiple(of: 2) ? .user : .assistant, content: .text(Self.text($0, count: count)))
            }
            let baseline = PairedEncodeVariant("LangTools", Anthropic.MessageRequest(model: .claude46Sonnet, messages: messages, max_tokens: 4096, stream: false))
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let variant = PairedEncodeVariant("SwiftAnthropic", SwiftAnthropic.MessageParameter(model: .other("claude-sonnet-4-6"), messages: swiftMessages, maxTokens: 4096), encoder: encoder)
            try assertEquivalent(baseline, variant)
            try timePair(key: "Anthropic.\(count).encode.LangToolsOverSwiftAnthropic", iterations: count == 1 ? 10_000 : 1_000,
                         a: { try variant.encode().count }, b: { try baseline.encode().count })
        }
        #else
        throw XCTSkip("Enable SwiftAnthropic")
        #endif
    }

    func testPairedOpenAIDecode() throws {
        try requireOptIn()
        for (operation, data) in [("response", OpenAIBenchmarkTests.chatCompletionJSON), ("toolCall", OpenAIBenchmarkTests.toolCallJSON)] {
            let baseline = PairedDecodeVariant("LangTools", OpenAI.ChatCompletionResponse.self, data: data)
            var variants = Self.additionalDecodeVariants(data: data)
            #if canImport(SwiftOpenAI)
            variants.append(.init("SwiftOpenAI", ChatCompletionObject.self, data: data))
            #endif
            try XCTSkipUnless(!variants.isEmpty, "Enable OpenAI competitor packages")
            for variant in variants {
                try timePair(key: "OpenAI.\(operation).decode.LangToolsOver\(variant.name)", iterations: 5_000,
                             a: variant.decode, b: baseline.decode)
            }
        }
    }

    func testPairedAnthropicDecode() throws {
        try requireOptIn()
        #if canImport(SwiftAnthropic)
        for (operation, data) in [("response", AnthropicBenchmarkTests.messageResponseJSON), ("toolUse", AnthropicBenchmarkTests.toolUseResponseJSON)] {
            let baseline = PairedDecodeVariant("LangTools", Anthropic.MessageResponse.self, data: data)
            // SwiftAnthropic's model requires this strategy for snake_case API keys.
            // Match each SDK's valid configuration, not identical-but-incorrect settings.
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let variant = PairedDecodeVariant("SwiftAnthropic", SwiftAnthropic.MessageResponse.self, data: data, decoder: decoder)
            try timePair(key: "Anthropic.\(operation).decode.LangToolsOverSwiftAnthropic", iterations: 5_000,
                         a: variant.decode, b: baseline.decode)
        }
        #else
        throw XCTSkip("Enable SwiftAnthropic")
        #endif
    }

    private func requireOptIn() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LANGTOOLS_RUN_PAIRED_BENCHMARKS"] == "1",
                          "Set LANGTOOLS_RUN_PAIRED_BENCHMARKS=1 and enable competitor packages")
    }

    private func assertEquivalent(_ a: PairedEncodeVariant, _ b: PairedEncodeVariant) throws {
        let left = try JSONSerialization.jsonObject(with: a.encode())
        let right = try JSONSerialization.jsonObject(with: b.encode())
        let leftData = try JSONSerialization.data(withJSONObject: left, options: [.sortedKeys])
        let rightData = try JSONSerialization.data(withJSONObject: right, options: [.sortedKeys])
        guard leftData == rightData else {
            XCTFail("Wire mismatch \(a.name)/\(b.name): \(String(decoding: leftData, as: UTF8.self)) vs \(String(decoding: rightData, as: UTF8.self))")
            throw NSError(domain: "PairedBenchmarkWireMismatch", code: 1)
        }
    }

    private func timePair(key: String, iterations: Int, a: () throws -> Int, b: () throws -> Int) throws {
        var consumed = 0
        func batch(_ operation: () throws -> Int) rethrows -> Double {
            let start = ProcessInfo.processInfo.systemUptime
            for _ in 0..<iterations { consumed += try operation() }
            return ProcessInfo.processInfo.systemUptime - start
        }
        for _ in 0..<2 { _ = try batch(a); _ = try batch(b) }
        var aSamples = [Double]()
        var bSamples = [Double]()
        for sample in 0..<10 {
            if sample.isMultiple(of: 2) {
                aSamples.append(try batch(a)); bSamples.append(try batch(b))
            } else {
                bSamples.append(try batch(b)); aSamples.append(try batch(a))
            }
        }
        let ratios = zip(aSamples, bSamples).map { $1 / $0 }
        let sorted = ratios.sorted()
        let result: [String: Any] = ["key": key, "iterations": iterations, "aSeconds": aSamples, "bSeconds": bSamples,
                                     "pairedRatios": ratios, "medianPairedRatio": (sorted[4] + sorted[5]) / 2,
                                     "minPairedRatio": sorted.first!, "maxPairedRatio": sorted.last!, "consumed": consumed]
        XCTAssertGreaterThan(consumed, 0)
        PairedBenchmarkRecorder.emit(prefix: "PAIRED_COMPETITOR", json: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]))
    }
}
