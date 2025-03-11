//
//  Agents.swift
//  LangTools
//
//  Created by Reid Chatham on 2/5/25.
//

import Foundation
import LangTools

// Watch out Neo, that's an agent. Sentient programs,... they're coming for you.
public protocol Agent {
    var name: String { get }
    var description: String { get }
    var instructions: String { get }

    associatedtype LangTool: LangTools
    var langTool: LangTool { get }
    var model: LangTool.Model { get }
    var tools: [any LangToolsTool]? { get }
    var delegateAgents: [any Agent] { get }

    func execute(context: AgentContext) async throws -> String
}

public struct AgentContext {
    public var messages: [any LangToolsMessage]
    public var eventHandler: (AgentEvent) -> Void
    public var parent: (any Agent)?

    public init(messages: [any LangToolsMessage], eventHandler: @escaping (AgentEvent) -> Void = {_ in}, parent: (any Agent)? = nil) {
        self.messages = messages
        self.eventHandler = eventHandler
        self.parent = parent
    }
}

public enum AgentEvent: Equatable {
    case started(agent: String, parent: String?, task: String)
    case agentTransfer(from: String, to: String, reason: String)
    case toolCalled(agent: String, tool: String, arguments: String)
    case toolCompleted(agent: String, result: String?)
    case completed(agent: String, result: String, is_error: Bool = false)
    case error(agent: String, message: String)

    public var description: String {
        switch self {
        case .started(let agent, let parent, let task):
            let parentString = parent == nil ? "" : "parent: " + parent!
            return "🤖 Agent '\(agent):\(parentString)' started: \(task)"
        case .agentTransfer(let from, let to, let reason):
            return "🔄 Agent '\(from)' delegated to '\(to)': \(reason)"
        case .toolCalled(let agent, let tool, let args):
            return "🛠️ Agent '\(agent)' using tool: \(tool), arguments: \(args)"
        case .toolCompleted(let agent, let tool):
            return "✅ Agent '\(agent)' completed tool: \(tool)"
        case .completed(let agent, let result, let is_error):
            return "\(is_error ? "⚠️" :"🏁") Agent '\(agent)' \(is_error ? "encountered an error" :"completed with result"): \(result)"
        case .error(let agent, let message):
            return "‼️ Agent '\(agent)' error: \(message)"
        }
    }
}

extension Agent {
    public func execute(context: AgentContext) async throws -> String {
        context.eventHandler(.started(agent: name, parent: context.parent?.name, task: context.messages.last?.content.text ?? "Unknown task"))
        let tools = delegateAgents.isEmpty ? tools : (tools ?? []) + [Tool(
            name: "agent_transfer",
            description: "Transfer the task to another agent. Be specific and explicit in your directions, direct them only to do what you need them to do.",
            tool_schema: .init(
                properties: [
                    "agent_name": .init(
                        type: "string",
                        enumValues: (delegateAgents.isEmpty ? nil : delegateAgents.map { $0.name }),
                        description: "Name of the agent to transfer to"
                    ),
                    "reason": .init(
                        type: "string",
                        description: "Reason for the transfer"
                    )
                ],
                required: ["agent_name", "reason"]
            ),
            callback: { args in
                guard let agentName = args["agent_name"]?.stringValue,
                      let reason = args["reason"]?.stringValue,
                      let agent = self.delegateAgents.first(where: { $0.name == agentName })
                else { throw AgentError("Failed to retrieve agent.") }
                context.eventHandler(.agentTransfer(from: name, to: agentName, reason: reason))
                var context = context
                context.parent = self
                context.messages.append(langTool.systemMessage("You are a delegate agent of \(name), given the following reason provided from \(name), perform your function and respond back with your answer. Assume that if you do no have a tool to complete a task that it is \(name)'s responsibility to handle it further."))
                context.messages.append(langTool.assistantMessage(reason))
                do {
                    return try await agent.execute(context: context)
                } catch {
                    throw AgentError("error: " + error.localizedDescription)
                }
            }
        )]
        let systemMessage = langTool.systemMessage(createSystemPrompt())
        let toolEventHandler: (LangToolsToolEvent) -> Void = { [name] event in
            switch event {
            case .toolCalled(let toolCall):
                context.eventHandler(.toolCalled(agent: name, tool: toolCall.name ?? "no_tool_name", arguments: toolCall.arguments))

            case .toolCompleted(let toolResult):
                if toolResult?.is_error ?? false {
                    context.eventHandler(.error(agent: name, message: toolResult?.result ?? "No tool result returned."))
                } else {
                    context.eventHandler(.toolCompleted(agent: name, result: toolResult?.result))
                }
            }
        }
        do {
            let request = try LangTool.chatRequest(model: model, messages: [systemMessage] + context.messages, tools: tools, toolEventHandler: toolEventHandler)
            let response = try await langTool.perform(request: request) as any LangToolsChatResponse
            let result = response.message?.content.text ?? ""
            if result.isEmpty {
                context.eventHandler(.error(agent: name, message: "Empty result received"))
                throw AgentError("Failed to return text content")
            }
            context.eventHandler(.completed(agent: name, result: result))
            return result
        } catch {
            context.eventHandler(.completed(agent: name, result: error.localizedDescription, is_error: true))
            throw AgentError("error: " + error.localizedDescription)
        }
    }

    /// Creates system prompt from agent configuration
    fileprivate func createSystemPrompt() -> String {
        var prompt = "You are an AI assistant named \(name)."
        prompt += "\nRole: \(description)"
        prompt += "\n\nInstructions:\n\(instructions)"

        if let tools, !tools.isEmpty {
            prompt += "\n\nAvailable Tools:"
            for tool in tools {
                prompt += "\n- \(tool.name): \(tool.description ?? "")"
            }
        }

        if !delegateAgents.isEmpty {
            prompt += "\n\nYou can transfer to these agents:"
            for agent in delegateAgents {
                prompt += "\n- \(agent.name): \(agent.description)"
            }
            prompt += "\n\nAlways return a reponse no matter what. You should relay all the critical details from your delegate agents, the user will not have access to the agent's response. Your answer should be specific and comprehensive, but provide only the relevant information to the user or parent agent."
        }
        prompt += "\n\nCurrent time: \(Date().description(with: .current))"
        return prompt
    }
}

public struct AgentError: Error, LocalizedError {
    var message: String
    public var errorDescription: String? { message }
    public init(_ message: String) {
        self.message = message
    }
}
