//
//  EmailAgent.swift
//  LangTools_Example
//
//  Created by Claude on 2025-01-10.
//

import Foundation
import MailKit
import LangTools
import Agents

// MARK: - Email Permission Agent

@available(macOS 14.0, iOS 17.0, *)
struct EmailPermissionAgent: Agent {
    init() {}

    let name = "emailPermissionAgent"
    let description = "Agent responsible for managing email access permissions"
    let instructions = """
        You are responsible for checking and requesting email permissions.
        Only request permissions when explicitly needed and inform the user about the status.
        """

    var delegateAgents: [any Agent] = []

    var tools: [any LangToolsTool]? = [
        Tool(
            name: "request_email_permission",
            description: "Request permission to access the user's emails. Use this if permission has not been granted.",
            tool_schema: .init(),
            callback: { _ in
                do {
                    let emailService = try EmailService()
                    let permissionGranted = await emailService.requestPermissionIfNeeded()
                    if permissionGranted {
                        return "Permission to access Mail has been granted. You can now perform email operations."
                    } else {
                        return "Permission to access Mail was denied. The user needs to grant permission in Settings > Privacy > Mail before email operations can be performed."
                    }
                } catch {
                    return "Failed to initialize email service: \(error.localizedDescription). Please ensure a Mail account is configured on this device."
                }
            }
        )
    ]
}

// MARK: - Email Read Agent

@available(macOS 14.0, iOS 17.0, *)
struct EmailReadAgent: Agent {
    init() {}

    let name = "emailReadAgent"
    let description = "Agent responsible for reading and fetching emails"
    let instructions = """
        You are responsible for reading and fetching emails from the user's mailbox.
        Format email information clearly and provide relevant details.
        When listing emails, include sender, subject, and date received.
        """

    var delegateAgents: [any Agent] = []

    var tools: [any LangToolsTool]? = [
        Tool(
            name: "fetch_recent_emails",
            description: "Fetch recent emails from the inbox",
            tool_schema: .init(
                properties: [
                    "limit": .init(
                        type: "integer",
                        description: "Maximum number of emails to fetch (default: 10)"
                    )
                ],
                required: []
            ),
            callback: { args in
                let limit = args["limit"]?.intValue ?? 10

                do {
                    let emailService = try EmailService()
                    let messages = try await emailService.fetchEmails(limit: limit)
                    return formatEmailMessages(messages)
                } catch EmailServiceError.permissionDenied {
                    return "Permission to access Mail is required. Please use the request_email_permission tool first."
                } catch {
                    throw AgentError("Failed to fetch emails: \(error.localizedDescription)")
                }
            }
        ),
        Tool(
            name: "list_mailboxes",
            description: "List available mailboxes/folders",
            tool_schema: .init(),
            callback: { _ in
                do {
                    let emailService = try EmailService()
                    let mailboxes = try await emailService.getMailboxes()
                    if mailboxes.isEmpty {
                        return "No mailboxes found."
                    }
                    return "Available mailboxes:\n" + mailboxes.map { "- \($0.name)" }.joined(separator: "\n")
                } catch EmailServiceError.permissionDenied {
                    return "Permission to access Mail is required. Please use the request_email_permission tool first."
                } catch {
                    throw AgentError("Failed to list mailboxes: \(error.localizedDescription)")
                }
            }
        )
    ]
}

// MARK: - Email Search Agent

@available(macOS 14.0, iOS 17.0, *)
struct EmailSearchAgent: Agent {
    init() {}

    let name = "emailSearchAgent"
    let description = "Agent responsible for searching emails"
    let instructions = """
        You are responsible for searching emails based on user queries.
        Search for relevant emails matching the user's criteria.
        Provide clear, formatted results with sender, subject, and date.
        """

    var delegateAgents: [any Agent] = []

    var tools: [any LangToolsTool]? = [
        Tool(
            name: "search_emails",
            description: "Search emails by subject or body content",
            tool_schema: .init(
                properties: [
                    "query": .init(
                        type: "string",
                        description: "Search query for subject and body content"
                    )
                ],
                required: ["query"]
            ),
            callback: { args in
                guard let query = args["query"]?.stringValue else {
                    throw AgentError("Missing search query")
                }

                do {
                    let emailService = try EmailService()
                    let messages = try await emailService.searchEmails(query: query)
                    return formatEmailMessages(messages)
                } catch EmailServiceError.permissionDenied {
                    return "Permission to access Mail is required. Please use the request_email_permission tool first."
                } catch {
                    throw AgentError("Failed to search emails: \(error.localizedDescription)")
                }
            }
        )
    ]
}

