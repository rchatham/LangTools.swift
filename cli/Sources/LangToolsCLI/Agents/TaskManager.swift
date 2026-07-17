//
//  TaskManager.swift
//  CLI
//
//  Manages background agent task lifecycle
//

import Foundation
import LangTools
import OpenAI
import Agents

/// Manages agent task execution and lifecycle
actor TaskManager {
    /// Shared singleton instance
    static let shared = TaskManager()

    /// Active tasks
    private var activeTasks: [String: AgentTask] = [:]

    /// Running task handles
    private var runningTasks: [String: Task<String, Error>] = [:]

    /// Completed tasks (kept for resume capability)
    private var completedTasks: [String: AgentTask] = [:]

    /// Event callbacks
    private var eventCallbacks: [UUID: (AgentTaskEvent) -> Void] = [:]

    /// Maximum concurrent tasks
    private let maxConcurrentTasks = 5

    /// Maximum history size
    private let maxHistorySize = 50

    private init() {}

    // MARK: - Event Registration

    /// Register a callback for task events
    func registerEventCallback(_ callback: @escaping (AgentTaskEvent) -> Void) -> UUID {
        let id = UUID()
        eventCallbacks[id] = callback
        return id
    }

    /// Unregister a callback
    func unregisterEventCallback(_ id: UUID) {
        eventCallbacks.removeValue(forKey: id)
    }

    private func emit(_ event: AgentTaskEvent) {
        for callback in eventCallbacks.values {
            callback(event)
        }
    }

    // MARK: - Task Management

    /// Get a task by ID
    func getTask(id: String) -> AgentTask? {
        activeTasks[id] ?? completedTasks[id]
    }

    /// Get all active tasks
    var allActiveTasks: [AgentTask] {
        Array(activeTasks.values)
    }

    /// Get all completed tasks
    var allCompletedTasks: [AgentTask] {
        Array(completedTasks.values)
    }

    /// Execute a task synchronously
    func executeTask(_ task: AgentTask) async -> String {
        var task = task
        task.status = .running
        task.startTime = Date()
        activeTasks[task.id] = task

        emit(.started(taskId: task.id, agentType: task.agentType))

        do {
            let result = try await runAgent(task: task)

            task.status = .completed
            task.result = result
            task.endTime = Date()

            activeTasks.removeValue(forKey: task.id)
            addToHistory(task)

            emit(.completed(taskId: task.id, result: result))

            return result
        } catch {
            task.status = .failed
            task.error = error.localizedDescription
            task.endTime = Date()

            activeTasks.removeValue(forKey: task.id)
            addToHistory(task)

            emit(.failed(taskId: task.id, error: error))

            return "Error: \(error.localizedDescription)"
        }
    }

    /// Launch a task in the background
    func launchBackgroundTask(_ task: AgentTask) {
        var task = task
        task.status = .running
        task.startTime = Date()

        // Create output file for background task
        let outputPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("chatcli_task_\(task.id).txt")
            .path
        task.outputFile = outputPath

        activeTasks[task.id] = task

        let handle = Task<String, Error> {
            emit(.started(taskId: task.id, agentType: task.agentType))

            do {
                let result = try await runAgent(task: task)

                // Write result to output file
                try? result.write(toFile: outputPath, atomically: true, encoding: .utf8)

                var updatedTask = task
                updatedTask.status = .completed
                updatedTask.result = result
                updatedTask.endTime = Date()

                activeTasks.removeValue(forKey: task.id)
                addToHistory(updatedTask)

                emit(.completed(taskId: task.id, result: result))

                return result
            } catch {
                var updatedTask = task
                updatedTask.status = .failed
                updatedTask.error = error.localizedDescription
                updatedTask.endTime = Date()

                activeTasks.removeValue(forKey: task.id)
                addToHistory(updatedTask)

                emit(.failed(taskId: task.id, error: error))

                throw error
            }
        }

        runningTasks[task.id] = handle
    }

    /// Resume a task
    func resumeTask(_ task: AgentTask) async -> String {
        // If task is still running, wait for it
        if let handle = runningTasks[task.id] {
            do {
                return try await handle.value
            } catch {
                return "Error resuming task: \(error.localizedDescription)"
            }
        }

        // If completed, return result
        if task.status == .completed, let result = task.result {
            return result
        }

        // If failed, return error
        if task.status == .failed, let error = task.error {
            return "Previous execution failed: \(error)"
        }

        // Re-execute the task
        return await executeTask(task)
    }

    /// Cancel a running task
    func cancelTask(id: String) {
        if let handle = runningTasks[id] {
            handle.cancel()
            runningTasks.removeValue(forKey: id)
        }

        if var task = activeTasks[id] {
            task.status = .cancelled
            task.endTime = Date()
            activeTasks.removeValue(forKey: id)
            addToHistory(task)
            emit(.cancelled(taskId: id))
        }
    }

    /// Cancel all running tasks
    func cancelAllTasks() {
        for (id, handle) in runningTasks {
            handle.cancel()
            if var task = activeTasks[id] {
                task.status = .cancelled
                task.endTime = Date()
                addToHistory(task)
                emit(.cancelled(taskId: id))
            }
        }
        runningTasks.removeAll()
        activeTasks.removeAll()
    }

    // MARK: - Agent Execution

    private func runAgent(task: AgentTask) async throws -> String {
        // Create the agent based on type
        let agent = createAgent(for: task.agentType)

        // Get the tool registry and select tools for this agent type
        let registry = ToolRegistry.shared

        // Create tools with callbacks that execute via the registry
        let langToolsTools: [OpenAI.Tool] = task.agentType.tools.compactMap { toolName -> OpenAI.Tool? in
            guard let tool = registry.tool(named: toolName) else { return nil }
            return OpenAI.Tool.function(.init(
                name: tool.name,
                description: tool.description,
                parameters: tool.parametersSchema,
                callback: { _, args in
                    // Convert JSON args to [String: Any]
                    var params: [String: Any] = [:]
                    for (key, value) in args {
                        params[key] = value.anyValue
                    }
                    return try await registry.execute(toolName: toolName, parameters: params)
                }
            ))
        }

        // Create OpenAI instance for agent execution
        let langTool = OpenAI(apiKey: ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? "")

        // Default to GPT-4o for agent tasks
        let openAIModel: OpenAIModel = .gpt4o

        var progressMessages: [String] = []

        // Use the generic initializer with explicit types
        let messages: [any LangToolsMessage] = [langTool.userMessage(task.prompt)]
        let eventHandler: (AgentEvent) -> Void = { [weak self] event in
            Task {
                await self?.handleAgentEvent(event, taskId: task.id)
            }
            progressMessages.append(event.description)
        }

        let context = AgentContext(
            langTool: langTool as any LangTools,
            model: openAIModel as any RawRepresentable,
            messages: messages,
            eventHandler: eventHandler,
            parent: nil,
            tools: langToolsTools
        )

        // Execute the agent
        let result = try await agent.execute(context: context)

        return result
    }

    private func createAgent(for type: AgentType) -> CLIAgent {
        CLIAgent(agentType: type)
    }

    private func handleAgentEvent(_ event: AgentEvent, taskId: String) {
        emit(.progress(taskId: taskId, message: event.description))
    }

    // MARK: - History Management

    private func addToHistory(_ task: AgentTask) {
        completedTasks[task.id] = task

        // Trim history if needed
        if completedTasks.count > maxHistorySize {
            let sorted = completedTasks.values.sorted { ($0.endTime ?? Date.distantPast) < ($1.endTime ?? Date.distantPast) }
            let toRemove = sorted.prefix(completedTasks.count - maxHistorySize)
            for task in toRemove {
                completedTasks.removeValue(forKey: task.id)
            }
        }
    }
}

