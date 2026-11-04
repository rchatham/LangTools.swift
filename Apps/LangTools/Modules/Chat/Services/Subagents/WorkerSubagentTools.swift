//
//  WorkerSubagentTools.swift
//  Chat
//
//  Subagents that run on langtools-agent workers, offered to the chat model as tools.
//  The app is sandboxed and can't run docker or ssh, so the paired LangTools Helper
//  owns the subagent definitions and runs them; the app lists them, starts a run with
//  the model's task and polls for the result.
//

import Foundation
import LangTools
import OpenAI
import ToolKit
import HelperLink

#if canImport(Combine)
import Combine
#endif

public protocol HelperSubagentClientProtocol {
    func listSubagents() async throws -> HelperSubagentsResponse
    func startSubagent(_ request: HelperSubagentRunRequest) async throws -> HelperSubagentRunResponse
    func subagentStatus(_ request: HelperSubagentStatusRequest) async throws -> HelperSubagentStatusResponse
}

public enum HelperSubagentClientError: Error, LocalizedError, Equatable {
    case notPaired
    case helper(status: Int, message: String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .notPaired: return "Pair the LangTools Helper in Settings to use worker subagents."
        case .helper(let status, let message): return "The helper returned \(status): \(message)"
        case .invalidResponse: return "The helper's response wasn't understood."
        }
    }
}

/// Talks to the paired LangTools Helper's subagent routes, using the same URL and token
/// as the Codex helper.
public final class HelperSubagentClient: HelperSubagentClientProtocol {
    private let configurationProvider: () -> AccountBackendConfiguration
    private let urlSession: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        configurationProvider: @escaping () -> AccountBackendConfiguration = { AccountBackendConfiguration() },
        urlSession: URLSession = LoopbackURLSession.shared
    ) {
        self.configurationProvider = configurationProvider
        self.urlSession = urlSession
    }

    public func listSubagents() async throws -> HelperSubagentsResponse {
        try await send(HelperSubagentRoute.list, body: nil as HelperSubagentRunRequest?)
    }

    public func startSubagent(_ request: HelperSubagentRunRequest) async throws -> HelperSubagentRunResponse {
        try await send(HelperSubagentRoute.run, body: request)
    }

    public func subagentStatus(_ request: HelperSubagentStatusRequest) async throws -> HelperSubagentStatusResponse {
        try await send(HelperSubagentRoute.status, body: request)
    }

    private func send<Body: Encodable, Response: Decodable>(_ path: String, body: Body?) async throws -> Response {
        let route: AccountBackendRoute
        do { route = try configurationProvider().codexHelperRoute() } catch { throw HelperSubagentClientError.notPaired }
        var request = URLRequest(url: route.endpoint(path))
        request.setValue("Bearer \(route.credential.value)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(body)
        } else {
            request.httpMethod = "GET"
        }
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HelperSubagentClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? decoder.decode(HelperErrorPayload.self, from: data).error) ?? "no details"
            throw HelperSubagentClientError.helper(status: http.statusCode, message: message)
        }
        do { return try decoder.decode(Response.self, from: data) } catch { throw HelperSubagentClientError.invalidResponse }
    }
}

/// Registers the helper's subagents as tools and runs them when the model calls one.
@MainActor
public final class WorkerSubagentTools: ObservableObject {
    public static let shared = WorkerSubagentTools()

    /// The subagents registered by the last refresh.
    @Published public private(set) var subagents: [HelperSubagent] = []
    /// What the last refresh found, for Settings: an error, or the helper's skipped files.
    @Published public private(set) var problems: [String] = []
    @Published public private(set) var isRefreshing = false

    private let client: HelperSubagentClientProtocol
    private let toolManager: ToolManager
    private let pollInterval: TimeInterval
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    /// The display names of the tools this registered, by id, to tell them from other tools.
    private var registered: [String: String] = [:]

    public init(
        client: HelperSubagentClientProtocol = HelperSubagentClient(),
        toolManager: ToolManager? = nil,
        pollInterval: TimeInterval = 2,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) {
        self.client = client
        self.toolManager = toolManager ?? .shared
        self.pollInterval = pollInterval
        self.sleep = sleep
    }

