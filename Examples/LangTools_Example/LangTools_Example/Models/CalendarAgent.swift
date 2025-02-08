//
//  CalendarAgent.swift
//  LangTools_Example
//
//  Created by Reid Chatham on 2/8/25.
//

import EventKit
import LangTools
import Agents
import Anthropic

// MARK: - Calendar Permission Agent
struct CalendarPermissionAgent<LangTool: LangTools>: Agent {
    let langTool: LangTool
    let model: LangTool.Model

    init(langTool: LangTool, model: LangTool.Model) {
        self.langTool = langTool
        self.model = model
    }

    let name = "calendarPermissionAgent"
    let description = "Agent responsible for managing calendar access permissions"
    let instructions = """
        You are responsible for checking and requesting calendar permissions.
        Only request permissions when explicitly needed and inform the user about the status.
        """

    var delegateAgents: [any Agent] = []

    var tools: [Tool]? = [
        Tool(
            name: "check_calendar_permission",
            description: "Check current calendar access permission status",
            tool_schema: .init(),
            callback: { _ in
                let status = EKEventStore.authorizationStatus(for: .event)
                return "Calendar permission status: \(status.description)"
            }
        ),
        Tool(
            name: "request_calendar_permission",
            description: "Request calendar access permission",
            tool_schema: .init(),
            callback: { _ in
                if #available(iOS 17.0, macOS 14.0, *) {
                    do {
                        try await EKEventStore().requestFullAccessToEvents()
                        return "Calendar access granted"
                    } catch {
                        return "Failed to get calendar access: \(error.localizedDescription)"
                    }
                } else {
                    // Handle older versions
                    return "Calendar access request not supported on this OS version"
                }
            }
        )
    ]
}
// MARK: - Calendar Read Agent
struct CalendarReadAgent<LangTool: LangTools>: Agent {
    let langTool: LangTool
    let model: LangTool.Model

    init(langTool: LangTool, model: LangTool.Model) {
        self.langTool = langTool
        self.model = model
    }

    let name = "calendarReadAgent"
    let description = "Agent responsible for reading calendar events"
    let instructions = """
        You are responsible for reading and querying calendar events.
        Format dates consistently and provide clear, concise event information.
        """

    var delegateAgents: [any Agent] = []

    var tools: [Tool]? = [
        Tool(
            name: "get_events",
            description: "Get calendar events for a specific time range",
            tool_schema: .init(
                properties: [
                    "start_date": .init(
                        type: "string",
                        description: "Start date in ISO 8601 format"
                    ),
                    "end_date": .init(
                        type: "string",
                        description: "End date in ISO 8601 format"
                    )
                ],
                required: ["start_date", "end_date"]
            ),
            callback: { args in
                guard let startDate = (args["start_date"] as? String)?.iso8601Date,
                      let endDate = (args["end_date"] as? String)?.iso8601Date else {
                    return "Invalid date format"
                }

                do {
                    let events = try CalendarService().fetchEvents(from: startDate, to: endDate)
                    return events.isEmpty ? "No events returned from calendar." : events.map { $0.formattedDetails }.joined(separator: "\n\n")
                } catch {
                    return "Failed to fetch events: \(error.localizedDescription)"
                }
            }
        ),
        Tool(
            name: "get_upcoming_events",
            description: "Get upcoming calendar events",
            tool_schema: .init(
                properties: [
                    "limit": .init(
                        type: "integer",
                        description: "Maximum number of events to return"
                    )
                ],
                required: []
            ),
            callback: { args in
                let limit = (args["limit"] as? Int) ?? 10

                do {
                    let events = try CalendarService().upcomingEvents(limit: limit)
                    return events.map { $0.formattedDetails }.joined(separator: "\n\n")
                } catch {
                    return "Failed to fetch upcoming events: \(error.localizedDescription)"
                }
            }
        ),
        Tool(
            name: "search_events",
            description: "Search for calendar events",
            tool_schema: .init(
                properties: [
                    "query": .init(
                        type: "string",
                        description: "Search query"
                    )
                ],
                required: ["query"]
            ),
            callback: { args in
                guard let query = args["query"] as? String else {
                    return "Invalid query"
                }

                do {
                    let events = try CalendarService().searchEvents(matching: query)
                    return events.map { $0.formattedDetails }.joined(separator: "\n\n")
                } catch {
                    return "Failed to search events: \(error.localizedDescription)"
                }
            }
        )
    ]
}

// MARK: - Calendar Write Agent
struct CalendarWriteAgent<LangTool: LangTools>: Agent {
    let langTool: LangTool
    let model: LangTool.Model

    init(langTool: LangTool, model: LangTool.Model) {
        self.langTool = langTool
        self.model = model
    }

    let name = "calendarWriteAgent"
    let description = "Agent responsible for creating and modifying calendar events"
    let instructions = """
        You are responsible for creating and modifying calendar events.
        Ensure all required information is provided and validate dates before creating events.
        Always confirm event details with users before taking action.
        """

    var delegateAgents: [any Agent] = []

