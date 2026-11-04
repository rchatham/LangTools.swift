//
//  SubagentService.swift
//  AgentDeploy
//
//  Subagents defined in files and run on workers for another process, such as the
//  LangTools Helper serving the sandboxed app. The app sends a task and polls for the
//  result; the definitions, keys and Docker access stay with the helper.
//

import Foundation
import AgentRuntime
import HelperLink

/// A subagent definition file: what `WorkerSubagent` takes, as JSON.
///
/// ```json
/// {
///   "toolName": "research",
///   "description": "Researches a question and answers with sources.",
///   "worker": "helper",
///   "timeoutSeconds": 600,
///   "spec": { "name": "Researcher", "instructions": "...", "provider": "anthropic", "model": "claude-sonnet-4-6" }
/// }
/// ```
///
/// The spec needs no messages; the task arrives at run time.
public struct SubagentDefinition: Codable, Equatable {
    public var toolName: String
    public var description: String?
    public var worker: String
    public var owner: String?
    public var timeoutSeconds: Double?
    public var spec: AgentSpec

    public init(toolName: String, description: String? = nil, worker: String, owner: String? = nil, timeoutSeconds: Double? = nil, spec: AgentSpec) {
        self.toolName = toolName
        self.description = description
        self.worker = worker
        self.owner = owner
        self.timeoutSeconds = timeoutSeconds
        self.spec = spec
    }

    public func subagent() throws -> WorkerSubagent {
        try WorkerSubagent(toolName: toolName, description: description, spec: spec, worker: worker, owner: owner, timeout: timeoutSeconds ?? 600)
    }
}

/// The `*.json` subagent definitions in a directory, read fresh on every call so edits
/// take effect without a restart.
public struct SubagentCatalog {
    public var directory: URL

    public init(directory: URL) { self.directory = directory }

    /// `~/.config/langtools-agent/subagents`, next to the fleet registry.
    public static func defaultDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        FleetStore.defaultDirectory(environment: environment).appendingPathComponent("subagents", isDirectory: true)
    }

    /// Valid subagents by file name, and a line for each file that was skipped.
    public func load() -> (subagents: [WorkerSubagent], problems: [String]) {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
            .sorted()
        var subagents: [WorkerSubagent] = []
        var problems: [String] = []
        for name in names {
            do {
                let data = try Data(contentsOf: directory.appendingPathComponent(name))
                let subagent = try JSONDecoder().decode(SubagentDefinition.self, from: data).subagent()
                if subagents.contains(where: { $0.toolName == subagent.toolName }) {
                    problems.append("\(name): another file already defines '\(subagent.toolName)'.")
                } else {
                    subagents.append(subagent)
                }
            } catch {
                problems.append("\(name): \(Self.describe(error))")
            }
        }
        return (subagents, problems)
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, _): return "missing '\(key.stringValue)'."
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context), DecodingError.dataCorrupted(let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? "not valid JSON." : "invalid '\(path)': \(context.debugDescription)"
        default: return error.localizedDescription
        }
    }
}

/// Runs catalog subagents on workers: start a run, then poll its status.
public final class SubagentService: @unchecked Sendable {  // Immutable after init.
    public let catalog: SubagentCatalog
    private let fleet: AgentFleet

    public init(catalog: SubagentCatalog, fleet: AgentFleet) {
        self.catalog = catalog
        self.fleet = fleet
    }

    /// The service a helper on this Mac uses: the default fleet registry and catalog,
    /// with the usual places Docker and Homebrew install their commands on the search
    /// path, since an app started from Finder gets only the system's.
    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> SubagentService {
        let directory = FleetStore.defaultDirectory(environment: environment)
        let home = environment["HOME"] ?? NSHomeDirectory()
        let runner = ProcessCommandRunner(extraSearchPaths: ProcessCommandRunner.commonToolDirectories(home: home))
        let fleet = AgentFleet(store: FleetStore(file: directory.appendingPathComponent("fleet.json")), runner: runner)
        return SubagentService(catalog: SubagentCatalog(directory: SubagentCatalog.defaultDirectory(environment: environment)), fleet: fleet)
    }

    public func list() -> HelperSubagentsResponse {
        let (subagents, problems) = catalog.load()
        return HelperSubagentsResponse(
            subagents: subagents.map { HelperSubagent(toolName: $0.toolName, description: $0.description, worker: $0.worker, timeoutSeconds: $0.timeout) },
            problems: problems
        )
    }

    public func start(_ request: HelperSubagentRunRequest) async throws -> HelperSubagentRunResponse {
        let subagent = try subagent(named: request.toolName)
        guard !request.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DeployError.invalidArgument("A task is required.") }
        let job = subagent.job(task: request.task, context: request.context?.isEmpty == true ? nil : request.context)
        try await fleet.submit(job, to: subagent.worker)
        return HelperSubagentRunResponse(runID: job.runID)
    }

    public func status(_ request: HelperSubagentStatusRequest) async throws -> HelperSubagentStatusResponse {
        let subagent = try subagent(named: request.toolName)
        let status = try await fleet.status(of: request.runID, on: subagent.worker)
        switch status.state {
        case .queued: return HelperSubagentStatusResponse(runID: request.runID, state: .queued)
        case .running: return HelperSubagentStatusResponse(runID: request.runID, state: .running)
        case .done:
            guard let result = status.result else { throw DeployError.unexpectedOutput("Worker '\(subagent.worker)' reported run \(request.runID) done without a result.") }
            return HelperSubagentStatusResponse(runID: request.runID, state: .done, output: subagent.message(for: result))
        case .unknown:
            throw DeployError.invalidArgument("Worker '\(subagent.worker)' has no run '\(request.runID)'.")
        }
    }

    private func subagent(named toolName: String) throws -> WorkerSubagent {
        guard let subagent = catalog.load().subagents.first(where: { $0.toolName == toolName }) else {
            throw DeployError.invalidArgument("No subagent named '\(toolName)'. Definitions are read from \(catalog.directory.path).")
        }
        return subagent
    }
}
