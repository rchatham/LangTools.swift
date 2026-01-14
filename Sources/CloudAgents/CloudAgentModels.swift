//
//  CloudAgentModels.swift
//  LangTools
//
//  Created by Claude on 2025.
//

import Foundation

// MARK: - Agent Deployment Models

public struct AgentDeployment: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public var status: DeploymentStatus
    public let createdAt: Date
    public var completedAt: Date?
    public let scheduledExecution: Date?
    public let dropletSize: DropletSize
    public let dropletId: Int?
    public var result: AgentExecutionResult?

    public init(
        id: String = UUID().uuidString,
        name: String,
        status: DeploymentStatus = .provisioning,
        createdAt: Date = Date(),
        completedAt: Date? = nil,
        scheduledExecution: Date? = nil,
        dropletSize: DropletSize = .small,
        dropletId: Int? = nil,
        result: AgentExecutionResult? = nil
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.scheduledExecution = scheduledExecution
        self.dropletSize = dropletSize
        self.dropletId = dropletId
        self.result = result
    }
}

public enum DeploymentStatus: String, Codable, Sendable {
    case provisioning = "Provisioning"
    case running = "Running"
    case completed = "Completed"
    case failed = "Failed"
    case cancelled = "Cancelled"
}

public enum DropletSize: String, Codable, CaseIterable, Sendable {
    case small = "s-1vcpu-1gb"
    case medium = "s-1vcpu-2gb"
    case large = "s-2vcpu-2gb"
    case xlarge = "s-2vcpu-4gb"

    public var displayName: String {
        switch self {
        case .small: return "Small (1 vCPU, 1 GB)"
        case .medium: return "Medium (1 vCPU, 2 GB)"
        case .large: return "Large (2 vCPU, 2 GB)"
        case .xlarge: return "X-Large (2 vCPU, 4 GB)"
        }
    }

    public var monthlyCost: Double {
        switch self {
        case .small: return 6.0
        case .medium: return 12.0
        case .large: return 18.0
        case .xlarge: return 24.0
        }
    }

    public var hourlyCost: Double {
        switch self {
        case .small: return 0.009
        case .medium: return 0.018
        case .large: return 0.027
        case .xlarge: return 0.036
        }
    }
}

// MARK: - Agent Execution Models

public struct AgentExecutionResult: Codable, Sendable {
    public let status: ExecutionStatus
    public let output: String?
    public let error: String?
    public let executionTime: TimeInterval
    public let resourceUsage: ResourceUsage?

    public init(
        status: ExecutionStatus,
        output: String?,
        error: String?,
        executionTime: TimeInterval,
        resourceUsage: ResourceUsage?
    ) {
        self.status = status
        self.output = output
        self.error = error
        self.executionTime = executionTime
        self.resourceUsage = resourceUsage
    }

    public enum ExecutionStatus: String, Codable, Sendable {
        case completed = "completed"
        case failed = "failed"
        case timeout = "timeout"
        case cancelled = "cancelled"
    }
}

public struct ResourceUsage: Codable, Sendable {
    public let cpuUsage: Double
    public let memoryUsage: Int64
    public let networkUsage: NetworkUsage

    public init(cpuUsage: Double, memoryUsage: Int64, networkUsage: NetworkUsage) {
        self.cpuUsage = cpuUsage
        self.memoryUsage = memoryUsage
        self.networkUsage = networkUsage
    }

    public struct NetworkUsage: Codable, Sendable {
        public let bytesIn: Int64
        public let bytesOut: Int64

        public init(bytesIn: Int64, bytesOut: Int64) {
            self.bytesIn = bytesIn
            self.bytesOut = bytesOut
        }
    }
}

// MARK: - Notification Models

public struct AgentNotification: Codable, Sendable {
    public let agentName: String
    public let result: AgentExecutionResult
    public let timestamp: Date

    public init(agentName: String, result: AgentExecutionResult, timestamp: Date = Date()) {
        self.agentName = agentName
        self.result = result
        self.timestamp = timestamp
    }
}

