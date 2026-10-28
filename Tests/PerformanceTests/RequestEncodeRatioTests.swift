import XCTest
import Foundation
import PerformanceTestUtils

/// Reporting only: no competitor dependencies and no new regression ceilings.
final class RequestEncodeRatioTests: XCTestCase {
    func testOpenAISimpleEncodeRatio() throws {
        try report(PerformanceFixtures.openAIChatCompletionRequest(messageCount: 1), key: "OpenAI.requestEncode.simple")
    }

    func testOpenAILargeEncodeRatio() throws {
        try report(PerformanceFixtures.openAIChatCompletionRequest(messageCount: 100), key: "OpenAI.requestEncode.largeConversation")
    }

    func testAnthropicSimpleEncodeRatio() throws {
        try report(PerformanceFixtures.anthropicMessageRequest(messageCount: 1), key: "Anthropic.requestEncode.simple")
    }

    func testAnthropicLargeEncodeRatio() throws {
        try report(PerformanceFixtures.anthropicMessageRequest(messageCount: 100), key: "Anthropic.requestEncode.largeConversation")
    }

    private func report<Request: Encodable>(_ request: Request, key: String) throws {
        let encoder = JSONEncoder()
        let payload = try encoder.encode(request)
        let object = try JSONSerialization.jsonObject(with: payload)
        var typedTimes = [Double]()
        var foundationTimes = [Double]()
        var bytes = 0
        func time(_ operation: () throws -> Data) rethrows -> Double {
            let start = ProcessInfo.processInfo.systemUptime
            for _ in 0..<200 { bytes += try operation().count }
            return ProcessInfo.processInfo.systemUptime - start
        }
        // Warm both paths; alternate order to reduce systematic thermal/order bias.
        _ = try time { try encoder.encode(request) }
        _ = try time { try JSONSerialization.data(withJSONObject: object) }
        for sample in 0..<7 {
            if sample.isMultiple(of: 2) {
                typedTimes.append(try time { try encoder.encode(request) })
                foundationTimes.append(try time { try JSONSerialization.data(withJSONObject: object) })
            } else {
                foundationTimes.append(try time { try JSONSerialization.data(withJSONObject: object) })
                typedTimes.append(try time { try encoder.encode(request) })
            }
        }
        XCTAssertGreaterThan(bytes, 0)
        let typedMedian = typedTimes.sorted()[3]
        let foundationMedian = foundationTimes.sorted()[3]
        XCTAssertGreaterThan(foundationMedian, 0)
        print("ENCODE_RATIO \(key) ratio=\(typedMedian / foundationMedian) typedSeconds=\(typedMedian) foundationSeconds=\(foundationMedian) iterations=200 samples=7")
    }
}