// MARK: - CLI Agent Implementation

/// A CLI-specific agent that wraps the Agent protocol
struct CLIAgent: Agent {
    let agentType: AgentType

    var name: String { agentType.rawValue }

    var description: String { agentType.description }

    var instructions: String {
        switch agentType {
        case .explore:
            return """
            You are an exploration agent specialized in quickly navigating and understanding codebases.
            Use glob to find files by pattern, grep to search for code keywords, and read to examine file contents.
            Be thorough but efficient - prioritize the most relevant information.
            Summarize your findings clearly and concisely.
            """

        case .plan:
            return """
            You are a planning agent specialized in designing implementation strategies.
            Analyze the codebase structure and existing patterns before proposing changes.
            Create step-by-step implementation plans that are specific and actionable.
            Identify potential risks, dependencies, and architectural considerations.
            Your plans should be clear enough for another agent or developer to execute.
            """

        case .general:
            return """
            You are a general-purpose agent capable of handling complex, multi-step tasks.
            You have access to all tools including file reading, writing, editing, and bash execution.
            Be methodical and thorough in your approach.
            If a task is unclear, break it down into smaller steps.
            Always verify your work before reporting completion.
            """

        case .bash:
            return """
            You are a command execution specialist focused on running bash commands.
            Use bash commands for git operations, file operations, and system tasks.
            Be careful with destructive operations - always verify before deleting or overwriting.
            Report command output clearly and explain any errors encountered.
            """
        }
    }

    var tools: [any LangToolsTool]? { nil }  // Tools are passed via context

    var delegateAgents: [any Agent] { [] }  // No delegation for CLI agents
}

// MARK: - JSON Extension

extension JSON {
    /// Convert JSON to Any for tool parameter passing
    var anyValue: Any {
        switch self {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b
        case .array(let arr): return arr.map { $0.anyValue }
        case .object(let obj): return obj.mapValues { $0.anyValue }
        case .null: return NSNull()
        }
    }
}
