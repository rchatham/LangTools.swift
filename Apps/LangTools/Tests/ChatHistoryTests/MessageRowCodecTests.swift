import ChatUI
import Foundation
import XCTest
@testable import Chat
@testable import ChatHistory

final class MessageRowCodecTests: XCTestCase {
    private func roundTrip(_ messages: [Message]) throws -> [Message] {
        var rows: [MessageRow] = []
        var order: Int64 = 0
        for message in messages {
            for var row in try MessageRowCodec.rows(for: message, parentID: nil) {
                row.sortOrder = order
                order += 1
                rows.append(row)
            }
        }
        return MessageRowCodec.messages(from: rows)
    }

    func testEveryContentTypeAndTheFieldsTheLegacyStoreDroppedRoundTrip() throws {
        let cards = ContentCardsContent(cardType: "weather", message: "Sunny", cardsJSON: "[{\"t\":1}]", cardCount: 1)
        let assistant = Message(
            role: .assistant,
            contentType: .string("reply"),
            imageDetail: .high,
            createdAt: Date(timeIntervalSinceReferenceDate: 10.123456),
            toolCalls: [ChatToolCall(id: "call", name: "lookup", arguments: "{}", status: .success, result: "ok")],
            providerToolResults: ["call": "raw"],
            providerToolResultServices: ["call": .anthropic],
            responseToMessageID: UUID()
        )
        let stopped = text("stop me", .user, at: 9)
        stopped.wasResponseStopped = true
        let originals = [
            stopped,
            assistant,
            Message(role: .assistant, contentType: .array(["a", "b"]), createdAt: Date(timeIntervalSinceReferenceDate: 11)),
            Message(role: .assistant, contentType: .contentCards(cards), createdAt: Date(timeIntervalSinceReferenceDate: 12)),
            Message(role: .assistant, contentType: .null, createdAt: Date(timeIntervalSinceReferenceDate: 13)),
        ]

        let restored = try roundTrip(originals)

        XCTAssertEqual(restored, originals, "Message equality covers every persisted field")
        XCTAssertTrue(restored[0].wasResponseStopped)
        XCTAssertEqual(restored[1].imageDetail, .high)
        XCTAssertEqual(restored[1].providerToolResultServices, ["call": .anthropic])
        XCTAssertEqual(restored[1].responseToMessageID, assistant.responseToMessageID)
    }

    func testAgentEventTreesRebuildWithOrderedChildren() throws {
        let laterChild = Message.agentEvent(type: .completed, agentName: "Maps", details: "done")
        let earlierChild = Message.agentEvent(type: .toolCalled, agentName: "Maps", details: "search")
        let root = Message(
            role: .system,
            contentType: .agentEvent(AgentEventContent(type: .started, agentName: "Maps", details: "go", children: [laterChild, earlierChild])),
            createdAt: Date(timeIntervalSinceReferenceDate: 1)
        )
        // Rows are ordered by time first, so the earlier child comes first.
        let rows = try MessageRowCodec.rows(for: root, parentID: nil).enumerated().map { index, row -> MessageRow in
            var row = row
            row.sortOrder = Int64(index)
            if row.id == laterChild.uuid { row.createdAt = Date(timeIntervalSinceReferenceDate: 3) }
            if row.id == earlierChild.uuid { row.createdAt = Date(timeIntervalSinceReferenceDate: 2) }
            return row
        }

        let restored = try XCTUnwrap(MessageRowCodec.messages(from: rows).first)

        XCTAssertEqual(MessageRowCodec.messages(from: rows).count, 1)
        XCTAssertEqual(restored.childMessages.map(\.uuid), [earlierChild.uuid, laterChild.uuid])
    }

    func testEncodingNeverFollowsParentPointers() throws {
        let parent = Message.agentEvent(type: .started, agentName: "A", details: "root")
        let child = Message(
            role: .system,
            contentType: .agentEvent(AgentEventContent(type: .toolCalled, agentName: "A", details: "child", parent: parent))
        )
        parent.contentType = .agentEvent(AgentEventContent(type: .started, agentName: "A", details: "root", children: [child]))

        // A naive encode of `child` would recurse through parent -> children -> child.
        let rows = try MessageRowCodec.rows(for: parent, parentID: nil)

        XCTAssertEqual(rows.map(\.id), [parent.uuid, child.uuid])
        XCTAssertEqual(rows[1].parentID, parent.uuid)
        let payload = try XCTUnwrap(String(data: rows[1].payload, encoding: .utf8))
        XCTAssertFalse(payload.contains("\"parent\""))
    }

    func testTimestampTiesFallBackToSortOrderThenID() throws {
        let first = text("first", .user, at: 5)
        let second = text("second", .assistant, at: 5)
        var rows = try [first, second].map { try MessageRowCodec.row(for: $0, parentID: nil) }
        rows[0].sortOrder = 0
        rows[1].sortOrder = 1

        XCTAssertEqual(MessageRowCodec.messages(from: rows.reversed()).map(\.text), ["first", "second"])
    }

    func testCorruptPayloadFallsBackToStoredText() throws {
        var row = try MessageRowCodec.row(for: text("readable", .assistant, at: 1), parentID: nil)
        row.payload = Data("not json".utf8)

        let restored = try XCTUnwrap(MessageRowCodec.messages(from: [row]).first)

        XCTAssertEqual(restored.uuid, row.id)
        XCTAssertEqual(restored.text, "readable")
        XCTAssertEqual(restored.role, .assistant)
    }

    func testOrphansAndCyclesStayVisibleAtTheTopLevel() throws {
        let orphan = try MessageRowCodec.row(for: text("orphan", .assistant, at: 1), parentID: UUID())
        let a = Message.agentEvent(type: .started, agentName: "A", details: "a")
        let b = Message.agentEvent(type: .started, agentName: "B", details: "b")
        var rowA = try MessageRowCodec.row(for: a, parentID: b.uuid)
        var rowB = try MessageRowCodec.row(for: b, parentID: a.uuid)
        rowA.createdAt = Date(timeIntervalSinceReferenceDate: 2)
        rowB.createdAt = Date(timeIntervalSinceReferenceDate: 3)

        let restored = MessageRowCodec.messages(from: [orphan, rowA, rowB])

        XCTAssertEqual(Set(restored.map(\.uuid)), [orphan.id, a.uuid, b.uuid])
    }
}
