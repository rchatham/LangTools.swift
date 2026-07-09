//
//  EmailService.swift
//  LangTools_Example
//
//  Created by Claude on 2025-01-10.
//

import Foundation
import MailKit

/// Errors that can occur during email operations
public enum EmailServiceError: Error {
    case invalidEmailAddress
    case sendFailure(String)
    case fetchFailure(String)
    case searchFailure(String)
    case permissionDenied
    case noMailAccountConfigured

    var localizedDescription: String {
        switch self {
        case .invalidEmailAddress:
            return "Invalid email address provided"
        case .sendFailure(let reason):
            return "Failed to send email: \(reason)"
        case .fetchFailure(let reason):
            return "Failed to fetch emails: \(reason)"
        case .searchFailure(let reason):
            return "Failed to search emails: \(reason)"
        case .permissionDenied:
            return "Permission to access Mail is required"
        case .noMailAccountConfigured:
            return "No Mail account is configured on this device"
        }
    }
}

/// A wrapper around MKMailManager to manage email operations
@available(macOS 14.0, iOS 17.0, *)
public actor EmailService {
    private let mailManager: MKMailManager
    private var hasPermission: Bool = false

    public init() throws {
        // Attempt to initialize, which may throw if permission is not granted
        self.mailManager = try MKMailManager()
        self.hasPermission = true  // If we get here, we have permission
    }

    // MARK: - Authorization

    /// Check and request permission if needed
    public func requestPermissionIfNeeded() async -> Bool {
        // If we already have permission, return true
        if hasPermission {
            return true
        }

        // Try to create a mail manager which will trigger the permission request
        do {
            _ = try MKMailManager()
            hasPermission = true
            return true
        } catch let error as MKError {
            // Handle specific MailKit errors
            switch error.code {
            case .noAccount:
                print("No mail account configured")
            case .accessDenied:
                print("Mail access denied by user")
            default:
                print("Mail error: \(error.localizedDescription)")
            }
            return false
        } catch {
            print("Unknown error: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Send Operations

    /// Send an email
    /// - Parameters:
    ///   - recipients: List of email addresses to send to
    ///   - subject: Email subject line
    ///   - body: Email body content (can include HTML)
    public func sendEmail(to recipients: [String], subject: String, body: String) async throws {
        // Ensure we have permission before attempting to send
        guard await requestPermissionIfNeeded() else {
            throw EmailServiceError.permissionDenied
        }

        let message = MKMessage()
        message.subject = subject
        message.htmlContent = body
        message.toRecipients = recipients.map { MKEmailAddress(rawValue: $0) }.compactMap { $0 }

        try await mailManager.send(message)
    }

    // MARK: - Fetch Operations

    /// Fetch emails from a mailbox
    /// - Parameters:
    ///   - mailbox: Optional mailbox to fetch from (defaults to inbox)
    ///   - limit: Maximum number of emails to fetch (default: 10)
    /// - Returns: Array of messages sorted by date (newest first)
    public func fetchEmails(mailbox: MKMailbox? = nil, limit: Int = 10) async throws -> [MKMessage] {
        // Ensure we have permission before attempting to fetch
        guard await requestPermissionIfNeeded() else {
            throw EmailServiceError.permissionDenied
        }

        let targetMailbox = mailbox ?? try await mailManager.inbox
        let messages = try await targetMailbox.messages

        // Sort by date and take the specified limit
        return Array(messages
            .sorted(by: { ($0.dateReceived ?? Date()) > ($1.dateReceived ?? Date()) })
            .prefix(limit))
    }

    // MARK: - Search Operations

    /// Search emails in a mailbox
    /// - Parameters:
    ///   - query: Search query for subject and body content
    ///   - mailbox: Optional mailbox to search (defaults to inbox)
    /// - Returns: Array of matching messages
    public func searchEmails(query: String, mailbox: MKMailbox? = nil) async throws -> [MKMessage] {
        // Ensure we have permission before attempting to search
        guard await requestPermissionIfNeeded() else {
            throw EmailServiceError.permissionDenied
        }

        let targetMailbox = mailbox ?? try await mailManager.inbox
        let predicate = NSPredicate(format: "subject CONTAINS[cd] %@ OR body CONTAINS[cd] %@", query, query)

        let messages = try await targetMailbox.messages
        return messages.filter { message in
            predicate.evaluate(with: message)
        }
    }

    // MARK: - Mailbox Operations

    /// Get all available mailboxes
    /// - Returns: Array of mailboxes
    public func getMailboxes() async throws -> [MKMailbox] {
        // Ensure we have permission before attempting to get mailboxes
        guard await requestPermissionIfNeeded() else {
            throw EmailServiceError.permissionDenied
        }

        return try await mailManager.mailboxes
    }
}

// MARK: - Message Formatting Extensions

@available(macOS 14.0, iOS 17.0, *)
extension MKMessage {
    /// Format message details as a human-readable string
    public var formattedDetails: String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        var details = """
            From: \(fromAddress?.rawValue ?? "Unknown")
            Subject: \(subject)
            """

        if let dateReceived = dateReceived {
            details += "\nDate: \(dateFormatter.string(from: dateReceived))"
        }

        details += "\n----------------------------------------"

        return details
    }
}
