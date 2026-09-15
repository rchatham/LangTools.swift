import XCTest
@testable import OpenAI

final class MessageEncodingParityTests: XCTestCase {
    /// Reference implementation of the pre-optimization wire encoding.
    private struct Reference: Encodable {
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

    func testEncodingMatchesReferenceForAllContentShapes() throws {
        var messages = [OpenAI.Message]()
        for role: OpenAI.Message.Role in [.system, .developer, .user, .assistant, .tool] {
            for content: OpenAI.Message.Content in [.string(""), .string("héllo 🌍\n\"quoted\""), .null, .array([])] {
                messages.append(.init(role: role, content: content))
            }
        }
        messages.append(.init(tool_selection_id: "call_1", result: "{\"ok\":true}"))
        // Decoded wire examples cover metadata and multimodal/tool-call fallbacks.
        let fixtures = [
            #"{"role":"assistant","content":null,"name":"agent","refusal":"no","audio":{"id":"audio_1","expires_at":123,"data":"AA==","transcript":"hello"},"tool_calls":[{"id":"call_1","type":"function","function":{"name":"weather","arguments":"{}"}}]}"#,
            #"{"role":"user","content":[{"type":"text","text":"hello"},{"type":"image_url","image_url":{"url":"https://example.com/image.png"}}]}"#
        ]
        for fixture in fixtures {
            messages.append(try JSONDecoder().decode(OpenAI.Message.self, from: Data(fixture.utf8)))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for message in messages {
            XCTAssertEqual(try encoder.encode(message), try encoder.encode(Reference(message: message)))
        }
    }
}
