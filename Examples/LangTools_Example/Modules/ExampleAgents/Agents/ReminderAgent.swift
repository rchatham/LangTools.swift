//
//  ReminderAgent.swift
//  LangTools_Example
//
//  Created by Reid Chatham on 2/9/25.
//

import SwiftUI
import EventKit
import LangTools
import Agents
import Anthropic

// MARK: - Reminder Permission Agent
struct ReminderPermissionAgent: Agent {
    init() {}

    let name = "reminderPermissionAgent"
    let description = "Agent responsible for managing reminder access permissions"
    let instructions = """
        You are responsible for checking and requesting reminder permissions.
        Only request permissions when explicitly needed and inform the user about the status.
        """

    var delegateAgents: [any Agent] = []

    var tools: [any LangToolsTool]? = [
        Tool(
            name: "check_reminder_permission",
            description: "Check current reminder access permission status",
            tool_schema: .init(),
            callback: { _ in
                let status = EKEventStore.authorizationStatus(for: .reminder)
                return "Reminder permission status: \(status.description)"
            }
        ),
        Tool(
            name: "request_reminder_permission",
            description: "Request reminder access permission",
            tool_schema: .init(),
            callback: { _ in
                if #available(iOS 17.0, macOS 14.0, *) {
                    do {
                        return "Reminder access granted: \(try await EKEventStore().requestFullAccessToReminders())"
                    } catch {
                        throw AgentError("Failed to get reminder access: \(error.localizedDescription)")
                    }
                } else {
                    throw AgentError("Reminder access request not supported on this OS version")
                }
            }
        )
    ]
}

// MARK: - Reminder Read Agent
struct ReminderReadAgent: Agent {
    init() {}

    let name = "reminderReadAgent"
    let description = "Agent responsible for reading reminders"
    let instructions = """
        You are responsible for reading and querying reminders.
        Format dates consistently and provide clear, concise reminder information.
        
        Error: (EKErrorDomain error 29.) - Requires Permissions
        """

    var delegateAgents: [any Agent] = []

    var tools: [any LangToolsTool]? = [
        Tool(
            name: "get_reminders",
            description: "Get reminders for a specific time range",
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
                guard let startDate = (args["start_date"]?.stringValue)?.iso8601Date,
                      let endDate = (args["end_date"]?.stringValue)?.iso8601Date else {
                    throw AgentError("Invalid date format")
                }

                do {
                    let reminders = try await ReminderService().fetchReminders(from: startDate, to: endDate)
                    return reminders.isEmpty ? "Reminders did not return any results." : reminders.isEmpty ? "No reminders found." : reminders.map { $0.formattedDetails }.joined(separator: "\n\n")
                } catch {
                    throw AgentError("Failed to fetch reminders: \(error.localizedDescription)")
                }
            }
        ),
        Tool(
            name: "get_upcoming_reminders",
            description: "Get upcoming reminders",
            tool_schema: .init(
                properties: [
                    "limit": .init(
                        type: "integer",
                        description: "Maximum number of reminders to return"
                    )
                ],
                required: []
            ),
            callback: { args in
                let limit = (args["limit"]?.intValue) ?? 10

                do {
                    let reminders = try await ReminderService().upcomingReminders(limit: limit)
                    return reminders.isEmpty ? "Reminders did not return any results." : reminders.map { $0.formattedDetails }.joined(separator: "\n\n")
                } catch {
                    throw AgentError("Failed to fetch upcoming reminders: \(error.localizedDescription)")
                }
            }
        ),
        Tool(
            name: "search_reminders",
            description: "Search for reminders",
            tool_schema: .init(
                properties: [
                    "query": .init(
                        type: "string",
                        description: "Search query"
                    ),
                    "include_completed": .init(
                        type: "boolean",
                        description: "Whether to include completed reminders"
                    )
                ],
                required: ["query"]
            ),
            callback: { args in
                guard let query = args["query"]?.stringValue else {
                    throw AgentError("Invalid query")
                }

                let includeCompleted = args["include_completed"]?.boolValue ?? false

                do {
                    let reminders = try await ReminderService().searchReminders(matching: query, includeCompleted: includeCompleted)
                    return reminders.isEmpty ? "Reminders did not return any results." : reminders.map { $0.formattedDetails }.joined(separator: "\n\n")
                } catch {
                    throw AgentError("Failed to search reminders: \(error.localizedDescription)")
                }
            }
        ),
        Tool(
            name: "get_list_info",
            description: "Get detailed information about a specific reminder list",
            tool_schema: .init(
                properties: [
                    "name": .init(
                        type: "string",
                        description: "Name of the list to get information about"
                    )
                ],
                required: ["name"]
            ),
            callback: { args in
                guard let name = args["name"]?.stringValue else {
                    throw AgentError("Missing list name")
                }

                let service = ReminderService()
                guard let list = service.getAllLists().first(where: { $0.title == name }) else {
                    throw AgentError("List not found: \(name)")
                }

                do {
                    let info = try await service.getListInfo(list)
                    let colorStr = info.color != nil ? "yes" : "no"

                    return """
                        List Information for '\(info.title)':
                        Total Reminders: \(info.reminderCount)
                        Active Reminders: \(info.activeCount)
                        Completed Reminders: \(info.completedCount)
                        Has Custom Color: \(colorStr)
                        """
                } catch {
                    throw AgentError("Failed to get list information: \(error.localizedDescription)")
                }
            }
        ),

