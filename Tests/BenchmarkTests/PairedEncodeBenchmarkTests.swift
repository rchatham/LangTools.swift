import XCTest
import Foundation
@testable import OpenAI
@testable import Anthropic

/// Opt-in, same-process component experiments. Run in release with
/// LANGTOOLS_RUN_PAIRED_BENCHMARKS=1 Scripts/run-extended-tests.sh -c release --filter PairedEncodeBenchmarkTests
/// These report timings, not regression gates. Request mirrors only represent the fixtures below.
final class PairedEncodeBenchmarkTests: XCTestCase {
    private struct Request<Model: Encodable, Message: Encodable>: Encodable {
        let model: Model
        let messages: [Message]
        let max_tokens: Int?
    }

    /// Identical wrapper layout to LegacyOpenAI; forwards without adding an encoding container.
    private struct CurrentOpenAI: Encodable {
        let message: OpenAI.Message
        func encode(to encoder: Encoder) throws { try message.encode(to: encoder) }
    }

    private struct LegacyOpenAI: Encodable {
        let message: OpenAI.Message
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: OpenAI.Message.CodingKeys.self)
            try container.encode(message.role, forKey: .role)
            if let id = message.tool_call_id, let result = message.toolResult {
                try container.encode(id, forKey: .tool_call_id)
                try container.encode(OpenAI.Message.Content.string(result.result), forKey: .content)
            } else {
                try container.encode(message.content, forKey: .content)
            }
            try container.encodeIfPresent(message.name, forKey: .name)
            try container.encodeIfPresent(message.tool_calls, forKey: .tool_calls)
            try container.encodeIfPresent(message.audio, forKey: .audio)
            try container.encodeIfPresent(message.refusal, forKey: .refusal)
        }
    }

    private struct CurrentAnthropic: Encodable {
        let message: Anthropic.Message
        func encode(to encoder: Encoder) throws { try message.encode(to: encoder) }
    }

    private struct LegacyAnthropic: Encodable {
        let message: Anthropic.Message
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: Anthropic.Message.CodingKeys.self)
            try container.encode(message.role, forKey: .role)
            try container.encode(message.content, forKey: .content)
        }
    }

    private struct FlatMessage: Encodable {
        let role: String
        let content: String
    }

    func testOpenAIPairedEncoding() throws {
        try requireOptIn()
        for count in [1, 50] {
            let messages: [OpenAI.Message] = (0..<count).map {
                .init(role: $0.isMultiple(of: 2) ? .user : .assistant, content: text($0, count: count))
            }
            let production = OpenAI.ChatCompletionRequest(model: .gpt4o, messages: messages)
            let old = Request(model: production.model, messages: messages.map(LegacyOpenAI.init), max_tokens: nil)
            let current = Request(model: production.model, messages: messages.map(CurrentOpenAI.init), max_tokens: nil)
            let unwrapped = Request(model: production.model, messages: messages, max_tokens: nil)
            let flat = Request(model: production.model, messages: messages.map {
                FlatMessage(role: $0.role.rawValue, content: $0.content.string!)
            }, max_tokens: nil)
            let iterations = count == 1 ? 10_000 : 1_000
            try compare(old, current, key: "OpenAI.\(count).messageImplementation", iterations: iterations)
            try compare(unwrapped, current, key: "OpenAI.\(count).wrapperCalibration", iterations: iterations)
            try compare(unwrapped, production, key: "OpenAI.\(count).requestEnvelope", iterations: iterations)
            try compare(flat, unwrapped, key: "OpenAI.\(count).messageShape", iterations: iterations)
        }
    }

    func testAnthropicPairedEncoding() throws {
        try requireOptIn()
        for count in [1, 50] {
            let messages: [Anthropic.Message] = (0..<count).map {
                .init(role: $0.isMultiple(of: 2) ? .user : .assistant, content: text($0, count: count))
            }
            let production = Anthropic.MessageRequest(model: .claude46Sonnet, messages: messages)
            let old = Request(model: production.model, messages: messages.map(LegacyAnthropic.init), max_tokens: 4096)
            let current = Request(model: production.model, messages: messages.map(CurrentAnthropic.init), max_tokens: 4096)
            let unwrapped = Request(model: production.model, messages: messages, max_tokens: 4096)
            let flat = Request(model: production.model, messages: messages.map {
                FlatMessage(role: $0.role.rawValue, content: $0.content.string!)
            }, max_tokens: 4096)
            let iterations = count == 1 ? 10_000 : 1_000
            try compare(old, current, key: "Anthropic.\(count).messageImplementation", iterations: iterations)
            try compare(unwrapped, current, key: "Anthropic.\(count).wrapperCalibration", iterations: iterations)
            try compare(unwrapped, production, key: "Anthropic.\(count).requestEnvelope", iterations: iterations)
            try compare(flat, unwrapped, key: "Anthropic.\(count).messageShape", iterations: iterations)
        }
    }

    private func requireOptIn() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LANGTOOLS_RUN_PAIRED_BENCHMARKS"] == "1",
                          "Set LANGTOOLS_RUN_PAIRED_BENCHMARKS=1; prefer a release build")
    }

    private func text(_ index: Int, count: Int) -> String {
        count == 1 ? "What's the weather in SF?" : "Message \(index) with realistic content for benchmarking."
    }

    /// Ratio is B/A. For messageImplementation: current/legacy; requestEnvelope: production/minimal.
    func compare<A: Encodable, B: Encodable>(_ a: A, _ b: B, key: String, iterations: Int) throws {
        let validationEncoder = JSONEncoder()
        validationEncoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try validationEncoder.encode(a), try validationEncoder.encode(b), "Wire parity: \(key)")
        let encoder = JSONEncoder()
        var bytes = 0
        func batch<T: Encodable>(_ value: T) throws -> Double {
            let start = ProcessInfo.processInfo.systemUptime
            for _ in 0..<iterations { bytes += try encoder.encode(value).count }
            return ProcessInfo.processInfo.systemUptime - start
        }
        for _ in 0..<2 {
            _ = try batch(a)
            _ = try batch(b)
        }
        var aSamples = [Double]()
        var bSamples = [Double]()
        for sample in 0..<10 {
            if sample.isMultiple(of: 2) {
                aSamples.append(try batch(a))
                bSamples.append(try batch(b))
            } else {
                bSamples.append(try batch(b))
                aSamples.append(try batch(a))
            }
        }
        let ratios = zip(aSamples, bSamples).map { $1 / $0 }
        let sorted = ratios.sorted()
        let result: [String: Any] = [
            "key": key, "iterations": iterations, "warmupBatchesPerVariant": 2,
            "aSeconds": aSamples, "bSeconds": bSamples, "pairedRatios": ratios,
            "medianPairedRatio": (sorted[4] + sorted[5]) / 2,
            "minPairedRatio": sorted.first!, "maxPairedRatio": sorted.last!,
            "observedBytes": bytes
        ]
        XCTAssertGreaterThan(bytes, 0)
        let json = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        PairedBenchmarkRecorder.emit(prefix: "PAIRED_ENCODE", json: json)
    }
}
