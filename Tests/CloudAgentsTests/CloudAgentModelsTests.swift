//
//  CloudAgentModelsTests.swift
//  LangTools
//
//  Created by Claude on 2025.
//

import XCTest
@testable import CloudAgents

final class CloudAgentModelsTests: XCTestCase {

    // MARK: - AgentDeployment Tests

    func testAgentDeploymentCreation() {
        let deployment = AgentDeployment(
            name: "test-agent",
            dropletSize: .medium
        )

        XCTAssertFalse(deployment.id.isEmpty)
        XCTAssertEqual(deployment.name, "test-agent")
        XCTAssertEqual(deployment.status, .provisioning)
        XCTAssertEqual(deployment.dropletSize, .medium)
        XCTAssertNil(deployment.completedAt)
        XCTAssertNil(deployment.result)
    }

    func testAgentDeploymentCodable() throws {
        let deployment = AgentDeployment(
            id: "test-id",
            name: "test-agent",
            status: .running,
            dropletSize: .large,
            dropletId: 12345
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(deployment)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(AgentDeployment.self, from: data)

        XCTAssertEqual(decoded.id, deployment.id)
        XCTAssertEqual(decoded.name, deployment.name)
        XCTAssertEqual(decoded.status, deployment.status)
        XCTAssertEqual(decoded.dropletSize, deployment.dropletSize)
        XCTAssertEqual(decoded.dropletId, deployment.dropletId)
    }

    // MARK: - DeploymentStatus Tests

    func testDeploymentStatusRawValues() {
        XCTAssertEqual(DeploymentStatus.provisioning.rawValue, "Provisioning")
        XCTAssertEqual(DeploymentStatus.running.rawValue, "Running")
        XCTAssertEqual(DeploymentStatus.completed.rawValue, "Completed")
        XCTAssertEqual(DeploymentStatus.failed.rawValue, "Failed")
        XCTAssertEqual(DeploymentStatus.cancelled.rawValue, "Cancelled")
    }

    // MARK: - AgentExecutionResult Tests

    func testAgentExecutionResultCreation() {
        let result = AgentExecutionResult(
            status: .completed,
            output: "Test output",
            error: nil,
            executionTime: 120.5,
            resourceUsage: nil
        )

        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.output, "Test output")
        XCTAssertNil(result.error)
        XCTAssertEqual(result.executionTime, 120.5)
    }

    func testAgentExecutionResultWithError() {
        let result = AgentExecutionResult(
            status: .failed,
            output: nil,
            error: "Something went wrong",
            executionTime: 5.0,
            resourceUsage: nil
        )

        XCTAssertEqual(result.status, .failed)
        XCTAssertNil(result.output)
        XCTAssertEqual(result.error, "Something went wrong")
    }

    func testExecutionStatusRawValues() {
        XCTAssertEqual(AgentExecutionResult.ExecutionStatus.completed.rawValue, "completed")
        XCTAssertEqual(AgentExecutionResult.ExecutionStatus.failed.rawValue, "failed")
        XCTAssertEqual(AgentExecutionResult.ExecutionStatus.timeout.rawValue, "timeout")
        XCTAssertEqual(AgentExecutionResult.ExecutionStatus.cancelled.rawValue, "cancelled")
    }

    // MARK: - ResourceUsage Tests

    func testResourceUsageCreation() {
        let networkUsage = ResourceUsage.NetworkUsage(bytesIn: 1024, bytesOut: 2048)
        let resourceUsage = ResourceUsage(
            cpuUsage: 45.5,
            memoryUsage: 512_000_000,
            networkUsage: networkUsage
        )

        XCTAssertEqual(resourceUsage.cpuUsage, 45.5)
        XCTAssertEqual(resourceUsage.memoryUsage, 512_000_000)
        XCTAssertEqual(resourceUsage.networkUsage.bytesIn, 1024)
        XCTAssertEqual(resourceUsage.networkUsage.bytesOut, 2048)
    }

    // MARK: - AgentNotification Tests

    func testAgentNotificationCreation() {
        let result = AgentExecutionResult(
            status: .completed,
            output: "Done",
            error: nil,
            executionTime: 60.0,
            resourceUsage: nil
        )

        let notification = AgentNotification(
            agentName: "test-agent",
            result: result
        )

        XCTAssertEqual(notification.agentName, "test-agent")
        XCTAssertEqual(notification.result.status, .completed)
    }

    // MARK: - AIProvider Tests

    func testAIProviderRawValues() {
        XCTAssertEqual(AIProvider.openAI.rawValue, "openai")
        XCTAssertEqual(AIProvider.anthropic.rawValue, "anthropic")
        XCTAssertEqual(AIProvider.gemini.rawValue, "gemini")
        XCTAssertEqual(AIProvider.xAI.rawValue, "xai")
        XCTAssertEqual(AIProvider.ollama.rawValue, "ollama")
    }

