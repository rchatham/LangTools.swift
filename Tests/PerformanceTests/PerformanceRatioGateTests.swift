//
//  PerformanceRatioGateTests.swift
//  LangTools
//
//  Regression *gates* (not just reporting) for the hottest custom paths. Each asserts the
//  LangTools path stays within a committed multiple of a Foundation baseline over the same
//  payload — see `PerformanceRatioGate.swift` for why a ratio (rather than a wall-clock number)
//  is the machine-independent invariant. Ceilings live in `ratios.json`; re-record with
//  `RECORD_PERF_RATIOS=1 swift test --filter PerformanceRatioGateTests`.
//
//  Note: the high-RSD end-to-end streaming `measure` tests in OpenAIPerformanceTests are
//  deliberately NOT gated here — they time Task/run-loop dispatch, not parser throughput.
//

import XCTest
import Foundation
@testable import OpenAI
import PerformanceTestUtils

final class PerformanceRatioGateTests: XCTestCase {

    // MARK: - OpenAI.responseCombining
    //
    // Baseline parses the same text/tool delta JSON used by the accumulator. Each batch
    // resets independent conversations, bounding accumulated strings. This replaces the old
    // full-response workload; its historical ratios are not directly comparable.

    func testGate_OpenAIResponseCombining() throws {
        let workload = try StreamingCombiningWorkload.OpenAIStreams()
        workload.validate(workload.combine())
        var sink: [OpenAI.ChatCompletionResponse] = []

        assertWithinRatio(
            of: {
                for _ in 0..<StreamingCombiningWorkload.batchCount {
                    for stream in workload.payloads {
                        for payload in stream {
                            _ = try! JSONSerialization.jsonObject(with: payload)
                        }
                    }
                }
            },
            {
                for _ in 0..<StreamingCombiningWorkload.batchCount {
                    sink = workload.combine()
                }
            },
            maxRatio: 6.0,
            key: "OpenAI.responseCombining")
        workload.validate(sink)
    }

    // MARK: - OpenAI.manyChoicesDecode

    func testGate_OpenAIManyChoicesDecode() throws {
        let manyChoiceData = PerformanceFixtures.openAIChatCompletionResponseJSON(choiceCount: 20)
        let decoder = JSONDecoder()
        XCTAssertNoThrow(try decoder.decode(OpenAI.ChatCompletionResponse.self, from: manyChoiceData))
        let iterations = 500

        assertWithinRatio(
            of: {
                for _ in 0..<iterations {
                    _ = try! JSONSerialization.jsonObject(with: manyChoiceData)
                }
            },
            {
                for _ in 0..<iterations {
                    _ = try! decoder.decode(OpenAI.ChatCompletionResponse.self, from: manyChoiceData)
                }
            },
            maxRatio: 6.0,
            key: "OpenAI.manyChoicesDecode")
    }

    // MARK: - OpenAI.largeConversationEncode

    func testGate_OpenAILargeConversationEncode() throws {
        let request = PerformanceFixtures.openAIChatCompletionRequest(messageCount: 100)
        let encoder = JSONEncoder()
        // Foundation baseline: serialize an equivalent dictionary of the same encoded payload.
        let dict = try JSONSerialization.jsonObject(with: encoder.encode(request))
        let iterations = 200

        assertWithinRatio(
            of: {
                for _ in 0..<iterations {
                    _ = try! JSONSerialization.data(withJSONObject: dict)
                }
            },
            {
                for _ in 0..<iterations {
                    _ = try! encoder.encode(request)
                }
            },
            maxRatio: 6.0,
            key: "OpenAI.largeConversationEncode")
    }
}
