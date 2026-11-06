import XCTest
import LangTools
@testable import Ollama

final class OllamaToolIdentityTests: XCTestCase {
    func testDecodedParallelCallsWithoutIDsHaveDistinctStableIdentities() throws {
        let data = Data(#"[{"function":{"name":"check_configuration","arguments":{}}},{"function":{"name":"list_mailboxes","arguments":{}}}]"#.utf8)
        let calls = try JSONDecoder().decode([Ollama.ChatToolCall].self, from: data)
        let ids = try calls.map { try XCTUnwrap($0.id) }
        XCTAssertEqual(Set(ids).count, 2, "Duplicate IDs cause Ollama cloud multi-tool continuations to fail.")
        XCTAssertTrue(ids.allSatisfy { !$0.isEmpty })
        let replay = try JSONDecoder().decode([Ollama.ChatToolCall].self, from: JSONEncoder().encode(calls))
        XCTAssertEqual(replay.map(\.id), calls.map(\.id), "Encoding a continuation must preserve correlation.")
    }

    func testProviderSuppliedIDSurvivesDecodeAndReplay() throws {
        let data = Data(#"{"id":"provider-call-42","function":{"name":"list_mailboxes","arguments":{}}}"#.utf8)
        let call = try JSONDecoder().decode(Ollama.ChatToolCall.self, from: data)
        XCTAssertEqual(call.id, "provider-call-42")
        let replay = try JSONDecoder().decode(Ollama.ChatToolCall.self, from: JSONEncoder().encode(call))
        XCTAssertEqual(replay.id, "provider-call-42")
    }

    func testConstructedCallsAndEmptyProviderIDsGetDistinctIdentities() throws {
        let first = Ollama.ChatToolCall(function: .init(name: "check", arguments: [:]))
        let second = Ollama.ChatToolCall(function: .init(name: "list", arguments: [:]))
        let empty = try JSONDecoder().decode(Ollama.ChatToolCall.self,
            from: Data(#"{"id":"","function":{"name":"list","arguments":{}}}"#.utf8))
        let ids = try [first, second, empty].map { try XCTUnwrap($0.id) }
        XCTAssertEqual(Set(ids).count, 3)
        XCTAssertTrue(ids.allSatisfy { !$0.isEmpty })
    }
}
