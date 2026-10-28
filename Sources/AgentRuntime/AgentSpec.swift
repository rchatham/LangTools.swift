//
//  AgentSpec.swift
//  AgentRuntime
//
//  A serializable description of an agent run. A spec names its provider, model and
//  tools; it never carries credentials or code. The runtime resolves the provider and
//  tools by name from registries compiled into the binary that runs the spec.
//

import Foundation
import LangTools

public struct AgentSpec: Codable, Equatable, Sendable {
    /// The spec format version this runtime reads.
    public static let currentVersion = 1

    public var version: Int
    public var name: String
    public var description: String
    public var instructions: String
    /// Matches a `ProviderRegistration.id`, such as `"anthropic"` or `"openai"`.
    public var provider: LangToolsProviderID
    /// The provider's model ID, such as `"claude-sonnet-4-6"`.
    public var model: String
    /// Overrides the provider's default base URL, for a proxy or a self-hosted server.
    public var baseURL: URL?
    /// The conversation so far; the last message is normally the task.
    public var messages: [Message]
    /// Names of tools in the runtime's `AgentToolRegistry`.
    public var tools: [String]
    /// Agents this one can hand work to. They share the parent's provider and model, and
    /// their `messages`, `baseURL` and `timeoutSeconds` are ignored.
    public var delegates: [AgentSpec]
    /// Constrains the final response to JSON matching this schema, where the provider supports it.
    public var responseSchema: JSONSchema?
    /// Wall-clock limit for the whole run, including tool calls and delegates.
    public var timeoutSeconds: Double?

    public init(
        version: Int = AgentSpec.currentVersion,
        name: String,
        description: String = "",
        instructions: String,
        provider: LangToolsProviderID,
        model: String,
        baseURL: URL? = nil,
        messages: [Message],
        tools: [String] = [],
        delegates: [AgentSpec] = [],
        responseSchema: JSONSchema? = nil,
        timeoutSeconds: Double? = nil
    ) {
        self.version = version
        self.name = name
        self.description = description
        self.instructions = instructions
        self.provider = provider
        self.model = model
        self.baseURL = baseURL
        self.messages = messages
        self.tools = tools
        self.delegates = delegates
        self.responseSchema = responseSchema
        self.timeoutSeconds = timeoutSeconds
    }

    // Optional keys may be left out of hand-written specs.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? AgentSpec.currentVersion
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        instructions = try container.decode(String.self, forKey: .instructions)
        provider = try container.decode(LangToolsProviderID.self, forKey: .provider)
        model = try container.decode(String.self, forKey: .model)
        baseURL = try container.decodeIfPresent(URL.self, forKey: .baseURL)
        messages = try container.decodeIfPresent([Message].self, forKey: .messages) ?? []
        tools = try container.decodeIfPresent([String].self, forKey: .tools) ?? []
        delegates = try container.decodeIfPresent([AgentSpec].self, forKey: .delegates) ?? []
        responseSchema = try container.decodeIfPresent(JSONSchema.self, forKey: .responseSchema)
        timeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .timeoutSeconds)
    }

    public struct Message: Codable, Equatable, Sendable {
        public enum Role: String, Codable, Sendable {
            case system, user, assistant
        }

        public var role: Role
        public var content: String

        public init(role: Role, content: String) {
            self.role = role
            self.content = content
        }

        public static func user(_ content: String) -> Message { Message(role: .user, content: content) }
        public static func system(_ content: String) -> Message { Message(role: .system, content: content) }
        public static func assistant(_ content: String) -> Message { Message(role: .assistant, content: content) }
    }
}

extension AgentSpec {
    public static func decode(from data: Data) throws -> AgentSpec {
        do { return try JSONDecoder().decode(AgentSpec.self, from: data) }
        catch { throw AgentRuntimeError.invalidSpec("Could not decode spec: \(error)") }
    }

    public func encoded(prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Checks the spec's own structure. Provider, model and tool names are checked
    /// against registries by `AgentRunner.validate(_:)`.
    public func validateStructure() throws {
        guard version <= AgentSpec.currentVersion else {
            throw AgentRuntimeError.invalidSpec("Spec version \(version) is newer than this runtime supports (\(AgentSpec.currentVersion)).")
        }
        guard !model.trimmingCharacters(in: .whitespaces).isEmpty else { throw AgentRuntimeError.invalidSpec("Spec '\(name)' has no model.") }
        guard messages.contains(where: { $0.role == .user }) else {
            throw AgentRuntimeError.invalidSpec("Spec '\(name)' has no user message to act on.")
        }
        if let timeoutSeconds, !(timeoutSeconds > 0) {
            throw AgentRuntimeError.invalidSpec("Spec '\(name)' timeoutSeconds must be greater than zero.")
        }
        var names: Set<String> = []
        try validateAgentTree(names: &names)
    }

    // Delegates receive their task from the parent, so only the root needs a user message.
    private func validateAgentTree(names: inout Set<String>) throws {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { throw AgentRuntimeError.invalidSpec("An agent's name is empty.") }
        guard names.insert(name).inserted else { throw AgentRuntimeError.invalidSpec("More than one agent is named '\(name)'.") }
        for delegate in delegates {
            guard delegate.provider == provider, delegate.model == model else {
                throw AgentRuntimeError.invalidSpec("Delegate '\(delegate.name)' must use its parent's provider and model.")
            }
            try delegate.validateAgentTree(names: &names)
        }
    }

    /// Every tool name used by this spec and its delegates.
    public var allToolNames: Set<String> {
        delegates.reduce(into: Set(tools)) { $0.formUnion($1.allToolNames) }
    }
}

public enum AgentRuntimeError: Error, LocalizedError, Equatable {
    case invalidSpec(String)
    case unknownProvider(String, available: [String])
    case unknownModel(provider: String, model: String)
    case missingCredential(provider: String, environmentVariable: String?)
    case unknownTools([String], available: [String])
    case timedOut(seconds: Double)

    public var errorDescription: String? {
        switch self {
        case .invalidSpec(let message):
            return message
        case .unknownProvider(let id, let available):
            return "Unknown provider '\(id)'. Available: \(available.joined(separator: ", "))."
        case .unknownModel(let provider, let model):
            return "Provider '\(provider)' does not recognize model '\(model)'."
        case .missingCredential(let provider, let variable):
            return variable.map { "No API key for provider '\(provider)'. Set \($0)." } ?? "No API key for provider '\(provider)'."
        case .unknownTools(let names, let available):
            let list = available.isEmpty ? "none" : available.joined(separator: ", ")
            return "Unknown tool(s): \(names.joined(separator: ", ")). Available: \(list)."
        case .timedOut(let seconds):
            return "Run exceeded its \(seconds)s timeout."
        }
    }
}
