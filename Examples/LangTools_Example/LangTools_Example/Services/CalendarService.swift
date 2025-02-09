//
//  CalendarService.swift
//  LangTools_Example
//
//  Created by Reid Chatham on 2/8/25.
//

import EventKit
import Foundation

/// Errors that can occur during calendar operations
public enum CalendarError: Error {
    case accessDenied
    case eventNotFound
    case invalidDateRange
    case saveFailed(Error)
    case deleteFailed(Error)
    case fetchFailed(Error)
    case unknown(Error)
}

/// A wrapper around EKEventStore to manage calendar operations
public actor CalendarService {
    private let store: EKEventStore

    public init() {
        self.store = EKEventStore()
    }

    // MARK: - Authorization

    /// Check if the app has calendar access
    /// - Returns: Current authorization status
    public func checkAuthorization() -> EKAuthorizationStatus {
        return EKEventStore.authorizationStatus(for: .event)
    }

    /// Request calendar access
    /// - Returns: True if access was granted, false otherwise
    public func requestAccess() async throws -> Bool {
        if #available(iOS 17.0, macOS 14.0, *) {
            return try await store.requestFullAccessToEvents()
        } else {
            return try await store.requestAccess(to: .event)
        }
    }

    // MARK: - Calendar Operations

    /// Get all available calendars
    /// - Returns: Array of available calendars
    public func getCalendars() -> [EKCalendar] {
        return store.calendars(for: .event)
    }

    /// Get the default calendar
    /// - Returns: Default calendar for new events
    public func getDefaultCalendar() -> EKCalendar? {
        return store.defaultCalendarForNewEvents
    }

    // MARK: - Event Operations

    /// Create a new event
    /// - Parameters:
    ///   - title: Event title
    ///   - startDate: Event start date
    ///   - endDate: Event end date
    ///   - calendar: Calendar to add event to (optional, uses default if nil)
    ///   - location: Event location (optional)
    ///   - notes: Event notes (optional)
    ///   - url: Event URL (optional)
    ///   - isAllDay: Whether the event is all-day
    /// - Returns: Created event
    public func createEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        calendar: EKCalendar? = nil,
        location: String? = nil,
        notes: String? = nil,
        url: URL? = nil,
        isAllDay: Bool = false
    ) throws -> EKEvent {
        guard startDate < endDate else {
            throw CalendarError.invalidDateRange
        }

        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        event.calendar = calendar ?? store.defaultCalendarForNewEvents
        event.location = location
        event.notes = notes
        event.url = url
        event.isAllDay = isAllDay

        do {
            try store.save(event, span: .thisEvent)
            return event
        } catch {
            throw CalendarError.saveFailed(error)
        }
    }

    /// Update an existing event
    /// - Parameters:
    ///   - event: Event to update
    ///   - title: New title (optional)
    ///   - startDate: New start date (optional)
    ///   - endDate: New end date (optional)
    ///   - location: New location (optional)
    ///   - notes: New notes (optional)
    ///   - url: New URL (optional)
    ///   - isAllDay: New all-day status (optional)
    /// - Returns: Updated event
    public func updateEvent(
        event: EKEvent,
        title: String? = nil,
        startDate: Date? = nil,
        endDate: Date? = nil,
        location: String? = nil,
        notes: String? = nil,
        url: URL? = nil,
        isAllDay: Bool? = nil
    ) throws -> EKEvent {
        if let startDate = startDate {
            event.startDate = startDate
        }

        if let endDate = endDate {
            guard event.startDate < endDate else {
                throw CalendarError.invalidDateRange
            }
            event.endDate = endDate
        }

        if let title = title {
            event.title = title
        }

        if let location = location {
            event.location = location
        }

        if let notes = notes {
            event.notes = notes
        }

        if let url = url {
            event.url = url
        }

        if let isAllDay = isAllDay {
            event.isAllDay = isAllDay
        }

        do {
            try store.save(event, span: .thisEvent)
            return event
        } catch {
            throw CalendarError.saveFailed(error)
        }
    }

    /// Delete an event
    /// - Parameter event: Event to delete
    public func deleteEvent(_ event: EKEvent) throws {
        do {
            try store.remove(event, span: .thisEvent)
        } catch {
            throw CalendarError.deleteFailed(error)
        }
    }

    /// Fetch events between two dates
    /// - Parameters:
    ///   - startDate: Start date of range
    ///   - endDate: End date of range
    ///   - calendars: Specific calendars to search (optional, searches all if nil)
    /// - Returns: Array of events in the date range
    public func fetchEvents(
        from startDate: Date,
        to endDate: Date,
        in calendars: [EKCalendar]? = nil
    ) throws -> [EKEvent] {
        guard startDate < endDate else {
            throw CalendarError.invalidDateRange
        }

        let predicate = store.predicateForEvents(
            withStart: startDate,
            end: endDate,
            calendars: calendars
        )

//        do {
            return store.events(matching: predicate)
//        } catch {
//            throw CalendarError.fetchFailed(error)
//        }
    }

    /// Search for events matching a query string
    /// - Parameters:
    ///   - query: Search query
    ///   - startDate: Start date of search range (optional)
    ///   - endDate: End date of search range (optional)
    ///   - calendars: Specific calendars to search (optional)
    /// - Returns: Array of matching events
    public func searchEvents(
        matching query: String,
        from startDate: Date? = nil,
        to endDate: Date? = nil,
        in calendars: [EKCalendar]? = nil
    ) throws -> [EKEvent] {
        let events: [EKEvent]

        if let startDate = startDate, let endDate = endDate {
            events = try fetchEvents(from: startDate, to: endDate, in: calendars)
        } else {
            // If no date range specified, search next 365 days
            let now = Date()
            let oneYear = Calendar.current.date(byAdding: .year, value: 1, to: now)!
            events = try fetchEvents(from: now, to: oneYear, in: calendars)
        }

        // Filter events based on query
        let lowercaseQuery = query.lowercased()
        return events.filter { event in
            let titleMatch = event.title?.lowercased().contains(lowercaseQuery) ?? false
            let locationMatch = event.location?.lowercased().contains(lowercaseQuery) ?? false
            let notesMatch = event.notes?.lowercased().contains(lowercaseQuery) ?? false

            return titleMatch || locationMatch || notesMatch
        }
    }

    /// Get upcoming events
    /// - Parameters:
    ///   - limit: Maximum number of events to return
    ///   - calendars: Specific calendars to search (optional)
    /// - Returns: Array of upcoming events
    public func upcomingEvents(
        limit: Int = 10,
        in calendars: [EKCalendar]? = nil
    ) throws -> [EKEvent] {
        let now = Date()
        let oneYear = Calendar.current.date(byAdding: .year, value: 1, to: now)!

        let events = try fetchEvents(from: now, to: oneYear, in: calendars)
        return Array(events.prefix(limit))
    }
}

// MARK: - Event Formatting Extensions

extension EKEvent {
    /// Format event details as a human-readable string
    public var formattedDetails: String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        var details = """
            Title: \(title ?? "No Title")
            Start: \(dateFormatter.string(from: startDate))
            End: \(dateFormatter.string(from: endDate))
            """

        if let location = location {
            details += "\nLocation: \(location)"
        }

        if let notes = notes {
            details += "\nNotes: \(notes)"
        }

        if let url = url {
            details += "\nURL: \(url.absoluteString)"
        }

        if isAllDay {
            details += "\nAll Day Event"
        }

        details += "\nEvent Identifier: \(eventIdentifier)"

        return details
    }
}

// MARK: - Convenience Extensions

extension Date {
    /// Format date as ISO8601 string
    var iso8601String: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: self)
    }
}

extension String {
    /// Parse ISO8601 string to Date
    var iso8601Date: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: self)
    }
}
