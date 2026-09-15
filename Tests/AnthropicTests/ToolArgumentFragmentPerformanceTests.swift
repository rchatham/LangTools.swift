import Foundation
import XCTest
import Anthropic
import LangTools

/// Opt-in, local-only measurements. Event decoding and correctness checks are outside
/// the timed region. These report absolute combining costs, not an asserted speedup.
final class ToolArgumentFragmentPerformanceTests: XCTestCase {
    func test8KiBArgumentsIn16CharacterChunks() throws {
        try measureCombining(payloadSize: 8 * 1024, chunkSize: 16)
    }

    func test64KiBArgumentsIn16CharacterChunks() throws {
        try measureCombining(payloadSize: 64 * 1024, chunkSize: 16)
    }

    func test64KiBArgumentsIn256CharacterChunks() throws {
        try measureCombining(payloadSize: 64 * 1024, chunkSize: 256)
    }

    func test64KiBArgumentsIn4096CharacterChunks() throws {
        try measureCombining(payloadSize: 64 * 1024, chunkSize: 4096)
    }

    private func measureCombining(payloadSize: Int, chunkSize: Int) throws {
        guard ProcessInfo.processInfo.environment["LANGTOOLS_RUN_TOOL_ARGUMENT_BENCHMARKS"] == "1" else {
            throw XCTSkip("Set LANGTOOLS_RUN_TOOL_ARGUMENT_BENCHMARKS=1 for local fragmented-tool measurements")
        }
        let arguments = "{\"payload\":\"" + String(repeating: "x", count: payloadSize) + "\",\"enabled\":true}"
        let decoder = JSONDecoder()
        let start = try decoder.decode(Anthropic.MessageResponse.self, from: Data(#"{"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"test-model","content":[],"usage":{"input_tokens":1,"output_tokens":0}}}"#.utf8))
        let blockStart = try decoder.decode(Anthropic.MessageResponse.self, from: Data(#"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tool_1","name":"lookup","input":{}}}"#.utf8))
        let initial = start.combining(with: blockStart)
        let characters = Array(arguments)
        let chunks = try stride(from: 0, to: characters.count, by: chunkSize).map { offset in
            let chunk = String(characters[offset..<min(offset + chunkSize, characters.count)])
            let data = try JSONSerialization.data(withJSONObject: [
                "type": "content_block_delta", "index": 0,
                "delta": ["type": "input_json_delta", "partial_json": chunk]
            ])
            return try decoder.decode(Anthropic.MessageResponse.self, from: data)
        }
        func combine() -> Anthropic.MessageResponse {
            chunks.reduce(initial) { $0.combining(with: $1) }
        }
        func validate(_ response: Anthropic.MessageResponse) throws {
            let tool = try XCTUnwrap(response.message?.tool_selection?.first)
            XCTAssertEqual(tool.id, "tool_1")
            XCTAssertEqual(tool.arguments, arguments)
            XCTAssertEqual(tool.inputJSON, try JSON(string: arguments))
            let encoded = try JSONDecoder().decode([String: JSON].self, from: JSONEncoder().encode(tool))
            XCTAssertEqual(encoded["input"], try JSON(string: arguments))
        }
        try validate(combine())
        print("TOOL_ARGUMENT_WORKLOAD payloadBytes=\(payloadSize) argumentBytes=\(arguments.utf8.count) chunkCharacters=\(chunkSize) events=\(chunks.count)")
        var result = initial
        measure {
            result = combine()
        }
        try validate(result)
    }
}
