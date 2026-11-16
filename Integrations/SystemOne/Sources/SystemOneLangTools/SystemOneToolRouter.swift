import Foundation
import LangTools
import SystemOne
import SystemOneChat
import SystemOneD1

/// Routes messages with a System One model such as d1-omni.
///
/// Asks one choice question about the message alone: what is the user asking for?
/// Every tool is an option, described as the request it handles, and a catch-all
/// comes last for messages that need no tool. System One only scores options, so
/// the language model still writes the tool's arguments and the reply.
public struct SystemOneToolRouter: LangToolsToolRouter {
    /// The catch-all's option key. Its choice means the message needs no tool.
    public static let noToolKey = "generate_text"
    public static let noToolDescription = "Anything else: chat, thanks, a general question, or writing"

    private let decider: any ActionDecider
    private let routingDescriptions: [String: String]

    /// - Parameters:
    ///   - decider: The model to ask. `SystemOneEngine` runs in-process and
    ///     `HTTPDecider` asks `system-one serve`.
    ///   - routingDescriptions: Replacements for tool descriptions, keyed by tool
    ///     name. Descriptions written for a language model say what a tool does,
    ///     while System One routes best on the request it handles.
    public init(decider: any ActionDecider, routingDescriptions: [String: String] = [:]) {
        self.decider = decider
        self.routingDescriptions = routingDescriptions
    }

    public func route(message: String, options: [ToolRoutingOption]) async throws -> ToolRoutingDecision {
        let choices = options.map {
            ChoiceOption(key: $0.name, description: routingDescriptions[$0.name] ?? $0.description)
        } + [ChoiceOption(key: Self.noToolKey, description: Self.noToolDescription)]
        let answer = try await decider.chooseAction(
            state: .text(message),
            options: choices,
            instructions: ChatAgent.routingInstructions
        )
        var toolProbabilities: [String: Double] = [:]
        for entry in answer.probabilities where entry.key != Self.noToolKey {
            toolProbabilities[entry.key] = Double(entry.probability)
        }
        return ToolRoutingDecision(toolProbabilities: toolProbabilities)
    }
}

public extension SystemOneToolRouter {
    /// Loads d1-omni into this process. Loading verifies and copies 2.35 GB of
    /// weights, so call this away from the main actor and before routing begins.
    static func d1(
        modelFolder: URL,
        precision: D1Precision = .float32,
        routingDescriptions: [String: String] = [:]
    ) async throws -> SystemOneToolRouter {
        let engine = try await SystemOneEngine.d1(modelFolder: modelFolder, precision: precision)
        return SystemOneToolRouter(decider: engine, routingDescriptions: routingDescriptions)
    }

    /// Asks a `system-one serve` endpoint, and fails now if it cannot be reached.
    static func server(
        endpoint: URL,
        routingDescriptions: [String: String] = [:]
    ) async throws -> SystemOneToolRouter {
        let decider = HTTPDecider(endpoint: endpoint)
        _ = try await decider.chooseAction(
            state: .text("hello"),
            options: [ChoiceOption(key: "ok")],
            instructions: "Ready?"
        )
        return SystemOneToolRouter(decider: decider, routingDescriptions: routingDescriptions)
    }
}
