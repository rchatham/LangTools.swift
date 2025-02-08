//
//  Agents.swift
//  LangTools
//
//  Created by Reid Chatham on 2/5/25.
//

import LangTools

public protocol Agent {
    var name: String { get }
    var description: String { get }
    var instructions: String { get }

    associatedtype LangTool: LangTools
    var langTool: LangTool { get }
    var model: LangTool.Model { get }
    var tools: [Tool]? { get }
    var delegateAgents: [any Agent] { get }

    func execute(context: AgentContext) async throws -> String
}

public struct AgentContext {
    public var messages: [any LangToolsMessage]

    public init(messages: [any LangToolsMessage]) {
        self.messages = messages
    }
}

extension Agent {
    public func execute(context: AgentContext) async throws -> String {
        let tools = delegateAgents.isEmpty ? tools : (tools ?? []) + [Tool(
            name: "agent_transfer",
            description: "Transfer the conversation to another agent",
            tool_schema: .init(
                properties: [
                    "agent_name": .init(
                        type: "string",
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
                guard let agentName = args["agent_name"] as? String,
                      let reason = args["reason"] as? String,
                      let agent = self.delegateAgents.first(where: { $0.name == agentName })
                else { return nil }
                var messages = context.messages
                messages.append(LangToolsMessageImpl<LangToolsTextContent>(role: .system, string: "You are a delegate agent of \(name), given the following reason provided in the next message from \(name), perform your function and respond back with your answer."))
                messages.append(LangToolsMessageImpl<LangToolsTextContent>(role: .user, string: reason)) // TODO: - Should this be a user or assistant message.
                let context = AgentContext(messages: messages)
                do {
                    return try await agent.execute(context: context)
                } catch {
                    return "error: " + error.localizedDescription
                }
            }
        )]
        let systemMessage = langTool.systemMessage(createSystemPrompt())
        do {
            let request = try langTool.chatRequest(model: model, messages: [systemMessage] + context.messages, tools: tools)
            let response = try await langTool.perform(request: request)
            return response.message?.content.text ?? "failed to return text content"
        } catch {
            return "error: " + error.localizedDescription
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
        }

        return prompt
    }
}
