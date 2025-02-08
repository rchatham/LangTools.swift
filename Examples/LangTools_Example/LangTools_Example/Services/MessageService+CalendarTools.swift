//
//  MessageService+CalendarTools.swift
//  LangTools_Example
//
//  Created by Reid Chatham on 2/8/25.
//

import Foundation
import EventKit
import OpenAI
import LangTools

extension MessageService {
    var calendarTools: [OpenAI.Tool] {
        let calendarStore = CalendarService()

        return [
            .function(.init(
                name: "check_calendar_permission",
                description: "Check if the app has permission to access the calendar",
                parameters: .init(),
                callback: { _ in
                    let status = await calendarStore.checkAuthorization()
                    return "Calendar permission status: \(status.description)"
                })),

            .function(.init(
                name: "request_calendar_access",
                description: "Request access to the calendar",
                parameters: .init(),
                callback: { _ in
                    do {
                        let granted = try await calendarStore.requestAccess()
                        return granted ? "Calendar access granted" : "Calendar access denied"
                    } catch {
                        return "Failed to get calendar access: \(error.localizedDescription)"
                    }
                })),

            .function(.init(
                name: "create_calendar_event",
                description: "Create a new calendar event",
                parameters: .init(
                    properties: [
                        "title": .init(
                            type: "string",
                            description: "Event title"
                        ),
                        "start_date": .init(
                            type: "string",
                            description: "Start date in ISO 8601 format (e.g., 2025-02-08T14:00:00Z)"
                        ),
                        "end_date": .init(
                            type: "string",
                            description: "End date in ISO 8601 format (e.g., 2025-02-08T15:00:00Z)"
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
                        let event = try await calendarStore.createEvent(
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
                })),

            .function(.init(
                name: "get_upcoming_events",
                description: "Get upcoming calendar events",
                parameters: .init(
                    properties: [
                        "limit": .init(
                            type: "integer",
                            description: "Maximum number of events to return (default: 5)"
                        )
                    ],
                    required: []
                ),
                callback: { args in
                    let limit = (args["limit"] as? Int) ?? 5

                    do {
                        let events = try await calendarStore.upcomingEvents(limit: limit)
                        if events.isEmpty {
                            return "No upcoming events found"
                        }
                        return "Upcoming events:\n\n" + events.map { $0.formattedDetails }.joined(separator: "\n\n")
                    } catch {
                        return "Failed to fetch upcoming events: \(error.localizedDescription)"
                    }
                })),

            .function(.init(
                name: "search_calendar_events",
                description: "Search for calendar events",
                parameters: .init(
                    properties: [
                        "query": .init(
                            type: "string",
                            description: "Search query to find events"
                        ),
                        "start_date": .init(
                            type: "string",
                            description: "Optional start date in ISO 8601 format"
                        ),
                        "end_date": .init(
                            type: "string",
                            description: "Optional end date in ISO 8601 format"
                        )
                    ],
                    required: ["query"]
                ),
                callback: { args in
                    guard let query = args["query"] as? String else {
                        return "Missing search query"
                    }

                    let startDate = (args["start_date"] as? String)?.iso8601Date
                    let endDate = (args["end_date"] as? String)?.iso8601Date

                    do {
                        let events = try await calendarStore.searchEvents(
                            matching: query,
                            from: startDate,
                            to: endDate
                        )
                        if events.isEmpty {
                            return "No events found matching '\(query)'"
                        }
                        return "Found events:\n\n" + events.map { $0.formattedDetails }.joined(separator: "\n\n")
                    } catch {
                        return "Failed to search events: \(error.localizedDescription)"
                    }
                }))
        ]
    }
}
