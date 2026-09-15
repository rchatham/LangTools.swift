import Foundation
import XCTest
import OpenAI
import Anthropic
import PerformanceTestUtils

/// Bounded, independent conversations: decoding is setup, only accumulation is timed.
/// Keep the raw JSON chunks so the ratio baseline parses exactly the same payloads.
enum StreamingCombiningWorkload {
    static let textChunkCount = 32
    static let batchCount = 100
    static let expectedText = (0..<textChunkCount).map { "word\($0) " }.joined()

    static func payloads(_ data: Data) -> [Data] {
        String(decoding: data, as: UTF8.self).components(separatedBy: .newlines)
            .filter { $0.hasPrefix("data: ") && $0 != "data: [DONE]" }
            .map { Data($0.dropFirst(6).utf8) }
    }

    struct OpenAIStreams {
        let payloads: [[Data]]
        let streams: [[OpenAI.ChatCompletionResponse]]

        init() throws {
            payloads = [
                StreamingCombiningWorkload.payloads(PerformanceFixtures.openAIStreamChunksData(chunkCount: textChunkCount)),
                StreamingCombiningWorkload.payloads(PerformanceFixtures.openAIToolCallStreamData(toolCount: 3))
            ]
            streams = try payloads.map { try $0.map { try JSONDecoder().decode(OpenAI.ChatCompletionResponse.self, from: $0) } }
        }

        func combine() -> [OpenAI.ChatCompletionResponse] {
            streams.map { $0.reduce(.empty) { $0.combining(with: $1) } }
        }

        func validate(_ results: [OpenAI.ChatCompletionResponse], file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(results.count, 2, file: file, line: line)
            guard results.count == 2 else { return }
            XCTAssertEqual(results[0].choices.count, 1, file: file, line: line)
            XCTAssertEqual(results[0].choices.first?.message?.content.string, expectedText, file: file, line: line)
            XCTAssertEqual(results[1].choices.count, 1, file: file, line: line)
            let tools = results[1].choices.first?.message?.tool_calls ?? []
            XCTAssertEqual(tools.count, 3, file: file, line: line)
            for (index, tool) in tools.enumerated() {
                XCTAssertEqual(tool.id, "call_\(index)", file: file, line: line)
                XCTAssertEqual(tool.name, "get_weather", file: file, line: line)
                XCTAssertEqual(tool.arguments, "{\"location\": \"City\(index)\"}", file: file, line: line)
            }
        }
    }

    struct AnthropicStreams {
        let streams: [[Anthropic.MessageResponse]]

        init() throws {
            let data = [
                PerformanceFixtures.anthropicStreamData(chunkCount: textChunkCount),
                PerformanceFixtures.anthropicToolUseStreamData()
            ]
            streams = try data.map { try payloads($0).map { try JSONDecoder().decode(Anthropic.MessageResponse.self, from: $0) } }
        }

        func combine() -> [Anthropic.MessageResponse] {
            streams.map { $0.reduce(.empty) { $0.combining(with: $1) } }
        }

        func validate(_ results: [Anthropic.MessageResponse], file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(results.count, 2, file: file, line: line)
            guard results.count == 2 else { return }
            XCTAssertEqual(results[0].message?.content.string, expectedText, file: file, line: line)
            let tools = results[1].message?.tool_selection ?? []
            XCTAssertEqual(tools.count, 1, file: file, line: line)
            XCTAssertEqual(tools.first?.id, "toolu_test_001", file: file, line: line)
            XCTAssertEqual(tools.first?.name, "get_weather", file: file, line: line)
            XCTAssertEqual(tools.first?.arguments, "{\"location\": \"San Francisco\", \"unit\": \"fahrenheit\"}", file: file, line: line)
        }
    }
}

final class StreamingCombiningRegressionTests: XCTestCase {
    func testOpenAITextAndToolDeltasAccumulateExactly() throws {
        let workload = try StreamingCombiningWorkload.OpenAIStreams()
        workload.validate(workload.combine())
    }

    func testAnthropicTextAndToolDeltasAccumulateExactly() throws {
        let workload = try StreamingCombiningWorkload.AnthropicStreams()
        workload.validate(workload.combine())
    }
}