public struct EncryptedNotificationPayload: Codable, Sendable {
    public let data: String
    public let nonce: String
    public let agentId: String

    public init(data: String, nonce: String, agentId: String) {
        self.data = data
        self.nonce = nonce
        self.agentId = agentId
    }
}

// MARK: - Serialization Models

public struct SerializableAgentDefinition: Codable, Sendable {
    public let name: String
    public let description: String
    public let instructions: String
    public let provider: AIProvider
    public let model: String
    public let apiKey: String
    public let messages: [SerializableMessage]
    public let tools: [SerializableToolDefinition]?

    public init(
        name: String,
        description: String,
        instructions: String,
        provider: AIProvider,
        model: String,
        apiKey: String,
        messages: [SerializableMessage],
        tools: [SerializableToolDefinition]?
    ) {
        self.name = name
        self.description = description
        self.instructions = instructions
        self.provider = provider
        self.model = model
        self.apiKey = apiKey
        self.messages = messages
        self.tools = tools
    }

    public struct SerializableMessage: Codable, Sendable {
        public let role: String
        public let content: String

        public init(role: String, content: String) {
            self.role = role
            self.content = content
        }
    }

    public struct SerializableToolDefinition: Codable, Sendable {
        public let name: String
        public let description: String?
        public let schema: [String: SerializableProperty]
        public let required: [String]?

        public init(
            name: String,
            description: String?,
            schema: [String: SerializableProperty],
            required: [String]?
        ) {
            self.name = name
            self.description = description
            self.schema = schema
            self.required = required
        }

        public struct SerializableProperty: Codable, Sendable {
            public let type: String
            public let enumValues: [String]?
            public let description: String?

            public init(type: String, enumValues: [String]? = nil, description: String? = nil) {
                self.type = type
                self.enumValues = enumValues
                self.description = description
            }
        }
    }
}

public enum AIProvider: String, Codable, CaseIterable, Sendable {
    case openAI = "openai"
    case anthropic = "anthropic"
    case gemini = "gemini"
    case xAI = "xai"
    case ollama = "ollama"
}

// MARK: - Runtime Configuration

public struct RuntimeConfiguration: Codable, Sendable {
    public let agentName: String
    public let agentDefinition: String // Base64 encoded
    public let deviceToken: String?
    public let encryptionKey: String
    public let maxExecutionTime: TimeInterval
    public let scheduledExecution: Date?
    public let callbackURL: String?

    public init(
        agentName: String,
        agentDefinition: String,
        deviceToken: String? = nil,
        encryptionKey: String,
        maxExecutionTime: TimeInterval = 3600,
        scheduledExecution: Date? = nil,
        callbackURL: String? = nil
    ) {
        self.agentName = agentName
        self.agentDefinition = agentDefinition
        self.deviceToken = deviceToken
        self.encryptionKey = encryptionKey
        self.maxExecutionTime = maxExecutionTime
        self.scheduledExecution = scheduledExecution
        self.callbackURL = callbackURL
    }
}

// MARK: - Errors

public enum CloudAgentError: Error, LocalizedError {
    case missingDeviceToken
    case serializationFailed(String)
    case deploymentFailed(String)
    case invalidResponse
    case encryptionFailed(String)
    case decryptionFailed(String)
    case configurationError(String)
    case agentNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .missingDeviceToken:
            return "Device token is required for push notifications"
        case .serializationFailed(let reason):
            return "Failed to serialize agent: \(reason)"
        case .deploymentFailed(let reason):
            return "Deployment failed: \(reason)"
        case .invalidResponse:
            return "Invalid response received"
        case .encryptionFailed(let reason):
            return "Encryption failed: \(reason)"
        case .decryptionFailed(let reason):
            return "Decryption failed: \(reason)"
        case .configurationError(let reason):
            return "Configuration error: \(reason)"
        case .agentNotFound(let name):
            return "Agent not found: \(name)"
        }
    }
}