    func testAIProviderCaseIterable() {
        let allProviders = AIProvider.allCases
        XCTAssertEqual(allProviders.count, 5)
    }

    func testAIProviderFromTypeName() {
        XCTAssertEqual(AIProvider.from(langToolTypeName: "OpenAI"), .openAI)
        XCTAssertEqual(AIProvider.from(langToolTypeName: "Anthropic"), .anthropic)
        XCTAssertEqual(AIProvider.from(langToolTypeName: "GeminiClient"), .gemini)
        XCTAssertEqual(AIProvider.from(langToolTypeName: "XAI"), .xAI)
        XCTAssertEqual(AIProvider.from(langToolTypeName: "OllamaClient"), .ollama)
        XCTAssertEqual(AIProvider.from(langToolTypeName: "Unknown"), .anthropic) // Default
    }

    // MARK: - RuntimeConfiguration Tests

    func testRuntimeConfigurationCreation() {
        let config = RuntimeConfiguration(
            agentName: "test-agent",
            agentDefinition: "base64encodeddata",
            deviceToken: "device-token",
            encryptionKey: "encryption-key",
            maxExecutionTime: 7200,
            callbackURL: "https://example.com/callback"
        )

        XCTAssertEqual(config.agentName, "test-agent")
        XCTAssertEqual(config.agentDefinition, "base64encodeddata")
        XCTAssertEqual(config.deviceToken, "device-token")
        XCTAssertEqual(config.encryptionKey, "encryption-key")
        XCTAssertEqual(config.maxExecutionTime, 7200)
        XCTAssertEqual(config.callbackURL, "https://example.com/callback")
    }

    func testRuntimeConfigurationDefaults() {
        let config = RuntimeConfiguration(
            agentName: "test",
            agentDefinition: "data",
            encryptionKey: "key"
        )

        XCTAssertNil(config.deviceToken)
        XCTAssertEqual(config.maxExecutionTime, 3600)
        XCTAssertNil(config.scheduledExecution)
        XCTAssertNil(config.callbackURL)
    }

    // MARK: - CloudAgentError Tests

    func testCloudAgentErrorDescriptions() {
        XCTAssertEqual(
            CloudAgentError.missingDeviceToken.errorDescription,
            "Device token is required for push notifications"
        )

        XCTAssertEqual(
            CloudAgentError.serializationFailed("invalid json").errorDescription,
            "Failed to serialize agent: invalid json"
        )

        XCTAssertEqual(
            CloudAgentError.deploymentFailed("network error").errorDescription,
            "Deployment failed: network error"
        )

        XCTAssertEqual(
            CloudAgentError.invalidResponse.errorDescription,
            "Invalid response received"
        )

        XCTAssertEqual(
            CloudAgentError.agentNotFound("my-agent").errorDescription,
            "Agent not found: my-agent"
        )
    }

    // MARK: - SerializableAgentDefinition Tests

    func testSerializableAgentDefinitionCodable() throws {
        let message = SerializableAgentDefinition.SerializableMessage(
            role: "user",
            content: "Hello"
        )

        let toolProperty = SerializableAgentDefinition.SerializableToolDefinition.SerializableProperty(
            type: "string",
            description: "A test property"
        )

        let tool = SerializableAgentDefinition.SerializableToolDefinition(
            name: "test_tool",
            description: "A test tool",
            schema: ["input": toolProperty],
            required: ["input"]
        )

        let definition = SerializableAgentDefinition(
            name: "Test Agent",
            description: "A test agent",
            instructions: "Do test things",
            provider: .anthropic,
            model: "claude-3-5-sonnet",
            apiKey: "test-key",
            messages: [message],
            tools: [tool]
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(definition)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(SerializableAgentDefinition.self, from: data)

        XCTAssertEqual(decoded.name, "Test Agent")
        XCTAssertEqual(decoded.provider, .anthropic)
        XCTAssertEqual(decoded.messages.count, 1)
        XCTAssertEqual(decoded.tools?.count, 1)
    }

    // MARK: - EncryptedNotificationPayload Tests

    func testEncryptedNotificationPayloadCreation() {
        let payload = EncryptedNotificationPayload(
            data: "encrypted-data",
            nonce: "nonce-value",
            agentId: "agent-123"
        )

        XCTAssertEqual(payload.data, "encrypted-data")
        XCTAssertEqual(payload.nonce, "nonce-value")
        XCTAssertEqual(payload.agentId, "agent-123")
    }
}
