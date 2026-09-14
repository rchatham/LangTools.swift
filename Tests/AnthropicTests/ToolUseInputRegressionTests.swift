import Foundation
import XCTest
import Anthropic
import LangTools

final class ToolUseInputRegressionTests: XCTestCase {
    private typealias ToolUse = Anthropic.Content.ContentType.ToolUse

    private let inputs = [
        #"{"nested":{"enabled":true,"nothing":null},"items":[1,"two",false]}"#,
        "{}", #"[1,"two",false,null,{"nested":[]}]"#, "[]",
        #""quoted \"value\" and \n newline 雪""#, "\"\"",
        "0", "-42", "3.125", "1e20", "true", "false"
    ]

    func testDecodedInputAcceptsEveryNonNullJSONKindAndRoundTrips() throws {
        for input in inputs {
            let tool = try decode(input: input)
            let expected = try JSON(string: input)
            XCTAssertEqual(tool.id, "tool_1")
            XCTAssertEqual(tool.name, "lookup")
            XCTAssertEqual(tool.inputJSON, expected, input)
            XCTAssertEqual(try JSON(string: tool.input), expected, input)
            XCTAssertEqual(tool.arguments, tool.input)
            XCTAssertEqual(try encodedInput(tool), expected, input)
            let roundTrip = try JSONDecoder().decode(ToolUse.self, from: JSONEncoder().encode(tool))
            XCTAssertEqual(roundTrip.inputJSON, expected, input)
        }
    }

    func testMissingAndNullDecodedInputRemainEmptyAndAreOmittedOnEncode() throws {
        for input in [nil, "null"] as [String?] {
            let tool = try decode(input: input)
            XCTAssertNil(tool.inputJSON)
            XCTAssertEqual(tool.input, "")
            XCTAssertEqual(tool.arguments, "")
            XCTAssertNil(try encodedInput(tool))
        }
    }

    func testStringInitializerPreservesExactSourceAndPublicParsedReadForEveryJSONKind() throws {
        // An explicitly supplied string containing null remains JSON null on encode;
        // a decoded null field, like a missing field, retains the historical empty behavior.
        for input in inputs + ["null", "  { \"value\" : [ true, null ] } \n"] {
            let tool = ToolUse(id: "tool_1", name: "lookup", input: input)
            let expected = try JSON(string: input)
            XCTAssertEqual(tool.input, input)
            XCTAssertEqual(tool.arguments, input)
            XCTAssertEqual(tool.inputJSON, expected, input)
            XCTAssertEqual(tool.inputJSON, expected, "Repeated reads must be stable")
            XCTAssertEqual(try encodedInput(tool), expected, input)
        }
    }

    func testEmptyAndIncompleteStringInputsKeepPublicReadsAndEncodingBehavior() throws {
        let empty = ToolUse(id: nil, name: nil, input: "")
        XCTAssertNil(empty.inputJSON)
        XCTAssertEqual(empty.input, "")
        XCTAssertNil(try encodedInput(empty))
        for input in ["{", #"{"query":"unfinished"#, "[1,", "not JSON", " "] {
            let tool = ToolUse(id: nil, name: nil, input: input)
            XCTAssertEqual(tool.input, input)
            XCTAssertEqual(tool.arguments, input)
            XCTAssertNil(tool.inputJSON)
            XCTAssertThrowsError(try JSONEncoder().encode(tool), input)
        }
    }

    func testInvalidMetadataAndMalformedJSONStillThrow() {
        for source in [#"{"id":1,"input":[]}"#, #"{"name":false,"input":true}"#,
                       #"{"input":{"unfinished":}}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(ToolUse.self, from: Data(source.utf8)))
        }
    }

    func testStreamingPrefixesAndFinalArgumentsAreExactAcrossChunkSizes() throws {
        let arguments = #"{ "query": "escaped \"quote\", slash \\, newline \n, unicode 雪🙂", "items": [1, true, null, {"nested": "value"}] }"#
        for chunkSize in [1, 2, 7, 31, arguments.count] {
            var response = try streamStart()
            let characters = Array(arguments)
            var prefix = ""
            for offset in stride(from: 0, to: characters.count, by: chunkSize) {
                let chunk = String(characters[offset..<min(offset + chunkSize, characters.count)])
                let event = try delta(chunk, index: 0)
                let previous = response
                response = response.combining(with: event)
                prefix += chunk
                let tool = try XCTUnwrap(response.message?.tool_selection?.first)
                XCTAssertEqual(tool.input, prefix)
                XCTAssertEqual(tool.arguments, prefix)
                XCTAssertEqual(tool.inputJSON, try? JSON(string: prefix))
                // Combining must not mutate prior response values.
                XCTAssertEqual(previous.message?.tool_selection?.first?.arguments, String(prefix.dropLast(chunk.count)))
            }
            response = response.combining(with: try event(#"{"type":"content_block_stop","index":0}"#))
            response = response.combining(with: try event(#"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":10}}"#))
            response = response.combining(with: try event(#"{"type":"message_stop"}"#))
            let tool = try XCTUnwrap(response.message?.tool_selection?.first)
            XCTAssertEqual(tool.id, "tool_1")
            XCTAssertEqual(tool.name, "lookup")
            XCTAssertEqual(tool.arguments, arguments)
            XCTAssertEqual(try encodedInput(tool), try JSON(string: arguments))
        }
    }

    func testStreamingMultipleToolsKeepArgumentsSeparate() throws {
        var response = try streamStart()
        response = response.combining(with: try delta(#"{"first":"#, index: 0))
        response = response.combining(with: try event(#"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"tool_2","name":"other","input":{}}}"#))
        response = response.combining(with: try delta(#"{"second":["#, index: 1))
        response = response.combining(with: try delta("true}", index: 0))
        response = response.combining(with: try delta("1,null]}", index: 1))
        let tools = try XCTUnwrap(response.message?.tool_selection)
        XCTAssertEqual(tools.map(\.id), ["tool_1", "tool_2"])
        XCTAssertEqual(tools.map(\.arguments), [#"{"first":true}"#, #"{"second":[1,null]}"#])
        for tool in tools {
            XCTAssertEqual(try encodedInput(tool), try JSON(string: tool.arguments))
        }
    }

    private func decode(input: String?) throws -> ToolUse {
        let field = input.map { ",\"input\":\($0)" } ?? ""
        return try JSONDecoder().decode(ToolUse.self, from: Data("{\"type\":\"tool_use\",\"id\":\"tool_1\",\"name\":\"lookup\"\(field)}".utf8))
    }

    private func encodedInput(_ tool: ToolUse) throws -> JSON? {
        let fields = try JSONDecoder().decode([String: JSON].self, from: JSONEncoder().encode(tool))
        XCTAssertEqual(fields["type"], .string("tool_use"))
        return fields["input"]
    }

    private func event(_ source: String) throws -> Anthropic.MessageResponse {
        try JSONDecoder().decode(Anthropic.MessageResponse.self, from: Data(source.utf8))
    }

    private func streamStart() throws -> Anthropic.MessageResponse {
        let start = try event(#"{"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"test-model","content":[],"stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":1,"output_tokens":0}}}"#)
        return start.combining(with: try event(#"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tool_1","name":"lookup","input":{}}}"#))
    }

    private func delta(_ chunk: String, index: Int) throws -> Anthropic.MessageResponse {
        let data = try JSONSerialization.data(withJSONObject: [
            "type": "content_block_delta", "index": index,
            "delta": ["type": "input_json_delta", "partial_json": chunk]
        ])
        return try JSONDecoder().decode(Anthropic.MessageResponse.self, from: data)
    }
}