        Tool(
            name: "get_lists_summary",
            description: "Get a summary of all reminder lists",
            tool_schema: .init(),
            callback: { _ in
                let service = ReminderService()
                let lists = service.getAllLists()

                if lists.isEmpty {
                    throw AgentError("No reminder lists found.")
                }

                do {
                    var summary = "Reminder Lists Summary:\n"
                    for list in lists {
                        let info = try await service.getListInfo(list)
                        summary += """
                            
                            \(info.title):
                            - Active Reminders: \(info.activeCount)
                            - Completed: \(info.completedCount)
                            """
                    }
                    return summary
                } catch {
                    throw AgentError("Failed to get lists summary: \(error.localizedDescription)")
                }
            }
        ),

        Tool(
            name: "search_lists",
            description: "Search for reminder lists containing specific text",
            tool_schema: .init(
                properties: [
                    "query": .init(
                        type: "string",
                        description: "Search text to find in list names"
                    )
                ],
                required: ["query"]
            ),
            callback: { args in
                guard let query = args["query"]?.stringValue else {
                    throw AgentError("Missing search query")
                }

                let service = ReminderService()
                let matchingLists = service.getAllLists().filter {
                    $0.title.localizedCaseInsensitiveContains(query)
                }

                if matchingLists.isEmpty {
                    throw AgentError("No lists found matching '\(query)'")
                }

                do {
                    var result = "Found Lists:\n"
                    for list in matchingLists {
                        let info = try await service.getListInfo(list)
                        result += """
                            
                            \(info.title):
                            - Active Reminders: \(info.activeCount)
                            - Completed: \(info.completedCount)
                            """
                    }
                    return result
                } catch {
                    throw AgentError("Failed to get search results: \(error.localizedDescription)")
                }
            }
        ),
        Tool(
            name: "get_list_reminders",
            description: "Get all reminders from a specific list",
            tool_schema: .init(
                properties: [
                    "list_name": .init(
                        type: "string",
                        description: "Name of the list to get reminders from"
                    ),
                    "include_completed": .init(
                        type: "boolean",
                        description: "Whether to include completed reminders (default: true)"
                    ),
                    "sort_by": .init(
                        type: "string",
                        enumValues: ["due_date", "priority", "title"],
                        description: "How to sort the reminders (default: due_date)"
                    )
                ],
                required: ["list_name"]
            ),
            callback: { args in
                guard let listName = args["list_name"]?.stringValue else {
                    return "Missing list name"
                }

                let includeCompleted = args["include_completed"]?.boolValue ?? true
                let sortByString = args["sort_by"]?.stringValue ?? "due_date"

                let sortBy: ReminderService.RemindersSort
                switch sortByString {
                case "priority":
                    sortBy = .priority
                case "title":
                    sortBy = .title
                default:
                    sortBy = .dueDate
                }

                let service = ReminderService()
                guard let list = service.getAllLists().first(where: { $0.title == listName }) else {
                    return "List not found: \(listName)"
                }

                do {
                    let reminders = try await service.fetchRemindersInList(list)
                    let formattedResult = service.formatRemindersInList(
                        reminders,
                        includeCompleted: includeCompleted,
                        sortBy: sortBy
                    )

                    return """
                        Reminders in '\(listName)':
                        
                        \(formattedResult)
                        """
                } catch {
                    return "Failed to fetch reminders: \(error.localizedDescription)"
                }
            }
        )
    ]
}

// MARK: - Reminder Write Agent
struct ReminderWriteAgent: Agent {
    init() {
        delegateAgents = [
            ReminderReadAgent()
        ]
    }

