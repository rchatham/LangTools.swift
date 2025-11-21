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

    var tools: [any LangToolsTool]? { get }
    var delegateAgents: [any Agent] { get }
}

public struct AgentContext{
    public var langTool: any LangTools
    public var model: any RawRepresentable

    public var messages: [any LangToolsMessage]
    public var eventHandler: (AgentEvent) -> Void
    public var parent: (any Agent)?
    public var tools: [any LangToolsTool]?

    public init<LangTool: LangTools>(
        langTool: LangTool, model: LangTool.Model,
        messages: [any LangToolsMessage],
        eventHandler: @escaping (AgentEvent) -> Void, parent: (any Agent)? = nil,
        tools: [any LangToolsTool]? = nil
    ) {
        self.init(langTool: langTool, model: model, messages: messages, eventHandler: eventHandler, parent: parent, tools: tools)
    }

    public init(
        langTool: any LangTools,
        model: any RawRepresentable,
        messages: [any LangToolsMessage],
        eventHandler: @escaping (AgentEvent) -> Void, parent: Agent?,
        tools: [any LangToolsTool]?
    ) {
        self.langTool = langTool
        self.model = model
        self.messages = messages
        self.eventHandler = eventHandler
        self.parent = parent
        self.tools = tools
    }
}

public enum AgentEvent: Equatable {
    case started(agent: String, parent: String?, task: String)
    case agentTransfer(from: String, to: String, reason: String)
    case agentHandoff(from: String, to: String, reason: String)
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
        case .agentHandoff(let from, let to, let reason):
            return "🤝 Agent '\(from)' handed off to '\(to)': \(reason)"
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
        var tools = delegateAgents.isEmpty ? tools : (tools ?? []) + [Tool(
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
                context.messages.append(context.langTool.systemMessage("You are a delegate agent of \(name), given the following reason provided from \(name), perform your function and respond back with your answer. Assume that if you do no have a tool to complete a task that it is \(name)'s responsibility to handle it further."))
                // This next messages must be a user message for use with Anthropic, an assistant message will constrain the result to be a completion of the current message and may provide unexpected results. https://docs.anthropic.com/en/api/messages#:~:text=If%20the%20final%20message%20uses%20the%20assistant%20role%2C%20the%20response%20content%20will%20continue%20immediately%20from%20the%20content%20in%20that%20message.%20This%20can%20be%20used%20to%20constrain%20part%20of%20the%20model's%20response.
                context.messages.append(context.langTool.systemMessage(reason)) // TODO: - decide if this should be wrapped into the previous system message
                do { return try await agent.execute(context: context) }
                catch { throw AgentError("error: " + error.localizedDescription) }
            }
        )]
        if let extraTools = context.tools, !extraTools.isEmpty {
            tools = (tools ?? []) + extraTools
        }
        let toolEventHandler: (LangToolsToolEvent) -> Void = { [name] event in
            switch event {
            case .toolCalled(let toolCall):
                context.eventHandler(.toolCalled(agent: name, tool: toolCall.name ?? "no_tool_name", arguments: toolCall.arguments))

            case .toolCompleted(let toolResult):
                if toolResult?.is_error ?? false { context.eventHandler(.error(agent: name, message: toolResult?.result ?? "No tool result returned.")) }
                else { context.eventHandler(.toolCompleted(agent: name, result: toolResult?.result)) }
            }
        }
        do {
//            print("AGENT \(name) SENDING: \([systemMessage] + context.messages)")
            let systemMessage = context.langTool.systemMessage(createSystemPrompt())
            let request = try context.langTool.chatRequest(model: context.model, messages: [systemMessage] + context.messages, tools: tools, toolEventHandler: toolEventHandler)
            let response = try await context.langTool.perform(request: request) as any LangToolsChatResponse
            guard let result = response.message?.content.string, !result.isEmpty else {
                context.eventHandler(.error(agent: name, message: "Empty result received"))
                throw AgentError("agent: \(name) - error: Failed to return text content")
            }
            context.eventHandler(.completed(agent: name, result: result))
            return result
        } catch {
            context.eventHandler(.completed(agent: name, result: error.localizedDescription, is_error: true))
            throw AgentError("agent: \(name) - error: " + error.localizedDescription)
        }
    }

    /// Creates system prompt from agent configuration
    fileprivate func createSystemPrompt() -> String {
        var prompt = "You are an AI assistant named \(name)."
        prompt += "\nRole: \(description)"
        prompt += "\n\nInstructions:\n\(instructions)"
        prompt += "\n\nAlways return a reponse no matter what."

        if let tools, !tools.isEmpty {
            prompt += "\n\nAvailable Tools:"
            for tool in tools { prompt += "\n- \(tool.name): \(tool.description ?? "")" }
        }

        if !delegateAgents.isEmpty {
            prompt += "\n\nYou can transfer to these agents:"
            for agent in delegateAgents { prompt += "\n- \(agent.name): \(agent.description)" }
        }

        if !(tools?.isEmpty ?? true) || !delegateAgents.isEmpty {
            prompt += """
                \n\nYou should relay all the critical details from your tools and delegate agents,
                the user will not have access to the tool or delegate agent's response. Your answer should
                be specific and comprehensive, but provide only the relevant information
                to the user or parent agent.
                """
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

extension Agent {
    func convertToLangToolsTool<Tool: LangToolsTool>(parent: Agent? = nil, eventHandler: @escaping (AgentEvent) -> Void = {_ in}) -> Tool {
        Tool(agent: self, parent: parent, eventHandler: eventHandler)
    }
}

extension LangToolsTool {
    public init(agent: Agent, parent: Agent? = nil, eventHandler: @escaping (AgentEvent) -> Void) {
        self.init(name: agent.name, description: agent.description, parent: parent, eventHandler: eventHandler, callback: { _ in agent })
    }

    public init(name: String, description: String?, parent: Agent? = nil, eventHandler: @escaping (AgentEvent) -> Void, callback: @escaping ([String: JSON]) async throws -> Agent) {
        self.init(name: name, description: description, tool_schema: ToolSchema(
            type: "object",
            properties: [
                "reason": .init(type: "string", enumValues: nil, description: "The reason for delegating to the agent. This should provide any neccsary information for the agent to be able to perform it's task.")
            ],
            required: ["reason"])) { info, args in
            guard let request = args["reason"]?.stringValue else { return "Invalid research request" }
            let context = AgentContext(langTool: info.langTool, model: info.model, messages: info.messages + [info.langTool.userMessage(request)], eventHandler: eventHandler, parent: parent, tools: nil)
            return try await callback(args).execute(context: context)
        }
    }
}
