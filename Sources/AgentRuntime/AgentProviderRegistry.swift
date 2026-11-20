//
//  AgentProviderRegistry.swift
//  AgentRuntime
//
//  Maps a spec's provider ID to code that builds the provider client and its model.
//  `AgentRuntimeProviders` registers the providers that ship with LangTools; a custom
//  runtime can register its own.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LangTools

/// What a provider factory receives when building a client for one run.
public struct ProviderConfiguration {
    /// Nil when `ProviderRegistration.requiresAPIKey` is false and no key was found.
    public var apiKey: String?
    /// The spec's `baseURL`; nil keeps the provider's default.
    public var baseURL: URL?
    public var session: URLSession

    public init(apiKey: String?, baseURL: URL? = nil, session: URLSession = URLSession(configuration: .default)) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
    }

    /// The API key, or the error a provider that needs one should throw.
    public func requireAPIKey(for id: LangToolsProviderID) throws -> String {
        guard let apiKey, !apiKey.isEmpty else { throw AgentRuntimeError.missingCredential(provider: id.rawValue, environmentVariable: nil) }
        return apiKey
    }
}

public struct ProviderRegistration {
    public var id: LangToolsProviderID
    public var displayName: String
    /// Where `AgentCredentials.environment` looks for this provider's key.
    public var apiKeyEnvironmentVariable: String?
    /// False for providers such as a local Ollama daemon that work without a key.
    public var requiresAPIKey: Bool
    public var makeClient: (ProviderConfiguration) throws -> any LangTools
    /// Returns nil when the provider does not recognize the model ID.
    public var makeModel: (String) -> (any RawRepresentable)?

    public init(
        id: LangToolsProviderID,
        displayName: String,
        apiKeyEnvironmentVariable: String?,
        requiresAPIKey: Bool = true,
        makeClient: @escaping (ProviderConfiguration) throws -> any LangTools,
        makeModel: @escaping (String) -> (any RawRepresentable)?
    ) {
        self.id = id
        self.displayName = displayName
        self.apiKeyEnvironmentVariable = apiKeyEnvironmentVariable
        self.requiresAPIKey = requiresAPIKey
        self.makeClient = makeClient
        self.makeModel = makeModel
    }
}

public struct AgentProviderRegistry {
    private var registrations: [LangToolsProviderID: ProviderRegistration] = [:]

    public init(_ registrations: [ProviderRegistration] = []) {
        for registration in registrations { register(registration) }
    }

    /// Replaces any registration with the same ID.
    public mutating func register(_ registration: ProviderRegistration) {
        registrations[registration.id] = registration
    }

    public func registration(for id: LangToolsProviderID) -> ProviderRegistration? { registrations[id] }

    public var all: [ProviderRegistration] { registrations.values.sorted { $0.id.rawValue < $1.id.rawValue } }

    func resolve(_ id: LangToolsProviderID) throws -> ProviderRegistration {
        guard let registration = registrations[id] else {
            throw AgentRuntimeError.unknownProvider(id.rawValue, available: all.map(\.id.rawValue))
        }
        return registration
    }
}

/// Supplies API keys to the runner. Keys never appear in an `AgentSpec`.
public struct AgentCredentials {
    private let lookup: (ProviderRegistration) -> String?

    public init(_ lookup: @escaping (ProviderRegistration) -> String?) {
        self.lookup = lookup
    }

    public func apiKey(for registration: ProviderRegistration) -> String? {
        lookup(registration).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Reads each provider's `apiKeyEnvironmentVariable`.
    public static func environment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> AgentCredentials {
        AgentCredentials { registration in registration.apiKeyEnvironmentVariable.flatMap { environment[$0] } }
    }

    public static func keys(_ keys: [LangToolsProviderID: String]) -> AgentCredentials {
        AgentCredentials { keys[$0.id] }
    }
}
