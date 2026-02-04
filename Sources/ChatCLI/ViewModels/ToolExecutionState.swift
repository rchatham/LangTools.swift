//
//  ToolExecutionState.swift
//  ChatCLI
//
//  State management for tool execution feedback in the UI
//

import Foundation
import SwiftTUI

/// Observable state for tool execution
@MainActor
class ToolExecutionState: ObservableObject {
    /// Currently executing tool name
    @Published var currentTool: String? = nil

    /// Progress message for the current tool
    @Published var progressMessage: String? = nil

    /// Whether a tool is currently executing
    @Published var isExecuting: Bool = false

    /// Pending approval request, if any
    @Published var pendingApproval: ApprovalRequest? = nil

    /// History of recent tool executions
    @Published var executionHistory: [ToolExecutionRecord] = []

    /// Maximum history entries to keep
    private let maxHistoryEntries = 50

    /// Event callback registration ID
    private var callbackId: UUID?

    init() {
        registerForEvents()
    }

    deinit {
        // Unregister callback when deallocated
        if let id = callbackId {
            Task {
                await ToolExecutor.shared.unregisterEventCallback(id)
            }
        }
    }

    // MARK: - Event Registration

    private func registerForEvents() {
        Task {
            callbackId = await ToolExecutor.shared.registerEventCallback { [weak self] event in
                Task { @MainActor in
                    self?.handleEvent(event)
                }
            }
        }
    }

    private func handleEvent(_ event: ToolExecutionEvent) {
        switch event {
        case .started(let toolName):
            currentTool = toolName
            progressMessage = "Starting..."
            isExecuting = true

        case .progress(let toolName, let message):
            if currentTool == toolName {
                progressMessage = message
            }

        case .output(let toolName, let content):
            // Could be used for streaming output display
            _ = (toolName, content)

        case .completed(let toolName, let result):
            addToHistory(ToolExecutionRecord(
                toolName: toolName,
                status: .completed,
                output: result.output,
                duration: result.duration,
                timestamp: Date()
            ))
            clearCurrentExecution()

        case .failed(let toolName, let error):
            addToHistory(ToolExecutionRecord(
                toolName: toolName,
                status: .failed,
                output: error.localizedDescription,
                duration: 0,
                timestamp: Date()
            ))
            clearCurrentExecution()

        case .cancelled(let toolName):
            addToHistory(ToolExecutionRecord(
                toolName: toolName,
                status: .cancelled,
                output: "Cancelled by user",
                duration: 0,
                timestamp: Date()
            ))
            clearCurrentExecution()
        }
    }

    private func clearCurrentExecution() {
        currentTool = nil
        progressMessage = nil
        isExecuting = false
    }

    private func addToHistory(_ record: ToolExecutionRecord) {
        executionHistory.insert(record, at: 0)
        if executionHistory.count > maxHistoryEntries {
            executionHistory.removeLast()
        }
    }

    // MARK: - Approval Handling

    /// Request approval for a tool operation
    func requestApproval(
        toolName: String,
        operation: String,
        parameters: [String: Any]
    ) -> ApprovalRequest {
        let request = ApprovalRequest(
            id: UUID(),
            toolName: toolName,
            operation: operation,
            parameters: parameters
        )
        pendingApproval = request
        return request
    }

    /// Approve the pending request
    func approveRequest() {
        if let request = pendingApproval {
            request.approve()
        }
        pendingApproval = nil
    }

    /// Deny the pending request
    func denyRequest() {
        if let request = pendingApproval {
            request.deny()
        }
        pendingApproval = nil
    }

    // MARK: - Tool Control

    /// Cancel the currently executing tool
    func cancelCurrentTool() {
        guard let toolName = currentTool else { return }
        Task {
            await ToolExecutor.shared.cancel(toolName: toolName)
        }
    }

    /// Cancel all executing tools
    func cancelAllTools() {
        Task {
            await ToolExecutor.shared.cancelAll()
        }
    }
}

// MARK: - Supporting Types

/// Record of a tool execution
struct ToolExecutionRecord: Identifiable {
    let id = UUID()
    let toolName: String
    let status: ExecutionStatus
    let output: String
    let duration: TimeInterval
    let timestamp: Date

    enum ExecutionStatus {
        case completed
        case failed
        case cancelled
    }

    var statusIcon: String {
        switch status {
        case .completed: return "✓"
        case .failed: return "✗"
        case .cancelled: return "○"
        }
    }

    var formattedDuration: String {
        if duration < 1 {
            return String(format: "%.0fms", duration * 1000)
        } else if duration < 60 {
            return String(format: "%.1fs", duration)
        } else {
            let minutes = Int(duration / 60)
            let seconds = Int(duration.truncatingRemainder(dividingBy: 60))
            return "\(minutes)m \(seconds)s"
        }
    }
}

/// Request for tool operation approval
class ApprovalRequest: Identifiable {
    let id: UUID
    let toolName: String
    let operation: String
    let parameters: [String: Any]

    private var continuation: CheckedContinuation<Bool, Never>?
    private var resolved = false

    init(id: UUID, toolName: String, operation: String, parameters: [String: Any]) {
        self.id = id
        self.toolName = toolName
        self.operation = operation
        self.parameters = parameters
    }

    /// Wait for user decision
    func waitForDecision() async -> Bool {
        guard !resolved else { return false }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    /// Approve the request
    func approve() {
        guard !resolved else { return }
        resolved = true
        continuation?.resume(returning: true)
    }

    /// Deny the request
    func deny() {
        guard !resolved else { return }
        resolved = true
        continuation?.resume(returning: false)
    }

    /// Description of the operation
    var description: String {
        ToolApprovalPolicy.operationDescription(toolName: toolName, parameters: parameters)
    }
}
