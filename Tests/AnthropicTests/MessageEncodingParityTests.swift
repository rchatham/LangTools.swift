import XCTest
@testable import Anthropic

final class MessageEncodingParityTests: XCTestCase {
    private struct Reference: Encodable {
        let message: Anthropic.Message

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: Anthropic.Message.CodingKeys.self)
            try container.encode(message.role, forKey: .role)
            try container.encode(message.content, forKey: .content)
        }
    }

    func testEncodingMatchesReferenceForStringsAndBlocks() throws {
        var messages = [Anthropic.Message]()
        for role: Anthropic.Role in [.user, .assistant] {
            for content: Anthropic.Content in [.string(""), .string("héllo 🌍\n\"quoted\""), .array([])] {
                messages.append(.init(role: role, content: content))
            }
        }
        let fixtures = [
            #"{"role":"user","content":[{"type":"text","text":"hello"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AA=="}}]}"#,
            #"{"role":"assistant","content":[{"type":"tool_use","id":"call_1","name":"weather","input":{"location":"SF"}}]}"#,
            #"{"role":"user","content":[{"type":"tool_result","tool_use_id":"call_1","content":"sunny","is_error":false}]}"#
        ]
        for fixture in fixtures {
            messages.append(try JSONDecoder().decode(Anthropic.Message.self, from: Data(fixture.utf8)))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for message in messages {
            XCTAssertEqual(try encoder.encode(message), try encoder.encode(Reference(message: message)))
        }
    }
}