    let name = "reminderWriteAgent"
    let description = "Agent responsible for creating and modifying reminders"
    let instructions = """
        You are responsible for creating and modifying reminders.
        Ensure all required information is provided and validate dates before creating reminders.
        Always confirm reminder details with users before taking action.
        
        Known Possible Errors:
         - (EKErrorDomain error 29.) = Requires Permissions
        """

    var delegateAgents: [any Agent]

    var tools: [any LangToolsTool]? = [
        Tool(
            name: "create_reminder",
            description: "Create a new reminder",
            tool_schema: .init(
                properties: [
                    "title": .init(
                        type: "string",
                        description: "Reminder title"
                    ),
                    "due_date": .init(
                        type: "string",
                        description: "Due date in ISO 8601 format"
                    ),
                    "priority": .init(
                        type: "integer",
                        description: "Priority (0-5, where 0 is none and 5 is highest)"
                    ),
                    "notes": .init(
                        type: "string",
                        description: "Additional notes"
                    ),
                    "list_name": .init(
                        type: "string",
                        description: "Name of the reminder list to add to"
                    )
                ],
                required: ["title"]
            ),
            callback: { args in
                guard let title = args["title"]?.stringValue else {
                    throw AgentError("Missing reminder title")
                }

                let dueDate = (args["due_date"]?.stringValue)?.iso8601Date
                let priority = args["priority"]?.intValue ?? 0
                let notes = args["notes"]?.stringValue
                let listName = args["list_name"]?.stringValue

                do {
                    let reminder = try ReminderService().createReminder(
                        title: title,
                        dueDate: dueDate,
                        priority: priority,
                        notes: notes,
                        listName: listName
                    )
                    return "Reminder created successfully:\n\(reminder.formattedDetails)"
                } catch {
                    throw AgentError("Failed to create reminder: \(error.localizedDescription)")
                }
            }
        ),
        Tool(
            name: "complete_reminder",
            description: "Mark a reminder as completed",
            tool_schema: .init(
                properties: [
                    "reminder_identifier": .init(
                        type: "string",
                        description: "The unique identifier of the reminder"
                    )
                ],
                required: ["reminder_identifier"]
            ),
            callback: { args in
                guard let reminderIdentifier = args["reminder_identifier"]?.stringValue else {
                    throw AgentError("Missing reminder identifier")
                }

                do {
                    let reminderService = ReminderService()
                    let reminder = try await reminderService.findReminder(identifier: reminderIdentifier)
                    try reminderService.completeReminder(reminder)
                    return "Reminder marked as completed"
                } catch {
                    throw AgentError("Failed to complete reminder: \(error.localizedDescription)")
                }
            }
        ),
        Tool(
            name: "update_reminder",
            description: "Update an existing reminder",
            tool_schema: .init(
                properties: [
                    "reminder_identifier": .init(
                        type: "string",
                        description: "The unique identifier of the reminder"
                    ),
                    "title": .init(
                        type: "string",
                        description: "New reminder title"
                    ),
                    "due_date": .init(
                        type: "string",
                        description: "New due date in ISO 8601 format"
                    ),
                    "priority": .init(
                        type: "integer",
                        description: "New priority (0-5)"
                    ),
                    "notes": .init(
                        type: "string",
                        description: "New notes"
                    )
                ],
                required: ["reminder_identifier"]
            ),
            callback: { args in
                guard let reminderIdentifier = args["reminder_identifier"]?.stringValue else {
                    throw AgentError("Missing reminder identifier")
                }

                do {
                    let reminderService = ReminderService()
                    let reminder = try await reminderService.findReminder(identifier: reminderIdentifier)

                    let title = args["title"]?.stringValue
                    let dueDate = (args["due_date"]?.stringValue)?.iso8601Date
                    let priority = args["priority"]?.intValue
                    let notes = args["notes"]?.stringValue

                    let updatedReminder = try reminderService.updateReminder(
                        reminder: reminder,
                        title: title,
                        dueDate: dueDate,
                        priority: priority,
                        notes: notes
                    )

                    return "Reminder updated successfully:\n\(updatedReminder.formattedDetails)"
                } catch {
                    throw AgentError("Failed to update reminder: \(error.localizedDescription)")
                }
            }
        ),
        // In ReminderWriteAgent struct, add these tools to the existing tools array:
        Tool(
            name: "create_list",
            description: "Create a new reminder list",
            tool_schema: .init(
                properties: [
                    "name": .init(
                        type: "string",
                        description: "Name of the new reminder list"
                    ),
                    "color": .init(
                        type: "string",
                        description: "Color for the list (optional, hex format e.g., #FF0000)"
                    )
                ],
                required: ["name"]
            ),
            callback: { args in
                guard let name = args["name"]?.stringValue else {
                    throw AgentError("Missing list name")
                }

                let colorStr = args["color"]?.stringValue
                let color = colorStr.flatMap { hex in
                    Color(hex: hex)
                }

                do {
                    let list = try ReminderService().createList(name: name, color: color)
                    return "Successfully created reminder list: \(list.title)"
                } catch {
                    throw AgentError("Failed to create list: \(error.localizedDescription)")
                }
            }
        ),
        Tool(
            name: "get_lists",
            description: "Get all reminder lists",
            tool_schema: .init(),
            callback: { _ in
                let lists = ReminderService().getAllLists()
                if lists.isEmpty {
                    throw AgentError("No reminder lists found.")
                }
                return "Available reminder lists:\n" + lists.map { list in
                    "- \(list.title)"
                }.joined(separator: "\n")
            }
        ),
        Tool(
            name: "delete_list",
            description: "Delete a reminder list",
            tool_schema: .init(
                properties: [
                    "name": .init(
                        type: "string",
                        description: "Name of the list to delete"
                    )
                ],
                required: ["name"]
            ),
            callback: { args in
                guard let name = args["name"]?.stringValue else {
                    throw AgentError("Missing list name")
                }

                let service = ReminderService()
                guard let list = service.getAllLists().first(where: { $0.title == name }) else {
                    throw AgentError("List not found: \(name)")
                }

                do {
                    try service.deleteList(list)
                    return "Successfully deleted reminder list: \(name)"
                } catch {
                    throw AgentError("Failed to delete list: \(error.localizedDescription)")
                }
            }
        ),
        Tool(
            name: "rename_list",
            description: "Rename a reminder list",
            tool_schema: .init(
                properties: [
                    "old_name": .init(
                        type: "string",
                        description: "Current name of the list"
                    ),
                    "new_name": .init(
                        type: "string",
                        description: "New name for the list"
                    )
                ],
                required: ["old_name", "new_name"]
            ),
            callback: { args in
                guard let oldName = args["old_name"]?.stringValue,
                      let newName = args["new_name"]?.stringValue else {
                    throw AgentError("Missing list name information")
                }

                let service = ReminderService()
                guard let list = service.getAllLists().first(where: { $0.title == oldName }) else {
                    throw AgentError("List not found: \(oldName)")
                }

                do {
                    let updatedList = try service.renameList(list, newName: newName)
                    return "Successfully renamed list from '\(oldName)' to '\(updatedList.title)'"
                } catch {
                    throw AgentError("Failed to rename list: \(error.localizedDescription)")
                }
            }
        )
    ]
}

