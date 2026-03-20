//
//  ToolExecutor.swift
//  CLI
//
//  Async tool execution engine with event-based feedback
//

import Foundation
import LangTools
import OpenAI

/// Events emitted during tool execution
enum ToolExecutionEvent {
    case started(toolName: String)
    case progress(toolName: String, message: String)
    case output(toolName: String, content: String)
    case completed(toolName: String, result: ToolExecutionResult)
    case failed(toolName: String, error: Error)
    case cancelled(toolName: String)
}

/// Result of a tool execution
struct ToolExecutionResult {
    let toolName: String
    let output: String
    let exitCode: Int?
    let duration: TimeInterval
    let truncated: Bool

    init(toolName: String, output: String, exitCode: Int? = nil, duration: TimeInterval = 0, truncated: Bool = false) {
        self.toolName = toolName
        self.output = output
        self.exitCode = exitCode
        self.duration = duration
        self.truncated = truncated
    }
}

/// Errors that can occur during tool execution
enum ToolExecutionError: Error, LocalizedError {
    case toolNotFound(String)
    case invalidParameters(String)
    case timeout(toolName: String, timeout: TimeInterval)
    case cancelled(toolName: String)
    case executionFailed(toolName: String, reason: String)
    case approvalRequired(toolName: String, operation: String)

    var errorDescription: String? {
        switch self {
        case .toolNotFound(let name):
            return "Tool not found: \(name)"
        case .invalidParameters(let reason):
            return "Invalid parameters: \(reason)"
        case .timeout(let name, let timeout):
            return "Tool '\(name)' timed out after \(Int(timeout / 1000))s"
        case .cancelled(let name):
            return "Tool '\(name)' was cancelled"
        case .executionFailed(let name, let reason):
            return "Tool '\(name)' failed: \(reason)"
        case .approvalRequired(let name, let operation):
            return "Tool '\(name)' requires approval for: \(operation)"
        }
    }
}

/// Tool execution priority levels
enum ToolExecutionPriority: Int, Comparable {
    case low = 0
    case normal = 1
    case high = 2

    static func < (lhs: ToolExecutionPriority, rhs: ToolExecutionPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Callback type for tool events
typealias ToolEventCallback = (ToolExecutionEvent) -> Void

/// Executor for running tools asynchronously with event-based feedback
actor ToolExecutor {
    /// Shared singleton instance
    static let shared = ToolExecutor()

    /// Tool registry reference
    private let registry = ToolRegistry.shared

    /// Currently executing tools
    private var executingTools: [String: Task<ToolExecutionResult, Error>] = [:]

    /// Event callbacks registered for tool execution
    private var eventCallbacks: [UUID: ToolEventCallback] = [:]

    /// Default timeout in milliseconds
    private let defaultTimeout: TimeInterval = 120_000

    /// Maximum concurrent tool executions
    private let maxConcurrent: Int = 5

    private init() {}

    // MARK: - Event Registration

    /// Register a callback for tool execution events
    /// - Parameter callback: The callback to invoke on events
    /// - Returns: A registration ID that can be used to unregister
    func registerEventCallback(_ callback: @escaping ToolEventCallback) -> UUID {
        let id = UUID()
        eventCallbacks[id] = callback
        return id
    }

    /// Unregister a callback
    /// - Parameter id: The registration ID returned from registerEventCallback
    func unregisterEventCallback(_ id: UUID) {
        eventCallbacks.removeValue(forKey: id)
    }

    /// Emit an event to all registered callbacks
    private func emit(_ event: ToolExecutionEvent) {
        for callback in eventCallbacks.values {
            callback(event)
        }
    }

    // MARK: - Tool Execution

    /// Execute a tool by name with the given parameters
    /// - Parameters:
    ///   - toolName: The name of the tool to execute
    ///   - parameters: Parameters to pass to the tool
    ///   - timeout: Optional timeout in milliseconds (defaults to 120s)
    ///   - priority: Execution priority
    /// - Returns: The execution result
    func execute(
        toolName: String,
        parameters: [String: Any],
        timeout: TimeInterval? = nil,
        priority: ToolExecutionPriority = .normal
    ) async throws -> ToolExecutionResult {
        // Check if tool exists
        guard let tool = registry.tool(named: toolName) else {
            let error = ToolExecutionError.toolNotFound(toolName)
            emit(.failed(toolName: toolName, error: error))
            throw error
        }

        // Check concurrent execution limit
        if executingTools.count >= maxConcurrent {
            // Wait for a slot to open
            while executingTools.count >= maxConcurrent {
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
        }

        // Record start time
        let startTime = Date()

        // Emit start event
        emit(.started(toolName: toolName))

        // Create the execution task
        let task = Task<ToolExecutionResult, Error> {
            let effectiveTimeout = timeout ?? defaultTimeout

            // Execute with timeout
            return try await withThrowingTaskGroup(of: ToolExecutionResult.self) { group in
                // Add the actual execution task
                group.addTask {
                    let output = try await tool.execute(parameters: parameters)
                    let duration = Date().timeIntervalSince(startTime)
                    let truncated = output.count > 30_000
                    let finalOutput = truncated ? String(output.prefix(30_000)) + "\n...(truncated)" : output

                    return ToolExecutionResult(
                        toolName: toolName,
                        output: finalOutput,
                        duration: duration,
                        truncated: truncated
                    )
                }

                // Add a timeout task
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(effectiveTimeout * 1_000_000))
                    throw ToolExecutionError.timeout(toolName: toolName, timeout: effectiveTimeout)
                }

                // Wait for the first task to complete
                guard let result = try await group.next() else {
                    throw ToolExecutionError.executionFailed(toolName: toolName, reason: "No result")
                }

                // Cancel the other task
                group.cancelAll()

                return result
            }
        }

        // Store the executing task
        executingTools[toolName] = task

        do {
            // Wait for completion
            let result = try await task.value

            // Remove from executing
            executingTools.removeValue(forKey: toolName)

            // Emit completion event
            emit(.completed(toolName: toolName, result: result))

            return result
        } catch is CancellationError {
            executingTools.removeValue(forKey: toolName)
            let error = ToolExecutionError.cancelled(toolName: toolName)
            emit(.cancelled(toolName: toolName))
            throw error
        } catch {
            executingTools.removeValue(forKey: toolName)
            emit(.failed(toolName: toolName, error: error))
            throw error
        }
    }

    /// Execute a tool from a tool call response
    /// - Parameter toolCall: The tool call from the LLM response
    /// - Returns: The execution result
    func execute(toolCall: OpenAI.Message.ToolCall) async throws -> ToolExecutionResult {
        guard let toolName = toolCall.name else {
            throw ToolExecutionError.invalidParameters("Tool call missing name")
        }

        // Parse arguments JSON
        let argumentsString = toolCall.arguments
        let parameters: [String: Any]
        if !argumentsString.isEmpty,
           let data = argumentsString.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            parameters = json
        } else {
            parameters = [:]
        }

        return try await execute(toolName: toolName, parameters: parameters)
    }

