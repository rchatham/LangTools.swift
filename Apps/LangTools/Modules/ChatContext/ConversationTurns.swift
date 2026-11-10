//
//  ConversationTurns.swift
//  ChatContext
//

import Foundation
import Chat

/// A request history split into turns, with the places it may be cut.
///
/// A turn is a user message and everything after it up to the next user
/// message; messages before the first user message form a leading turn. A
/// tool call and its result live in the same assistant `Message`, so cutting
/// between turns never separates them. A cut is only allowed where:
///
/// - every turn before it is finished: not another send's in-flight prompt
///   and without pending tool calls;
/// - no message after it answers (`responseToMessageID`) a message before it,
///   which happens when sends interleave;
/// - at least the last turn, the current prompt, stays after it.
struct ConversationTurns {
    struct Turn: Equatable {
        /// Indices into `messages`.
        var range: Range<Int>
        /// False while the turn may still change.
        var isFinished: Bool
    }

    let messages: [Message]
    let turns: [Turn]
    /// Message indices where the history may be cut, ascending. Cutting at
    /// `i` folds `messages[..<i]` into the summary.
    let cutIndices: [Int]

    init(messages: [Message], inFlightMessageIDs: Set<UUID> = []) {
        self.messages = messages

        var starts: [Int] = []
        for (index, message) in messages.enumerated() where index == 0 || message.isUser {
            starts.append(index)
        }
        var turns: [Turn] = []
        for (position, start) in starts.enumerated() {
            let end = position + 1 < starts.count ? starts[position + 1] : messages.count
            let members = messages[start..<end]
            let isFinished = !members.contains { message in
                inFlightMessageIDs.contains(message.uuid)
                    || message.toolCalls.contains { $0.status == .pending }
            }
            turns.append(Turn(range: start..<end, isFinished: isFinished))
        }
        self.turns = turns

        // The smallest index any message at or after `i` answers. Answers to
        // messages outside this history (already summarized) do not matter.
        let indexByID = Dictionary(messages.enumerated().map { ($1.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        var earliestAnsweredFrom = Array(repeating: Int.max, count: messages.count + 1)
        for index in stride(from: messages.count - 1, through: 0, by: -1) {
            let answered = messages[index].responseToMessageID.flatMap { indexByID[$0] } ?? Int.max
            earliestAnsweredFrom[index] = min(answered, earliestAnsweredFrom[index + 1])
        }

        var cuts: [Int] = []
        // Turn 0 can never be cut before (nothing would be summarized) and the
        // last turn is the current prompt, so cuts fall at turns 1..<count.
        for position in turns.indices.dropFirst() {
            guard turns[position - 1].isFinished else { break }
            let index = turns[position].range.lowerBound
            if earliestAnsweredFrom[index] >= index { cuts.append(index) }
        }
        self.cutIndices = cuts
    }

    /// How many turns stay word for word after cutting at `index`.
    func turnsKept(cuttingAt index: Int) -> Int {
        turns.filter { $0.range.lowerBound >= index }.count
    }
}
