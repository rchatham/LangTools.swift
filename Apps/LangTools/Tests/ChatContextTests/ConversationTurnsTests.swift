import ChatUI
import Foundation
import XCTest
@testable import Chat
@testable import ChatContext

@MainActor
final class ConversationTurnsTests: XCTestCase {
    private func user(_ text: String) -> Message { Message(text: text, role: .user) }
    private func reply(_ text: String, to prompt: Message? = nil) -> Message {
        let message = Message(text: text, role: .assistant)
        message.responseToMessageID = prompt?.uuid
        return message
    }

    func testTurnsStartAtUserMessagesWithALeadingTurnForEarlierMessages() {
        let greeting = reply("Hi, I'm your assistant")
        let q1 = user("q1"), q2 = user("q2"), q3 = user("q3")
        let messages = [greeting, q1, reply("a1", to: q1), q2, reply("a2", to: q2), q3]

        let turns = ConversationTurns(messages: messages)

        XCTAssertEqual(turns.turns.map(\.range), [0..<1, 1..<3, 3..<5, 5..<6])
        XCTAssertEqual(turns.cutIndices, [1, 3, 5], "Cuts fall before user messages; the current prompt always stays")
        XCTAssertEqual(turns.turnsKept(cuttingAt: 3), 2)
    }

    func testAToolCallAndItsResultAreNeverSeparated() {
        let q1 = user("look it up")
        let call = Message(
            role: .assistant,
            contentType: .string(""),
            toolCalls: [ChatToolCall(id: "c1", name: "search", arguments: "{}", status: .success, result: "found")]
        )
        call.responseToMessageID = q1.uuid
        let answer = reply("here it is", to: q1)
        let messages = [q1, call, answer, user("thanks")]

        XCTAssertEqual(ConversationTurns(messages: messages).cutIndices, [3],
                       "The tool call message and the reply that uses its result stay in one turn")
    }

    func testUnfinishedTurnsAndEverythingAfterThemCannotBeCovered() {
        let q1 = user("q1"), q2 = user("q2 still streaming")
        let messages = [q1, reply("a1", to: q1), q2, reply("partial", to: q2), user("q3"), reply("a3"), user("now")]

        let inFlight = ConversationTurns(messages: messages, inFlightMessageIDs: [q2.uuid])
        XCTAssertEqual(inFlight.cutIndices, [2], "Only the turn before the in-flight prompt can be folded")

        let pending = Message(role: .assistant, contentType: .null, toolCalls: [ChatToolCall(id: "p", name: "slow", status: .pending)])
        let withPending = ConversationTurns(messages: [q1, pending, user("q2"), reply("a2"), user("now")])
        XCTAssertEqual(withPending.cutIndices, [], "A turn with a pending tool call is unfinished")
    }

    func testInterleavedRepliesKeepTheirPromptInTheSameSide() {
        let q1 = user("slow question"), q2 = user("quick question")
        let messages = [q1, q2, reply("quick answer", to: q2), reply("slow answer", to: q1), user("next")]

        XCTAssertEqual(ConversationTurns(messages: messages).cutIndices, [4],
                       "Cutting before q2 would separate the slow answer from q1")
    }

    func testAnswersToMessagesOutsideTheHistoryDoNotBlockCuts() {
        let orphan = reply("answers an already summarized prompt")
        orphan.responseToMessageID = UUID()
        let q1 = user("q1")
        let messages = [orphan, q1, reply("a1", to: q1), user("now")]

        XCTAssertEqual(ConversationTurns(messages: messages).cutIndices, [1, 3])
    }

    func testEmptyAndSingleTurnHistoriesHaveNoCuts() {
        XCTAssertEqual(ConversationTurns(messages: []).cutIndices, [])
        XCTAssertEqual(ConversationTurns(messages: [user("only")]).cutIndices, [])
    }
}