    // MARK: - Tool Control

    /// Cancel a running tool execution
    /// - Parameter toolName: The name of the tool to cancel
    func cancel(toolName: String) {
        if let task = executingTools[toolName] {
            task.cancel()
            executingTools.removeValue(forKey: toolName)
            emit(.cancelled(toolName: toolName))
        }
    }

    /// Cancel all running tool executions
    func cancelAll() {
        for (name, task) in executingTools {
            task.cancel()
            emit(.cancelled(toolName: name))
        }
        executingTools.removeAll()
    }

    /// Check if a tool is currently executing
    /// - Parameter toolName: The name of the tool to check
    /// - Returns: True if the tool is executing
    func isExecuting(toolName: String) -> Bool {
        executingTools[toolName] != nil
    }

    /// Get the names of all currently executing tools
    var executingToolNames: [String] {
        Array(executingTools.keys)
    }
}

// MARK: - Tool Approval

/// Tools that require user approval before execution
struct ToolApprovalPolicy {
    /// Tools that always require approval
    static let alwaysApprove: Set<String> = [
        "write",
        "edit",
        "bash"
    ]

    /// Operations within tools that require approval
    static let dangerousOperations: [String: Set<String>] = [
        "bash": ["rm", "sudo", "chmod", "chown", "mv"],
        "write": [],  // All writes need approval
        "edit": []    // All edits need approval
    ]

    /// Check if a tool execution requires approval
    /// - Parameters:
    ///   - toolName: The tool name
    ///   - parameters: The parameters being passed
    /// - Returns: True if approval is required
    static func requiresApproval(toolName: String, parameters: [String: Any]) -> Bool {
        // Check if tool always requires approval
        if alwaysApprove.contains(toolName) {
            return true
        }

        // Check for dangerous operations in bash commands
        if toolName == "bash", let command = parameters["command"] as? String {
            let dangerous = dangerousOperations["bash"] ?? []
            for op in dangerous {
                if command.contains(op) {
                    return true
                }
            }
        }

        return false
    }

    /// Get a description of the operation requiring approval
    /// - Parameters:
    ///   - toolName: The tool name
    ///   - parameters: The parameters
    /// - Returns: A human-readable description
    static func operationDescription(toolName: String, parameters: [String: Any]) -> String {
        switch toolName {
        case "write":
            let path = parameters["file_path"] as? String ?? "unknown"
            return "Write to file: \(path)"
        case "edit":
            let path = parameters["file_path"] as? String ?? "unknown"
            return "Edit file: \(path)"
        case "bash":
            let command = parameters["command"] as? String ?? "unknown"
            let truncated = command.count > 50 ? String(command.prefix(50)) + "..." : command
            return "Execute command: \(truncated)"
        default:
            return "Execute \(toolName)"
        }
    }
}
