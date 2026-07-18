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
    // The streamed-response accumulator was the ~3× outlier. Baseline: parsing the same
    // single-choice payload. Combining a decoded response should stay within a small multiple
    // of raw-parse cost — that multiple is the invariant we lock in.

    func testGate_OpenAIResponseCombining() throws {
        let singleData = PerformanceFixtures.openAIChatCompletionResponseJSON(choiceCount: 1)
        let response = try JSONDecoder().decode(OpenAI.ChatCompletionResponse.self, from: singleData)
        let iterations = 2500

        assertWithinRatio(
            of: {
                for _ in 0..<iterations {
                    _ = try! JSONSerialization.jsonObject(with: singleData)
                }
            },
            {
                var combined = OpenAI.ChatCompletionResponse.empty
                for _ in 0..<iterations {
                    combined = combined.combining(with: response)
                }
            },
            maxRatio: 6.0,
            key: "OpenAI.responseCombining")
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
