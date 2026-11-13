//
//  LangTools+ToolRouter.swift
//  LangTools
//
//  A fast classifier that scores the tools a message might need before the
//  language model sees it, so the model only receives the plausible ones.
//

import Foundation

/// One tool a router can score.
public struct ToolRoutingOption: Equatable, Sendable {
    public let name: String
    public let description: String

    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }
}

/// How likely a router thinks each tool is for one message.
public struct ToolRoutingDecision: Equatable, Sendable {
    /// Each offered tool's probability, from 0 to 1. Whatever is left over is the
    /// chance that the message needs no tool.
    public let toolProbabilities: [String: Double]

    public init(toolProbabilities: [String: Double]) {
        self.toolProbabilities = toolProbabilities
    }
}

/// Scores the tools a user message might need. A router only scores; the language
/// model still chooses among what it receives, and writes the arguments and reply.
public protocol LangToolsToolRouter: Sendable {
    func route(message: String, options: [ToolRoutingOption]) async throws -> ToolRoutingDecision
}
