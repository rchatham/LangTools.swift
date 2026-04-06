//
//  CalendarEventCard.swift
//  LangTools_Example
//

import SwiftUI
import Chat
import ExampleAgents
import LangTools

// MARK: - CalendarEventCard

/// A structured calendar event returned by CalendarAgent and rendered as a SwiftUI card.
/// Conforms to `ContentCard` which bridges `StructuredOutput` (AI response schema) with a SwiftUI view.
///
/// `CalendarEventData` (the schema/data type) lives in `ExampleAgents`.
/// This type lives in the app target and adds `ContentCard` conformance + the SwiftUI view.
struct CalendarEventCard: ContentCard {
    let id: String
    let title: String
    let startDate: String      // ISO 8601 — kept as String for Codable simplicity
    let endDate: String
    let location: String?
    let notes: String?
    let isAllDay: Bool
    let calendarName: String?
    let eventIdentifier: String?

    init(from data: CalendarEventData) {
        self.id             = data.id
        self.title          = data.title
        self.startDate      = data.startDate
        self.endDate        = data.endDate
        self.location       = data.location
        self.notes          = data.notes
        self.isAllDay       = data.isAllDay
        self.calendarName   = data.calendarName
        self.eventIdentifier = data.eventIdentifier
    }

    // Memberwise init for direct Codable decode from cardsJSON
    init(
        id: String = UUID().uuidString,
        title: String,
        startDate: String,
        endDate: String,
        location: String? = nil,
        notes: String? = nil,
        isAllDay: Bool = false,
        calendarName: String? = nil,
        eventIdentifier: String? = nil
    ) {
        self.id              = id
        self.title           = title
        self.startDate       = startDate
        self.endDate         = endDate
        self.location        = location
        self.notes           = notes
        self.isAllDay        = isAllDay
        self.calendarName    = calendarName
        self.eventIdentifier = eventIdentifier
    }

    // MARK: - StructuredOutput / JSONSchema

    static var jsonSchema: JSONSchema {
        .object(
            properties: [
                "id":              .string(description: "Unique identifier for the event card"),
                "title":           .string(description: "Event title"),
                "startDate":       .string(description: "Event start date and time in ISO 8601 format"),
                "endDate":         .string(description: "Event end date and time in ISO 8601 format"),
                "location":        .string(description: "Event location (optional)"),
                "notes":           .string(description: "Event notes or description (optional)"),
                "isAllDay":        .boolean(description: "Whether this is an all-day event"),
                "calendarName":    .string(description: "Name of the calendar containing this event (optional)"),
                "eventIdentifier": .string(description: "System event identifier for updates/deletes (optional)")
            ],
            required: ["id", "title", "startDate", "endDate", "isAllDay"],
            additionalProperties: false,
            title: "CalendarEventCard"
        )
    }

    // MARK: - ContentCard / SwiftUI View

    func cardView() -> some View {
        CalendarEventCardView(card: self)
    }
}

// MARK: - CalendarEventCardView

private struct CalendarEventCardView: View {
    let card: CalendarEventCard

    private var parsedStart: Date? { card.startDate.iso8601CardDate }
    private var parsedEnd: Date?   { card.endDate.iso8601CardDate }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header bar with calendar colour accent
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.accentColor)
                    .frame(width: 4)

                VStack(alignment: .leading, spacing: 2) {
                    Text(card.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    if let calendarName = card.calendarName {
                        Text(calendarName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if card.isAllDay {
                    Text("All Day")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.15))
                        .foregroundStyle(Color.accentColor)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider().padding(.horizontal, 14)

            // Date / time rows
            VStack(alignment: .leading, spacing: 6) {
                dateRow(icon: "calendar", label: formattedDate(from: parsedStart))

                if !card.isAllDay {
                    dateRow(icon: "clock", label: timeRange(start: parsedStart, end: parsedEnd))
                }

                if let location = card.location, !location.isEmpty {
                    dateRow(icon: "location", label: location)
                }

                if let notes = card.notes, !notes.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "note.text")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        Text(notes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 2)
    }

    @ViewBuilder
    private func dateRow(icon: String, label: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
    }

    private func formattedDate(from date: Date?) -> String {
        guard let date else { return card.startDate }
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private func timeRange(start: Date?, end: Date?) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let startStr = start.map { formatter.string(from: $0) } ?? "--"
        let endStr   = end.map   { formatter.string(from: $0) } ?? "--"
        return "\(startStr) – \(endStr)"
    }
}

// MARK: - CalendarEventCardListView

/// Renders a list of CalendarEventCards decoded from ContentCardsContent.
struct CalendarEventCardListView: View {
    let content: ContentCardsContent

    private var cards: [CalendarEventCard] {
        (try? content.decodeCards(as: CalendarEventCard.self)) ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let message = content.message, !message.isEmpty {
                Text(message)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)
            }

            ForEach(cards) { card in
                card.cardView()
            }
        }
    }
}

// MARK: - Date parsing helper

private extension String {
    /// Parse ISO 8601 strings that may or may not include time zone info.
    var iso8601CardDate: Date? {
        let full = ISO8601DateFormatter()
        if let d = full.date(from: self) { return d }
        let fallback = DateFormatter()
        fallback.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            fallback.dateFormat = fmt
            if let d = fallback.date(from: self) { return d }
        }
        return nil
    }
}
