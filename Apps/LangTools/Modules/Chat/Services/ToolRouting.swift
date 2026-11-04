//
//  ToolRouting.swift
//  Chat
//
//  Turns a router's scores into the tools one chat request receives.
//

import Foundation
import LangTools

/// How one message was routed, kept for the conversation's route trace.
public struct ToolRoutingOutcome: Equatable, Sendable {
    public struct ScoredTool: Equatable, Sendable {
        public let name: String
        public let probability: Double

        public init(name: String, probability: Double) {
            self.name = name
            self.probability = probability
        }
    }

    public enum Route: Equatable, Sendable {
        /// The model received these tools, most likely first.
        case tools([ScoredTool])
        /// The model received no tools.
        case noTool
        /// A message after a routed turn: its own plausible tools, most likely
        /// first, plus the previous turn's tools in case it replies to that turn.
        case followUp(scored: [ScoredTool], kept: [String])
        /// The router could not answer, so the model received every enabled tool.
        case routerFailed(String)
    }

    public let route: Route

    public init(route: Route) {
        self.route = route
    }

    /// One line for the transcript, such as "calendarAgent 0.93".
    public var summary: String {
        switch route {
        case .tools(let tools):
            return Self.describe(tools)
        case .noTool:
            return "no tool"
        case .followUp(let scored, let kept):
            let keptSummary = "kept \(kept.joined(separator: ", "))"
            if scored.isEmpty { return keptSummary }
            return kept.isEmpty ? Self.describe(scored) : "\(Self.describe(scored)), \(keptSummary)"
        case .routerFailed(let reason):
            return "all tools, router failed: \(reason)"
        }
    }

    private static func describe(_ tools: [ScoredTool]) -> String {
        tools.map { "\($0.name) \(String(format: "%.2f", $0.probability))" }.joined(separator: ", ")
    }
}

/// Which tools a router's scores leave in the request.
///
/// A language model given a tool may call it even when the message doesn't need
/// it, and that call can search the web or change someone's data. So a request
/// gets only the tools the router finds plausible. Too low a cutoff lets stray
/// calls through, and too high a cutoff hides a tool the message needed.
public enum ToolRoutingPolicy {
    public static let defaultMinimumProbability = 0.2

    /// How sure a router must be that a message needs no tool before a follow-up
    /// drops the previous turn's tools. d1-omni gave "thanks" and "tell me a joke"
    /// 1.00, and replies such as "no thanks" and "ok go ahead" 0.89 or less.
    public static let followUpNoToolCertainty = 0.95

    public static func outcome(
        for decision: ToolRoutingDecision,
        offered: [ToolRoutingOption],
        minimumProbability: Double = defaultMinimumProbability
    ) -> ToolRoutingOutcome {
        let scored = offered.compactMap { option in
            decision.toolProbabilities[option.name].map {
                ToolRoutingOutcome.ScoredTool(name: option.name, probability: $0)
            }
        }
        guard !scored.isEmpty else {
            return ToolRoutingOutcome(route: .routerFailed("It scored none of the offered tools."))
        }
        let plausible = scored
            .filter { $0.probability >= minimumProbability }
            .sorted { $0.probability > $1.probability }
        return ToolRoutingOutcome(route: plausible.isEmpty ? .noTool : .tools(plausible))
    }

    /// The tools a follow-up to `previous` should keep, or `nil` if it isn't one.
    /// Only tools the router chose carry forward, so kept tools expire after a turn.
    static func toolsToKeep(after previous: ToolRoutingOutcome?) -> [String]? {
        switch previous?.route {
        case .tools(let tools):
            return tools.map(\.name)
        case .followUp(let scored, _) where !scored.isEmpty:
            return scored.map(\.name)
        default:
            return nil
        }
    }

    /// A message after a routed turn may be a reply with no tool intent of its own,
    /// like "yes, do it", or a new request, like asking about the weather. Scores
    /// alone can't tell them apart, so it gets both its own tools and the kept ones.
    public static func followUpOutcome(
        for decision: ToolRoutingDecision,
        offered: [ToolRoutingOption],
        keeping kept: [String],
        minimumProbability: Double = defaultMinimumProbability,
        noToolCertainty: Double = followUpNoToolCertainty
    ) -> ToolRoutingOutcome {
        let own = outcome(for: decision, offered: offered, minimumProbability: minimumProbability)
        let scored: [ToolRoutingOutcome.ScoredTool]
        switch own.route {
        case .tools(let tools):
            scored = tools
        case .noTool:
            let noToolProbability = 1 - decision.toolProbabilities.values.reduce(0, +)
            if noToolProbability >= noToolCertainty { return own }
            scored = []
        case .followUp, .routerFailed:
            return own
        }
        let remaining = kept.filter { name in !scored.contains { $0.name == name } }
        return ToolRoutingOutcome(route: .followUp(scored: scored, kept: remaining))
    }

    static func apply(_ outcome: ToolRoutingOutcome, to tools: [Tool]) -> [Tool]? {
        switch outcome.route {
        case .tools(let scored):
            return scored.compactMap { selected in tools.first { $0.name == selected.name } }
        case .followUp(let scored, let kept):
            return (scored.map(\.name) + kept).compactMap { name in tools.first { $0.name == name } }
        case .noTool:
            return nil
        case .routerFailed:
            return tools
        }
    }
}