// MARK: - Main Reminder Agent
public struct ReminderAgent: Agent {
    public init() {
        delegateAgents = [
            ReminderPermissionAgent(),
            ReminderReadAgent(),
            ReminderWriteAgent()
        ]
    }

    public let name = "reminderAgent"
    public let description = """
        Manage reminders - create, read, update, or complete reminders. create, edit, or update reminder lists. 
        Can handle natural language requests like "Remind me to call mom tomorrow" or 
        "What are my upcoming reminders?"
        """
    public let instructions = """
        You are a reminder management assistant. Your responsibilities include:
        1. Managing reminder permissions through the permission agent
        2. Reading and searching reminders through the read agent
        3. Creating, updating, and completing reminders through the write agent
        
        Always verify reminder permissions before performing operations.
        When creating or modifying reminders, ensure all required information is provided.
        Use delegate agents for specialized tasks and provide clear, concise responses.
        """

    public var delegateAgents: [any Agent]

    // Main agent uses delegate agents' tools
    public var tools: [any LangToolsTool]? = nil
}

// MARK: - Required Service Implementation
extension EKReminder {
    var formattedDetails: String {
        var details = "Title: \(title ?? "no title")"
        if let dueDate = dueDateComponents?.date {
            details += "\nDue Date: \(dueDate.formatted())"
        }
        details += "\nPriority: \(priority)"
        if let notes = notes {
            details += "\nNotes: \(notes)"
        }
        details += "\nCompleted: \(isCompleted)"
        details += "\nIdentifier: \(calendarItemIdentifier)"
        return details
    }
}