    /// Asks the helper for its subagents and registers each one as a tool, removing
    /// ones it no longer offers. A subagent whose name another tool has is skipped.
    public func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let response = try await client.listSubagents()
            var accepted: [HelperSubagent] = []
            var problems = response.problems
            var configurations: [ToolConfiguration] = []
            for subagent in response.subagents {
                guard !accepted.contains(where: { $0.toolName == subagent.toolName }) else {
                    problems.append("The helper listed '\(subagent.toolName)' more than once; the first is used.")
                    continue
                }
                // A tool with this name that isn't the one this registered belongs to something else.
                if let existing = toolManager.configuration(for: subagent.toolName), existing.displayName != registered[subagent.toolName] {
                    problems.append("'\(subagent.toolName)' is already the name of another tool; rename the subagent.")
                    continue
                }
                configurations.append(configuration(for: subagent))
                accepted.append(subagent)
            }
            // Subagents the helper no longer offers would fail if called, so they go.
            let current = Set(accepted.map(\.toolName))
            // Only remove tools this registered and still owns.
            let stale = registered.filter { id, name in !current.contains(id) && toolManager.configuration(for: id)?.displayName == name }
            toolManager.unregister(ids: Set(stale.keys))
            toolManager.register(configurations)
            registered = Dictionary(uniqueKeysWithValues: configurations.map { ($0.id, $0.displayName) })
            self.subagents = accepted
            self.problems = problems
        } catch {
            self.problems = [error.localizedDescription]
        }
    }

    func configuration(for subagent: HelperSubagent) -> ToolConfiguration {
        let schema = OpenAI.Tool.FunctionSchema.Parameters(
            properties: [
                "task": .init(type: "string", description: "What the subagent should do, with everything it needs to know."),
                "context": .init(type: "string", description: "Optional background, such as relevant parts of the conversation."),
            ],
            required: ["task"]
        )
        return ToolConfiguration(
            id: subagent.toolName,
            displayName: "\(subagent.toolName) (worker \(subagent.worker))",
            description: subagent.description,
            iconName: "shippingbox",
            isAgent: false,
            callback: { [client, pollInterval, sleep] args in
                guard let task = args["task"]?.stringValue, !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return "A task is required."
                }
                return try await Self.run(subagent, task: task, context: args["context"]?.stringValue, client: client, pollInterval: pollInterval, sleep: sleep)
            },
            toolSchema: schema,
            requiredParameters: ["task"]
        )
    }

    /// Starts a run and polls until it's done. Failures come back as text for the model
    /// rather than ending the conversation; cancelling stops waiting, while the run
    /// itself continues on the worker.
    nonisolated static func run(
        _ subagent: HelperSubagent,
        task: String,
        context: String?,
        client: HelperSubagentClientProtocol,
        pollInterval: TimeInterval,
        sleep: @Sendable (TimeInterval) async throws -> Void
    ) async throws -> String {
        let runID: String
        do {
            runID = try await client.startSubagent(HelperSubagentRunRequest(toolName: subagent.toolName, task: task, context: context)).runID
        } catch {
            return "The \(subagent.toolName) subagent could not be started: \(error.localizedDescription)"
        }
        let deadline = Date().addingTimeInterval(subagent.timeoutSeconds)
        while true {
            try await sleep(pollInterval)
            do {
                let status = try await client.subagentStatus(HelperSubagentStatusRequest(toolName: subagent.toolName, runID: runID))
                if status.state == .done { return status.output ?? "" }
            } catch {
                return "Lost track of the \(subagent.toolName) subagent (run \(runID) on worker '\(subagent.worker)'): \(error.localizedDescription)"
            }
            if Date() >= deadline {
                return "The \(subagent.toolName) subagent did not finish in \(Int(subagent.timeoutSeconds))s (run \(runID) on worker '\(subagent.worker)'). It's still running there."
            }
        }
    }
}

#if canImport(SwiftUI) && os(macOS)
import SwiftUI

/// The Settings box listing the helper's worker subagents, with a refresh button.
public struct WorkerSubagentsSettingsBox: View {
    @ObservedObject private var tools: WorkerSubagentTools

    public init(tools: WorkerSubagentTools = .shared) {
        self.tools = tools
    }

    public var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Worker Subagents").font(.headline)
                    Spacer()
                    Button(tools.isRefreshing ? "Refreshing…" : "Refresh") {
                        Task { await tools.refresh() }
                    }
                    .disabled(tools.isRefreshing)
                }
                Text(tools.subagents.isEmpty
                     ? "None yet. Add definitions to ~/.config/langtools-agent/subagents/ on this Mac, with the LangTools Helper running."
                     : "From the LangTools Helper: \(tools.subagents.map(\.toolName).joined(separator: ", ")). Turn each on or off above.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                ForEach(tools.problems, id: \.self) { problem in
                    Text(problem).font(.caption).foregroundColor(.orange)
                }
            }
            .padding(8)
        }
        .task { if tools.subagents.isEmpty, !tools.isRefreshing { await tools.refresh() } }
    }
}
#endif
