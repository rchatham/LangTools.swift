//
//  AgentSerializationService.swift
//  LangTools
//
//  Created by Claude on 2025.
//

import Foundation
import LangTools
import Agents

/// Service for serializing and deserializing agents for cloud deployment
public final class AgentSerializationService: Sendable {
    public init() {}

    /// Serializes an agent definition into a base64 encoded string
    public func serializeAgent(
        _ agent: any Agent,
        provider: AIProvider,
        model: String,
        apiKey: String,
        messages: [SerializableAgentDefinition.SerializableMessage] = []
    ) throws -> String {
        let toolDefinitions = agent.tools?.map { tool in
            SerializableAgentDefinition.SerializableToolDefinition(
                name: tool.name,
                description: tool.description,
                schema: serializeToolSchema(tool),
                required: nil // Could be extracted from tool_schema.required
            )
        }

        let definition = SerializableAgentDefinition(
            name: agent.name,
            description: agent.description,
            instructions: agent.instructions,
            provider: provider,
            model: model,
            apiKey: apiKey,
            messages: messages,
            tools: toolDefinitions
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(definition)
        return data.base64EncodedString()
    }

    /// Deserializes an agent definition from a base64 encoded string
    public func deserializeAgent(_ serialized: String) throws -> SerializableAgentDefinition {
        guard let data = Data(base64Encoded: serialized) else {
            throw CloudAgentError.serializationFailed("Invalid base64 string")
        }

        do {
            return try JSONDecoder().decode(SerializableAgentDefinition.self, from: data)
        } catch {
            throw CloudAgentError.serializationFailed("Failed to decode agent definition: \(error.localizedDescription)")
        }
    }

    /// Serializes messages for cloud deployment
    public func serializeMessages(_ messages: [any LangToolsMessage]) -> [SerializableAgentDefinition.SerializableMessage] {
        messages.compactMap { message in
            SerializableAgentDefinition.SerializableMessage(
                role: message.role.rawValue,
                content: message.content.text ?? ""
            )
        }
    }

    /// Creates a runtime configuration for cloud deployment
    public func createRuntimeConfiguration(
        agent: any Agent,
        provider: AIProvider,
        model: String,
        apiKey: String,
        messages: [any LangToolsMessage] = [],
        deviceToken: String? = nil,
        encryptionKey: String,
        maxExecutionTime: TimeInterval = 3600,
        scheduledExecution: Date? = nil,
        callbackURL: String? = nil
    ) throws -> RuntimeConfiguration {
        let serializedMessages = serializeMessages(messages)
        let agentDefinition = try serializeAgent(
            agent,
            provider: provider,
            model: model,
            apiKey: apiKey,
            messages: serializedMessages
        )

        return RuntimeConfiguration(
            agentName: agent.name,
            agentDefinition: agentDefinition,
            deviceToken: deviceToken,
            encryptionKey: encryptionKey,
            maxExecutionTime: maxExecutionTime,
            scheduledExecution: scheduledExecution,
            callbackURL: callbackURL
        )
    }

    // MARK: - Private Helpers

    private func serializeToolSchema(_ tool: any LangToolsTool) -> [String: SerializableAgentDefinition.SerializableToolDefinition.SerializableProperty] {
        // Convert tool schema properties to serializable format
        var result: [String: SerializableAgentDefinition.SerializableToolDefinition.SerializableProperty] = [:]

        // Access the properties through the protocol
        let properties = tool.tool_schema.properties
        for (key, value) in properties {
            result[key] = SerializableAgentDefinition.SerializableToolDefinition.SerializableProperty(
                type: value.type,
                enumValues: value.enumValues,
                description: value.description
            )
        }

        return result
    }
}

// MARK: - Helper Extension

extension AIProvider {
    /// Determines the AI provider from a LangTools instance type name
    public static func from(langToolTypeName: String) -> AIProvider {
        let typeName = langToolTypeName.lowercased()

        if typeName.contains("openai") {
            return .openAI
        } else if typeName.contains("anthropic") {
            return .anthropic
        } else if typeName.contains("gemini") {
            return .gemini
        } else if typeName.contains("xai") {
            return .xAI
        } else if typeName.contains("ollama") {
            return .ollama
        }

        return .anthropic // Default
    }
}