    var tools: [Tool]? = [
        Tool(
            name: "create_event",
            description: "Create a new calendar event",
            tool_schema: .init(
                properties: [
                    "title": .init(
                        type: "string",
                        description: "Event title"
                    ),
                    "start_date": .init(
                        type: "string",
                        description: "Start date in ISO 8601 format"
                    ),
                    "end_date": .init(
                        type: "string",
                        description: "End date in ISO 8601 format"
                    ),
                    "location": .init(
                        type: "string",
                        description: "Event location (optional)"
                    ),
                    "notes": .init(
                        type: "string",
                        description: "Event notes (optional)"
                    ),
                    "is_all_day": .init(
                        type: "boolean",
                        description: "Whether this is an all-day event (optional)"
                    )
                ],
                required: ["title", "start_date", "end_date"]
            ),
            callback: { args in
                guard let title = args["title"] as? String,
                      let startDate = (args["start_date"] as? String)?.iso8601Date,
                      let endDate = (args["end_date"] as? String)?.iso8601Date else {
                    return "Invalid event information"
                }

                let location = args["location"] as? String
                let notes = args["notes"] as? String
                let isAllDay = args["is_all_day"] as? Bool ?? false

                do {
                    let event = try CalendarService().createEvent(
                        title: title,
                        startDate: startDate,
                        endDate: endDate,
                        location: location,
                        notes: notes,
                        isAllDay: isAllDay
                    )
                    return "Event created successfully:\n\(event.formattedDetails)"
                } catch {
                    return "Failed to create event: \(error.localizedDescription)"
                }
            }
        ),
        Tool(
            name: "delete_event",
            description: "Delete an existing calendar event",
            tool_schema: .init(
                properties: [
                    "event_identifier": .init(
                        type: "string",
                        description: "The unique identifier of the event to delete"
                    )
                ],
                required: ["event_identifier"]
            ),
            callback: { args in
                guard let eventIdentifier = args["event_identifier"] as? String else {
                    return "Missing event identifier"
                }

                // First find the event in the next year
                let now = Date()
                let oneYear = Calendar.current.date(byAdding: .year, value: 1, to: now)!

                do {
                    let calendarStore = CalendarService()
                    let events = try calendarStore.fetchEvents(from: now, to: oneYear)
                    guard let event = events.first(where: { $0.eventIdentifier == eventIdentifier }) else {
                        return "Event not found"
                    }

                    try calendarStore.deleteEvent(event)
                    return "Event deleted successfully"
                } catch {
                    return "Failed to delete event: \(error.localizedDescription)"
                }
            }
        ),
        Tool(
            name: "update_event",
            description: "Update an existing calendar event",
            tool_schema: .init(
                properties: [
                    "event_identifier": .init(
                        type: "string",
                        description: "The unique identifier of the event to update"
                    ),
                    "title": .init(
                        type: "string",
                        description: "New event title (optional)"
                    ),
                    "start_date": .init(
                        type: "string",
                        description: "New start date in ISO 8601 format (optional)"
                    ),
                    "end_date": .init(
                        type: "string",
                        description: "New end date in ISO 8601 format (optional)"
                    ),
                    "location": .init(
                        type: "string",
                        description: "New event location (optional)"
                    ),
                    "notes": .init(
                        type: "string",
                        description: "New event notes (optional)"
                    ),
                    "is_all_day": .init(
                        type: "boolean",
                        description: "Whether this is an all-day event (optional)"
                    )
                ],
                required: ["event_identifier"]
            ),
            callback: { args in
                guard let eventIdentifier = args["event_identifier"] as? String else {
                    return "Missing event identifier"
                }

                do {
                    let calendarStore = CalendarService()
                    let now = Date()
                    let oneYear = Calendar.current.date(byAdding: .year, value: 1, to: now)!
                    let events = try calendarStore.fetchEvents(from: now, to: oneYear)

                    guard let event = events.first(where: { $0.eventIdentifier == eventIdentifier }) else {
                        return "Event not found"
                    }

                    let title = args["title"] as? String
                    let startDate = (args["start_date"] as? String)?.iso8601Date
                    let endDate = (args["end_date"] as? String)?.iso8601Date
                    let location = args["location"] as? String
                    let notes = args["notes"] as? String
                    let isAllDay = args["is_all_day"] as? Bool

                    let updatedEvent = try calendarStore.updateEvent(
                        event: event,
                        title: title,
                        startDate: startDate,
                        endDate: endDate,
                        location: location,
                        notes: notes,
                        isAllDay: isAllDay
                    )

                    return "Event updated successfully:\n\(updatedEvent.formattedDetails)"
                } catch {
                    return "Failed to update event: \(error.localizedDescription)"
                }
            }
        )
    ]
}

// MARK: - Main Calendar Agent
struct CalendarAgent<LangTool: LangTools>: Agent {
    let langTool: LangTool
    let model: LangTool.Model

    init(langTool: LangTool, model: LangTool.Model) {
        self.langTool = langTool
        self.model = model

        delegateAgents = [
            CalendarPermissionAgent(langTool: langTool, model: model),
            CalendarReadAgent(langTool: langTool, model: model),
            CalendarWriteAgent(langTool: langTool, model: model)
        ]
    }

    let name = "calendarAgent"
    let description = "Main calendar agent that manages all calendar operations"
    let instructions = """
        You are a calendar management assistant. Your responsibilities include:
        1. Managing calendar permissions through the permission agent
        2. Reading and searching calendar events through the read agent
        3. Creating, updating, and deleting events through the write agent

        Always verify calendar permissions before performing operations.
        When creating or modifying events, ensure all required information is provided.
        Use delegate agents for specialized tasks and provide clear, concise responses.
        """

    var delegateAgents: [any Agent]

    // Main agent uses delegate agents' tools
    var tools: [Tool]? = nil
}

// MARK: - Helpers
extension String {
    func toDate() -> Date? {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: self)
    }
}

extension EKAuthorizationStatus {
    var description: String {
        switch self {
        case .notDetermined: return "Not Determined"
        case .restricted: return "Restricted"
        case .denied: return "Denied"
        case .authorized: return "Authorized"
        case .fullAccess: return "Full Access"
        case .writeOnly: return "Write Only"
        @unknown default: return "Unknown"
        }
    }
}
