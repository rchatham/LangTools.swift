//
//  AgentRunner.swift
//  AgentRuntime
//
//  Turns an `AgentSpec` into a provider client, model and `Agent`, runs it, and
//  reports the outcome as an `AgentRunResult`.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LangTools
import Agents

public struct AgentRunner {
    public var providers: AgentProviderRegistry
    public var tools: AgentToolRegistry
    public var credentials: AgentCredentials
    public var session: URLSession
    /// Receives each event as it happens, such as to stream progress to a log.
    public var onEvent: (AgentRunResult.Event) -> Void

    public init(
        providers: AgentProviderRegistry,
        tools: AgentToolRegistry = .builtIn,
        credentials: AgentCredentials = .environment(),
        session: URLSession = URLSession(configuration: .default),
        onEvent: @escaping (AgentRunResult.Event) -> Void = { _ in }
    ) {
        self.providers = providers
        self.tools = tools
        self.credentials = credentials
        self.session = session
        self.onEvent = onEvent
    }

    /// Checks everything a run needs without calling the provider: structure, provider,
    /// model, tools and credentials.
    public func validate(_ spec: AgentSpec) throws {
        _ = try prepare(spec)
    }

    /// Runs the spec. Failures are reported in the result rather than thrown, so a
    /// caller always has a result to deliver.
    public func run(_ spec: AgentSpec) async -> AgentRunResult {
        let startedAt = Date()
        let recorder = EventRecorder(onEvent: onEvent)
        func result(_ status: AgentRunResult.Status, output: String? = nil, error: String? = nil) -> AgentRunResult {
            AgentRunResult(agent: spec.name, provider: spec.provider.rawValue, model: spec.model, status: status, output: output, error: error, events: recorder.events, startedAt: startedAt, finishedAt: Date())
        }

        let prepared: Prepared
        do { prepared = try prepare(spec) }
        catch { return result(.invalid, error: error.localizedDescription) }

        let context = AgentContext(
            langTool: prepared.client,
            model: prepared.model,
            messages: spec.messages.map(\.langToolsMessage),
            eventHandler: { recorder.record($0) },
            parent: nil,
            tools: nil,
            // Each SpecAgent carries its own schema; one set here would leak into delegates.
            responseSchema: nil
        )

        do {
            let output = try await withTimeout(spec.timeoutSeconds) { try await prepared.agent.execute(context: context) }
            return result(.completed, output: output)
        } catch let error as AgentRuntimeError {
            if case .timedOut = error { return result(.timedOut, error: error.localizedDescription) }
            return result(.failed, error: error.localizedDescription)
        } catch {
            return result(.failed, error: error.localizedDescription)
        }
    }

    private struct Prepared {
        var client: any LangTools
        var model: any RawRepresentable
        var agent: SpecAgent
    }

    private func prepare(_ spec: AgentSpec) throws -> Prepared {
        try spec.validateStructure()
        let registration = try providers.resolve(spec.provider)
        guard let model = registration.makeModel(spec.model) else {
            throw AgentRuntimeError.unknownModel(provider: registration.id.rawValue, model: spec.model)
        }
        let agent = try SpecAgent(spec: spec, tools: tools)
        let apiKey = credentials.apiKey(for: registration)
        if registration.requiresAPIKey && apiKey == nil {
            throw AgentRuntimeError.missingCredential(provider: registration.id.rawValue, environmentVariable: registration.apiKeyEnvironmentVariable)
        }
        let client = try registration.makeClient(ProviderConfiguration(apiKey: apiKey, baseURL: spec.baseURL, session: session))
        return Prepared(client: client, model: model, agent: agent)
    }
}

/// An `Agent` built from a spec, with its tools and delegates resolved.
struct SpecAgent: Agent {
    let name: String
    let description: String
    let instructions: String
    let tools: [any LangToolsTool]?
    let delegateAgents: [any Agent]
    let responseSchema: JSONSchema?

    init(spec: AgentSpec, tools registry: AgentToolRegistry) throws {
        name = spec.name
        description = spec.description
        instructions = spec.instructions
        let resolved = try registry.resolve(spec.tools)
        tools = resolved.isEmpty ? nil : resolved
        delegateAgents = try spec.delegates.map { try SpecAgent(spec: $0, tools: registry) }
        responseSchema = spec.responseSchema
    }
}

private func withTimeout<T>(_ seconds: Double?, _ operation: @escaping () async throws -> T) async throws -> T {
    guard let seconds else { return try await operation() }
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw AgentRuntimeError.timedOut(seconds: seconds)
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw CancellationError() }
        return first
    }
}

private final class EventRecorder {
    private let lock = NSLock()
    private var recorded: [AgentRunResult.Event] = []
    private let onEvent: (AgentRunResult.Event) -> Void

    init(onEvent: @escaping (AgentRunResult.Event) -> Void) { self.onEvent = onEvent }

    var events: [AgentRunResult.Event] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func record(_ agentEvent: AgentEvent) {
        let event = AgentRunResult.Event(agentEvent)
        lock.lock()
        recorded.append(event)
        lock.unlock()
        onEvent(event)
    }
}

extension AgentSpec.Message {
    var langToolsMessage: any LangToolsMessage {
        let role: LangToolsRoleImpl = switch self.role {
        case .system: .system
        case .user: .user
        case .assistant: .assistant
        }
        return LangToolsMessageImpl<LangToolsTextContent>(role: role, string: content)
    }
}