class ReminderService {
    private let eventStore = EKEventStore()

    func fetchReminders(from startDate: Date, to endDate: Date) async throws -> [EKReminder] {
        let predicate = eventStore.predicateForIncompleteReminders(
            withDueDateStarting: startDate,
            ending: endDate,
            calendars: nil
        )
        return try await withCheckedThrowingContinuation { continuation in
            self.eventStore.fetchReminders(matching: predicate) { reminders in
                if let reminders {
                    continuation.resume(returning: reminders)
                } else {
                    continuation.resume(throwing: ReminderServiceError.invalidData)
                }
            }
        }
    }

    func upcomingReminders(limit: Int = 10) async throws -> [EKReminder] {
        let predicate = eventStore.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: nil
        )
        return try await withCheckedThrowingContinuation { continuation in
            self.eventStore.fetchReminders(matching: predicate) { reminders in
                if let reminders {
                    let sortedReminders = reminders
                        .sorted { ($0.dueDateComponents?.date ?? .distantFuture) < ($1.dueDateComponents?.date ?? .distantFuture) }
                        .prefix(limit)
                    continuation.resume(returning: Array(sortedReminders))
                } else {
                    continuation.resume(throwing: ReminderServiceError.invalidData)
                }
            }
        }
    }

    func searchReminders(matching query: String, includeCompleted: Bool = false) async throws -> [EKReminder] {
        let predicate: NSPredicate
        if includeCompleted {
            predicate = eventStore.predicateForReminders(in: nil)
        } else {
            predicate = eventStore.predicateForIncompleteReminders(
                withDueDateStarting: nil,
                ending: nil,
                calendars: nil
            )
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.eventStore.fetchReminders(matching: predicate) { reminders in
                if let reminders {
                    let filteredReminders = reminders.filter({ reminder in
                            reminder.title.localizedCaseInsensitiveContains(query) ||
                            (reminder.notes?.localizedCaseInsensitiveContains(query) ?? false)
                    })
                    continuation.resume(returning: filteredReminders)
                } else {
                    continuation.resume(throwing: ReminderServiceError.invalidData)
                }
            }
        }
    }

    func createReminder(
        title: String,
        dueDate: Date? = nil,
        priority: Int = 0,
        notes: String? = nil,
        listName: String? = nil
    ) throws -> EKReminder {
        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = title
        reminder.priority = priority
        reminder.notes = notes

        if let dueDate = dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: dueDate)
        }

        // Set calendar (list)
        if let listName = listName {
            let calendars = eventStore.calendars(for: .reminder)
            if let calendar = calendars.first(where: { $0.title == listName }) {
                reminder.calendar = calendar
            } else {
                // Create new calendar if it doesn't exist
                let newCalendar = EKCalendar(for: .reminder, eventStore: eventStore)
                newCalendar.title = listName
                newCalendar.source = eventStore.defaultCalendarForNewReminders()?.source
                try eventStore.saveCalendar(newCalendar, commit: true)
                reminder.calendar = newCalendar
            }
        } else {
            reminder.calendar = eventStore.defaultCalendarForNewReminders()
        }

        try eventStore.save(reminder, commit: true)
        return reminder
    }

    func findReminder(identifier: String) async throws -> EKReminder {
        let predicate = eventStore.predicateForReminders(in: nil)
        return try await withCheckedThrowingContinuation { continuation in
            self.eventStore.fetchReminders(matching: predicate) { reminders in
                if let reminders, let reminder = reminders.first(where: { $0.calendarItemIdentifier == identifier }) {
                    continuation.resume(returning: reminder)
                } else {
                    continuation.resume(throwing: ReminderServiceError.reminderNotFound)
                }
            }
        }
    }

    func completeReminder(_ reminder: EKReminder) throws {
        reminder.isCompleted = true
        try eventStore.save(reminder, commit: true)
    }

    func updateReminder(
        reminder: EKReminder,
        title: String? = nil,
        dueDate: Date? = nil,
        priority: Int? = nil,
        notes: String? = nil
    ) throws -> EKReminder {
        if let title = title {
            reminder.title = title
        }

        if let dueDate = dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: dueDate)
        }

        if let priority = priority {
            reminder.priority = priority
        }

        if let notes = notes {
            reminder.notes = notes
        }

        try eventStore.save(reminder, commit: true)
        return reminder
    }
}

extension ReminderService {
    // Get all reminder lists
    func getAllLists() -> [EKCalendar] {
        return eventStore.calendars(for: .reminder)
    }

