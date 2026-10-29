//
//  WorkerSubagent.swift
//  AgentDeploy
//
//  A tool that hands a task to an agent running on a worker, so an agent in an app can
//  use a subagent that runs in a container: on this machine, a server, or a droplet.
//

import Foundation
import LangTools
import AgentRuntime

/// A subagent that runs on a worker. The spec fixes what the subagent is (provider, model,
/// instructions and tools); the calling model only chooses the task, so it can't change
/// which keys or tools the worker uses.
public struct WorkerSubagent {
    /// The tool's name as the calling model sees it, such as `research`.
    public var toolName: String
    public var description: String
    /// The subagent. Its messages come first; the task is appended as a user message.
    public var spec: AgentSpec
    public var worker: String
    /// Sent with each job; required by a worker isolated for an owner.
    public var owner: String?
    /// How long to wait for the result. The job keeps running on the worker after this.
    public var timeout: TimeInterval
    public var pollInterval: TimeInterval

    public init(toolName: String, description: String? = nil, spec: AgentSpec, worker: String, owner: String? = nil, timeout: TimeInterval = 600, pollInterval: TimeInterval = 2) throws {
        guard toolName.range(of: #"^[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil else {
            throw DeployError.invalidArgument("Tool name '\(toolName)' must be 1-64 letters, digits, '_' or '-'.")
        }
        guard timeout > 0, pollInterval > 0 else { throw DeployError.invalidArgument("timeout and pollInterval must be greater than zero.") }
        try WorkerNames.validate(name: worker)
        if let owner { try WorkerNames.validate(owner: owner) }
        self.toolName = toolName
        self.description = description ?? (spec.description.isEmpty ? "Hand a task to the \(spec.name) agent." : spec.description)
        self.spec = spec
        self.worker = worker
        self.owner = owner
        self.timeout = timeout
        self.pollInterval = pollInterval
    }

    /// The job for one task: the spec with the task appended as the last user message.
    public func job(task: String, context: String? = nil) -> AgentJob {
        var spec = spec
        let content = context.map { "\(task)\n\nContext:\n\($0)" } ?? task
        spec.messages.append(.init(role: .user, content: content))
        return AgentJob(spec: spec, owner: owner)
    }

    /// Runs one task on the worker and returns text for the calling model: the subagent's
    /// output, or a description of what went wrong. It doesn't throw for failures the
    /// model can act on, so one failed subagent doesn't end the parent's run.
    public func run(task: String, context: String? = nil, on fleet: AgentFleet) async throws -> String {
        let job = job(task: task, context: context)
        do {
            try await fleet.submit(job, to: worker)
        } catch {
            return "The \(spec.name) agent could not be started: \(error.localizedDescription)"
        }
        let result: AgentRunResult
        do {
            result = try await fleet.waitForResult(of: job.runID, on: worker, pollInterval: pollInterval, timeout: timeout)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return "The \(spec.name) agent did not finish in time (run \(job.runID) on worker '\(worker)'): \(error.localizedDescription)"
        }
        switch result.status {
        case .completed: return result.output ?? ""
        default: return "The \(spec.name) agent \(result.status.rawValue): \(result.error ?? "no details")"
        }
    }

    /// The tool to give an agent. It takes `task` and an optional `context`.
    public func tool(fleet: AgentFleet) -> Tool {
        Tool(
            name: toolName,
            description: description,
            tool_schema: .init(
                properties: [
                    "task": .init(type: "string", description: "What the \(spec.name) agent should do, with everything it needs to know."),
                    "context": .init(type: "string", description: "Optional background, such as relevant parts of the conversation."),
                ],
                required: ["task"]
            ),
            callback: { _, args in
                guard let task = args["task"]?.stringValue, !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return "A task is required."
                }
                return try await run(task: task, context: args["context"]?.stringValue, on: fleet)
            }
        )
    }
}