// MARK: - Email Send Agent

@available(macOS 14.0, iOS 17.0, *)
struct EmailSendAgent: Agent {
    init() {
        delegateAgents = [
            EmailReadAgent()
        ]
    }

    let name = "emailSendAgent"
    let description = "Agent responsible for composing and sending emails"
    let instructions = """
        You are responsible for composing and sending emails.
        Ensure all required information (recipients, subject, body) is provided and validated.
        Verify email addresses before sending and confirm content with users when appropriate.
        """

    var delegateAgents: [any Agent]

    var tools: [any LangToolsTool]? = [
        Tool(
            name: "send_email",
            description: "Send an email to specified recipients",
            tool_schema: .init(
                properties: [
                    "recipients": .init(
                        type: "array",
                        description: "List of email addresses to send to"
                    ),
                    "subject": .init(
                        type: "string",
                        description: "Email subject line"
                    ),
                    "body": .init(
                        type: "string",
                        description: "Email body content, can include HTML"
                    )
                ],
                required: ["recipients", "subject", "body"]
            ),
            callback: { args in
                guard let recipientsJson = args["recipients"]?.arrayValue,
                      let subject = args["subject"]?.stringValue,
                      let body = args["body"]?.stringValue else {
                    throw AgentError("Invalid email parameters. Required: recipients (array), subject (string), body (string)")
                }

                let recipients = recipientsJson.compactMap { $0.stringValue }
                guard !recipients.isEmpty else {
                    throw AgentError("No valid email addresses provided in recipients list")
                }

                do {
                    let emailService = try EmailService()
                    try await emailService.sendEmail(
                        to: recipients,
                        subject: subject,
                        body: body
                    )
                    return "Email sent successfully to: \(recipients.joined(separator: ", "))"
                } catch EmailServiceError.permissionDenied {
                    return "Permission to access Mail is required. Please use the request_email_permission tool first."
                } catch EmailServiceError.invalidEmailAddress {
                    throw AgentError("One or more email addresses are invalid")
                } catch {
                    throw AgentError("Failed to send email: \(error.localizedDescription)")
                }
            }
        )
    ]
}

// MARK: - Main Email Agent

@available(macOS 14.0, iOS 17.0, *)
public struct EmailAgent: Agent {
    public init() {
        delegateAgents = [
            EmailPermissionAgent(),
            EmailReadAgent(),
            EmailSearchAgent(),
            EmailSendAgent()
        ]
    }

    public let name = "emailAgent"
    public let description = """
        Manage emails - read, send, search, and organize emails using Apple MailKit.
        Can handle natural language requests like "Send an email to John" or
        "Show me my recent emails from Alice."
        """
    public let instructions = """
        You are an email management assistant. Your responsibilities include:
        1. Managing email permissions through the permission agent
        2. Reading and fetching emails through the read agent
        3. Searching emails through the search agent
        4. Composing and sending emails through the send agent

        IMPORTANT: The user needs to grant permission to the app to access Mail.
        If permission is required, inform the user and use the permission agent.
        If permission is denied, explain to the user what permissions are needed.

        Always verify email addresses and content before sending.
        Format email content appropriately and provide clear, concise responses.
        Handle emails with sensitivity and maintain privacy.

        Use delegate agents for specialized tasks and provide clear, concise responses.
        """

    public var delegateAgents: [any Agent]

    // Main agent uses delegate agents' tools
    public var tools: [any LangToolsTool]? = nil
}

// MARK: - Helper Functions

@available(macOS 14.0, iOS 17.0, *)
private func formatEmailMessages(_ messages: [MKMessage]) -> String {
    if messages.isEmpty {
        return "No emails found."
    }

    let dateFormatter = DateFormatter()
    dateFormatter.dateStyle = .medium
    dateFormatter.timeStyle = .short

    return messages.map { message in
        var details = "From: \(message.fromAddress?.rawValue ?? "Unknown")"
        details += "\nSubject: \(message.subject)"
        if let dateReceived = message.dateReceived {
            details += "\nDate: \(dateFormatter.string(from: dateReceived))"
        }
        details += "\n----------------------------------------"
        return details
    }.joined(separator: "\n\n")
}