    // Create a new reminder list
    func createList(name: String, color: Color? = nil) throws -> EKCalendar {
        // Check if list already exists
        if let existingList = eventStore.calendars(for: .reminder).first(where: { $0.title == name }) {
            return existingList
        }

        // Create new calendar for reminders
        let newList = EKCalendar(for: .reminder, eventStore: eventStore)
        newList.title = name
        if let color = color {
            newList.cgColor = color.cgColor
        }

        // Set source (usually iCloud or Local)
        newList.source = eventStore.defaultCalendarForNewReminders()?.source

        try eventStore.saveCalendar(newList, commit: true)
        return newList
    }

    // Delete a reminder list
    func deleteList(_ calendar: EKCalendar) throws {
        try eventStore.removeCalendar(calendar, commit: true)
    }

    // Rename a reminder list
    func renameList(_ calendar: EKCalendar, newName: String) throws -> EKCalendar {
        calendar.title = newName
        try eventStore.saveCalendar(calendar, commit: true)
        return calendar
    }
}

extension ReminderService {
    struct ListInfo {
        let title: String
        let color: Color?
        let reminderCount: Int
        let completedCount: Int
        let activeCount: Int
    }

    // Get detailed information about a specific list
    func getListInfo(_ calendar: EKCalendar) async throws -> ListInfo {
        let allReminders = try await fetchRemindersInList(calendar)
        let completed = allReminders.filter(\.isCompleted).count

        // Convert CGColor to SwiftUI Color if it exists
        var color: Color?
//        if let cgColor = calendar.cgColor {
//            color = Color(UIColor(cgColor: cgColor))
//        } else {
//            color = nil
//        }

        return ListInfo(
            title: calendar.title,
            color: color,
            reminderCount: allReminders.count,
            completedCount: completed,
            activeCount: allReminders.count - completed
        )
    }

    // Fetch all reminders in a specific list
    func fetchRemindersInList(_ calendar: EKCalendar) async throws -> [EKReminder] {
        let predicate = eventStore.predicateForReminders(in: [calendar])
        return try await withCheckedThrowingContinuation { continuation in
            self.eventStore.fetchReminders(matching: predicate) { reminders in
                if let reminders = reminders {
                    continuation.resume(returning: reminders)
                } else {
                    continuation.resume(throwing: ReminderServiceError.invalidData)
                }
            }
        }
    }
}

extension ReminderService {
    // Helper method to format reminders in a list with optional filters
    func formatRemindersInList(
        _ reminders: [EKReminder],
        includeCompleted: Bool = true,
        sortBy: RemindersSort = .dueDate
    ) -> String {
        let filteredReminders = reminders.filter { reminder in
            includeCompleted || !reminder.isCompleted
        }

        let sortedReminders: [EKReminder]
        switch sortBy {
        case .dueDate:
            sortedReminders = filteredReminders.sorted {
                ($0.dueDateComponents?.date ?? .distantFuture) < ($1.dueDateComponents?.date ?? .distantFuture)
            }
        case .priority:
            sortedReminders = filteredReminders.sorted { $0.priority > $1.priority }
        case .title:
            sortedReminders = filteredReminders.sorted { $0.title < $1.title }
        }

        if sortedReminders.isEmpty {
            return "No reminders found."
        }

        return sortedReminders.map { $0.formattedDetails }.joined(separator: "\n\n")
    }

    enum RemindersSort {
        case dueDate, priority, title
    }
}

// MARK: - Supporting Types
enum ReminderServiceError: String, Error {
    case reminderNotFound = "Reminder not found."
    case invalidPermissions = "Invalid permissions."
    case reminderAccessDenied = "Reminder access denied."
    case invalidData = "Invalid data."
    case saveFailed = "Save failed."
}

// MARK: - Extensions for Date Formatting
extension Date {
    func formatted() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: self)
    }
}

extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0

        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else {
            return nil
        }

        var red, green, blue: Double

        switch hexSanitized.count {
        case 6:
            red = Double((rgb & 0xFF0000) >> 16) / 255.0
            green = Double((rgb & 0x00FF00) >> 8) / 255.0
            blue = Double(rgb & 0x0000FF) / 255.0
        case 8:
            red = Double((rgb & 0xFF000000) >> 24) / 255.0
            green = Double((rgb & 0x00FF0000) >> 16) / 255.0
            blue = Double((rgb & 0x0000FF00) >> 8) / 255.0
        default:
            return nil
        }

        self.init(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }
}
