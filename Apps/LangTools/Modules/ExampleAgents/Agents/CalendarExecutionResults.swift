//
//  CalendarExecutionResults.swift
//  ExampleAgents
//

import Agents
import EventKit
import Foundation
import LangTools

/// Private wire envelope emitted by native Calendar callbacks, never by a model.
/// The final agent response remains the public CalendarAgentResponse shape.
struct CalendarToolResult: Codable {
    let version: Int
    let events: [CalendarEventData]
    let replacedEvent: CalendarEventData?
    let deletedEvent: CalendarEventData?

    init(events: [CalendarEventData], replacedEvent: CalendarEventData? = nil,
         deletedEvent: CalendarEventData? = nil) {
        self.version = 1
        self.events = events
        self.replacedEvent = replacedEvent
        self.deletedEvent = deletedEvent
    }

    func encoded() throws -> String {
        String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }
}

extension CalendarEventData {
    /// Copy native values before a mutable EKEvent is updated/deleted. No natural
    /// language date parsing, invented end times, or model-generated fields.
    init(event: EKEvent) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        self.init(
            title: event.title ?? "Untitled event",
            startDate: formatter.string(from: event.startDate),
            endDate: formatter.string(from: event.endDate),
            location: event.location,
            notes: event.notes,
            isAllDay: event.isAllDay,
            calendarName: event.calendar?.title,
            eventIdentifier: event.eventIdentifier
        )
    }
}

/// Internal, value-only query seam. Tests exercise the real read-tool callbacks
/// without creating an event store or requesting Calendar permissions.
struct CalendarEventQueries {
    var fetch: (Date, Date) async throws -> [CalendarEventData]
    var upcoming: (Int) async throws -> [CalendarEventData]
    var search: (String) async throws -> [CalendarEventData]

    static var live: CalendarEventQueries {
        CalendarEventQueries(
            fetch: { start, end in
                try await CalendarService().fetchEvents(from: start, to: end).map { CalendarEventData(event: $0) }
            },
            upcoming: { limit in
                try await CalendarService().upcomingEvents(limit: limit).map { CalendarEventData(event: $0) }
            },
            search: { query in
                try await CalendarService().searchEvents(matching: query).map { CalendarEventData(event: $0) }
            }
        )
    }
}

/// One collector per CalendarAgent.execute call. Nested delegates report native
/// callback output through that call's event handler. Never stored on the agent,
/// in UserDefaults, or in a global registry; concurrent invocations cannot mix.
final class CalendarExecutionResults: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [CalendarEventData] = []
    private var receivedToolResult = false
    private var failed = false
    private var deletedCount = 0

    func observe(_ event: AgentEvent) {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case .toolCompleted(let agent, let result)
            where agent == "calendarReadAgent" || agent == "calendarWriteAgent":
            guard let result,
                  let payload = try? JSONDecoder().decode(CalendarToolResult.self, from: Data(result.utf8)),
                  payload.version == 1 else {
                failed = true
                return
            }
            receivedToolResult = true
            if let previous = payload.replacedEvent { remove(previous) }
            if let deleted = payload.deletedEvent {
                remove(deleted)
                deletedCount += 1
            }
            for item in payload.events {
                if let index = events.firstIndex(where: { sameOccurrence($0, item) }) {
                    events[index] = item
                } else {
                    events.append(item)
                }
            }
        case .error(let agent, _) where isCalendarDelegate(agent):
            failed = true
        case .completed(let agent, _, let isError) where isError && isCalendarDelegate(agent):
            failed = true
        default:
            break
        }
    }

    func finalize(_ modelResult: String) throws -> String {
        lock.lock()
        let snapshot = events
        let hasNativeResult = receivedToolResult
        let hasFailure = failed
        let deletions = deletedCount
        lock.unlock()

        guard !hasFailure else {
            throw AgentError("A calendar operation failed. Some earlier operations may have completed; review the tool results before retrying.")
        }
        let response: CalendarAgentResponse
        if hasNativeResult {
            // The model may summarize incorrectly, omit fields, or return prose.
            // Native tool snapshots are authoritative even when model JSON decodes.
            let message: String
            if snapshot.isEmpty {
                message = deletions > 0 ? "Calendar event deletion completed." : "No calendar events found."
            } else {
                message = "Retrieved \(snapshot.count) calendar event\(snapshot.count == 1 ? "" : "s")."
            }
            response = CalendarAgentResponse(events: snapshot, message: message)
            #if DEBUG
            print("[RichResult][calendar-finalize] source=native count=\(snapshot.count) modelShape=\(RichResultDiagnostics.ResultShape.classify(modelResult).rawValue)")
            #endif
        } else {
            // Preserve valid schema-only responses (including existing clients and
            // fixtures), but do not report malformed/prose output as a success.
            do {
                _ = try CalendarAgentResponse(jsonString: modelResult)
                return modelResult // Keep valid legacy raw disclosure/replay byte-for-byte.
            } catch {
                throw AgentError("Calendar returned an invalid structured response and no native event results were available.")
            }
        }
        return String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
    }

    private func isCalendarDelegate(_ name: String) -> Bool {
        ["calendarReadAgent", "calendarWriteAgent", "calendarPermissionAgent"].contains(name)
    }

    private func sameOccurrence(_ lhs: CalendarEventData, _ rhs: CalendarEventData) -> Bool {
        if let identifier = lhs.eventIdentifier, !identifier.isEmpty,
           identifier == rhs.eventIdentifier {
            return lhs.startDate == rhs.startDate
        }
        return lhs == rhs
    }

    private func remove(_ event: CalendarEventData) {
        events.removeAll { sameOccurrence($0, event) }
    }
}
