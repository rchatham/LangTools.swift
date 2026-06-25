//
//  TaskTool.swift
//  CLI
//
//  Tool for spawning background agents to handle complex tasks
//

import Foundation
import LangTools
import OpenAI
import Agents

/// Agent types available for spawning
enum AgentType: String, CaseIterable, Codable {
    case explore = "Explore"
    case plan = "Plan"
    case general = "general-purpose"
    case bash = "Bash"

    var description: String {
        switch self {
        case .explore:
            return "Fast agent specialized for exploring codebases. Use for quick file searches, code keyword searches, or codebase questions."
        case .plan:
            return "Software architect agent for designing implementation plans. Returns step-by-step plans and identifies critical files."
        case .general:
            return "General-purpose agent for researching complex questions, searching for code, and executing multi-step tasks."
        case .bash:
            return "Command execution specialist for running bash commands. Use for git operations and terminal tasks."
        }
    }

    var tools: [String] {
        switch self {
        case .explore:
            return ["read", "glob", "grep"]
        case .plan:
            return ["read", "glob", "grep"]
        case .general:
            return ["read", "write", "edit", "bash", "glob", "grep"]
        case .bash:
            return ["bash"]
        }
    }
}

/// Task spawning tool - launches background agents
struct TaskTool: ExecutableTool {
    static var name: String { "task" }

    static var description: String {
        """
        Launch a new agent to handle complex, multi-step tasks autonomously.
        Spawns specialized agents (subprocesses) that autonomously handle complex tasks.
        Each agent type has specific capabilities and tools available to it.
        """
    }

    static var parametersSchema: OpenAI.Tool.FunctionSchema.Parameters {
        .init(
            properties: [
                "prompt": .init(
                    type: "string",
                    description: "The task for the agent to perform"
                ),
                "subagent_type": .init(
                    type: "string",
                    enumValues: AgentType.allCases.map { $0.rawValue },
                    description: "The type of specialized agent to use for this task"
                ),
                "description": .init(
                    type: "string",
                    description: "A short (3-5 word) description of the task"
                ),
                "run_in_background": .init(
                    type: "boolean",
                    description: "Set to true to run this agent in the background"
                ),
                "resume": .init(
                    type: "string",
                    description: "Optional agent ID to resume from a previous execution"
                )
            ],
            required: ["prompt", "subagent_type", "description"]
        )
    }

    static func execute(parameters: [String: Any]) async throws -> String {
        guard let prompt = ToolRegistry.extractString(parameters, key: "prompt") else {
            throw ToolExecutionError.invalidParameters("Missing required parameter: prompt")
        }

        guard let subagentTypeString = ToolRegistry.extractString(parameters, key: "subagent_type"),
              let subagentType = AgentType(rawValue: subagentTypeString) else {
            throw ToolExecutionError.invalidParameters("Invalid or missing subagent_type")
        }

        let description = ToolRegistry.extractString(parameters, key: "description") ?? "Task"
        let runInBackground = ToolRegistry.extractBool(parameters, key: "run_in_background") ?? false
        let resumeId = ToolRegistry.extractString(parameters, key: "resume")

        // Get the task manager
        let taskManager = await TaskManager.shared

        // Check for resume
        if let id = resumeId, let existingTask = await taskManager.getTask(id: id) {
            // Resume existing task
            return await taskManager.resumeTask(existingTask)
        }

        // Create and execute new task
        let task = AgentTask(
            id: UUID().uuidString,
            agentType: subagentType,
            prompt: prompt,
            description: description,
            status: .pending
        )

        if runInBackground {
            // Launch in background and return immediately
            await taskManager.launchBackgroundTask(task)
            return """
            Agent '\(subagentType.rawValue)' launched in background.
            Task ID: \(task.id)
            Description: \(description)
            Use the task ID to check on progress or resume later.
            """
        } else {
            // Execute synchronously
            return await taskManager.executeTask(task)
        }
    }
}

/// Represents an agent task
struct AgentTask: Identifiable, Codable {
    let id: String
    let agentType: AgentType
    let prompt: String
    let description: String
    var status: TaskStatus
    var result: String?
    var error: String?
    var startTime: Date?
    var endTime: Date?
    var outputFile: String?

    enum TaskStatus: String, Codable {
        case pending
        case running
        case completed
        case failed
        case cancelled
    }

    var duration: TimeInterval? {
        guard let start = startTime else { return nil }
        let end = endTime ?? Date()
        return end.timeIntervalSince(start)
    }
}

/// Events emitted during agent task execution
enum AgentTaskEvent {
    case started(taskId: String, agentType: AgentType)
    case progress(taskId: String, message: String)
    case completed(taskId: String, result: String)
    case failed(taskId: String, error: Error)
    case cancelled(taskId: String)
}
