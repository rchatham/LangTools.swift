//
//  AgentRunResult.swift
//  AgentRuntime
//

import Foundation
import Agents

public struct AgentRunResult: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// The agent returned an answer.
        case completed
        /// The provider or a tool failed during the run.
        case failed
        /// The run hit the spec's `timeoutSeconds`.
        case timedOut
        /// The spec could not be run: bad structure, unknown provider, model or tool, or no API key.
        case invalid
    }

    /// Set by whoever started the run, so a webhook receiver can match the result to its request.
    public var runID: String?
    public var agent: String
    public var provider: String
    public var model: String
    public var status: Status
    public var output: String?
    public var error: String?
    public var events: [Event]
    public var startedAt: Date
    public var finishedAt: Date

    public var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }

    public init(runID: String? = nil, agent: String, provider: String, model: String, status: Status, output: String? = nil, error: String? = nil, events: [Event] = [], startedAt: Date, finishedAt: Date) {
        self.runID = runID
        self.agent = agent
        self.provider = provider
        self.model = model
        self.status = status
        self.output = output
        self.error = error
        self.events = events
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    /// A Codable record of an `AgentEvent`.
    public struct Event: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable {
            case started, transfer, handoff, toolCalled, toolCompleted, completed, error
        }

        public var kind: Kind
        public var agent: String
        /// The other agent, for `transfer` and `handoff`.
        public var target: String?
        /// The tool name, for `toolCalled`.
        public var tool: String?
        /// The task, reason, tool arguments, tool result, answer or error message.
        public var detail: String?
        public var isError: Bool
        public var date: Date

        public init(kind: Kind, agent: String, target: String? = nil, tool: String? = nil, detail: String? = nil, isError: Bool = false, date: Date = Date()) {
            self.kind = kind
            self.agent = agent
            self.target = target
            self.tool = tool
            self.detail = detail
            self.isError = isError
            self.date = date
        }

        init(_ event: AgentEvent, date: Date = Date()) {
            switch event {
            case .started(let agent, _, let task):
                self.init(kind: .started, agent: agent, detail: task, date: date)
            case .agentTransfer(let from, let to, let reason):
                self.init(kind: .transfer, agent: from, target: to, detail: reason, date: date)
            case .agentHandoff(let from, let to, let reason):
                self.init(kind: .handoff, agent: from, target: to, detail: reason, date: date)
            case .toolCalled(let agent, let tool, let arguments):
                self.init(kind: .toolCalled, agent: agent, tool: tool, detail: arguments, date: date)
            case .toolCompleted(let agent, let result):
                self.init(kind: .toolCompleted, agent: agent, detail: result, date: date)
            case .completed(let agent, let result, let isError):
                self.init(kind: .completed, agent: agent, detail: result, isError: isError, date: date)
            case .error(let agent, let message):
                self.init(kind: .error, agent: agent, detail: message, isError: true, date: date)
            }
        }
    }
}

extension AgentRunResult {
    public func encoded(prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(from data: Data) throws -> AgentRunResult {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AgentRunResult.self, from: data)
    }
}
