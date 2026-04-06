//
//  CalendarAgentParser.swift
//  LangTools_Example
//

import Foundation
import Chat
import ExampleAgents

// MARK: - Calendar agent result parser

/// Returns a closure suitable for `MessageService.agentResultParser` that handles
/// the `calendarAgent` structured output.
///
/// When `calendarAgent` completes, its result is a JSON string conforming to
/// `CalendarAgentResponse`. This parser decodes it and returns a
/// `Message.contentCards` with `cardType == "calendarEvent"` so the view layer
/// can render `CalendarEventCardListView`.
///
/// Any other agent name returns `nil`, passing control back to the default
/// completion-event rendering in `MessageService`.
func makeAgentResultParser() -> (_ result: String, _ agentName: String) -> Message? {
    return { result, agentName in
        switch agentName {
        case "calendarAgent":
            return parseCalendarAgentResult(result)
        default:
            return nil
        }
    }
}

// MARK: - Private helpers

private func parseCalendarAgentResult(_ result: String) -> Message? {
    guard let data = result.data(using: .utf8),
          let response = try? JSONDecoder().decode(CalendarAgentResponse.self, from: data)
    else { return nil }

    guard let eventsData = try? JSONEncoder().encode(response.events),
          let eventsJSON = String(data: eventsData, encoding: .utf8)
    else { return nil }

    let count = response.events.count
    let summary = response.message ?? (count == 0
        ? "No events found"
        : "Found \(count) event\(count == 1 ? "" : "s")")

    let content = ContentCardsContent(
        cardType: "calendarEvent",
        message: summary,
        cardsJSON: eventsJSON,
        cardCount: count
    )
    return Message.contentCards(content)
}
