import Foundation

// Requests and responses between the app and the helper for subagents that run on
// langtools-agent workers. The helper owns the definitions and runs the jobs; the
// sandboxed app only sees names, descriptions and results.

/// A subagent the helper can run, as the app shows it.
public struct HelperSubagent: Codable, Equatable, Sendable {
    /// The tool name the calling model uses, such as `research`.
    public let toolName: String
    public let description: String
    /// The worker that runs it.
    public let worker: String
    /// How long the app should wait for a result.
    public let timeoutSeconds: Double

    public init(toolName: String, description: String, worker: String, timeoutSeconds: Double) {
        self.toolName = toolName
        self.description = description
        self.worker = worker
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct HelperSubagentsResponse: Codable, Equatable, Sendable {
    public let subagents: [HelperSubagent]
    /// Definition files the helper skipped, with the reason, so they can be fixed.
    public let problems: [String]

    public init(subagents: [HelperSubagent], problems: [String] = []) {
        self.subagents = subagents
        self.problems = problems
    }
}

public struct HelperSubagentRunRequest: Codable, Equatable, Sendable {
    public let toolName: String
    public let task: String
    public let context: String?

    public init(toolName: String, task: String, context: String? = nil) {
        self.toolName = toolName
        self.task = task
        self.context = context
    }
}

public struct HelperSubagentRunResponse: Codable, Equatable, Sendable {
    public let runID: String

    public init(runID: String) { self.runID = runID }
}

public struct HelperSubagentStatusRequest: Codable, Equatable, Sendable {
    public let toolName: String
    public let runID: String

    public init(toolName: String, runID: String) {
        self.toolName = toolName
        self.runID = runID
    }
}

public struct HelperSubagentStatusResponse: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case queued, running, done
    }

    public let runID: String
    public let state: State
    /// Text for the calling model once `state` is `done`: the subagent's output, or
    /// a description of what went wrong.
    public let output: String?

    public init(runID: String, state: State, output: String? = nil) {
        self.runID = runID
        self.state = state
        self.output = output
    }
}

/// The helper's routes for subagents. All require the helper's bearer token.
public enum HelperSubagentRoute {
    public static let list = "/v1/subagents"            // GET → HelperSubagentsResponse
    public static let run = "/v1/subagents/runs"        // POST HelperSubagentRunRequest → HelperSubagentRunResponse
    public static let status = "/v1/subagents/status"   // POST HelperSubagentStatusRequest → HelperSubagentStatusResponse
}
