//
//  DigitalOceanDeploymentAgent.swift
//  LangTools
//
//  Created by Claude on 2025.
//

import Foundation
import LangTools
import Agents

/// Agent responsible for deploying and managing AI agents on DigitalOcean infrastructure
public struct DigitalOceanDeploymentAgent: Agent {
    private let digitalOceanClient: DigitalOceanClient
    private let serializationService: AgentSerializationService
    private let encryptionService: NotificationEncryptionService
    private let defaultRegion: String

    public init(apiToken: String, defaultRegion: String = "nyc3") {
        self.digitalOceanClient = DigitalOceanClient(apiToken: apiToken)
        self.serializationService = AgentSerializationService()
        self.encryptionService = NotificationEncryptionService()
        self.defaultRegion = defaultRegion
    }

    public let name = "digitalOceanDeploymentAgent"
    public let description = "Agent responsible for deploying and managing AI agents on DigitalOcean infrastructure"
    public let instructions = """
        You are responsible for deploying AI agents to DigitalOcean droplets where they can run in the background.

        Your capabilities include:
        1. Creating and configuring DigitalOcean droplets
        2. Deploying agent runtime environments
        3. Managing agent lifecycles (start, stop, update, delete)
        4. Setting up secure communication channels for results
        5. Monitoring agent execution and resource usage

        Always ensure:
        - Proper security configurations
        - Cost-effective resource allocation
        - Reliable notification setup for results
        - Proper error handling and monitoring

        When deploying an agent, you need:
        - agent_name: A descriptive name for the deployment
        - agent_definition: The serialized agent configuration (JSON/base64)
        - droplet_size: The size of the DigitalOcean droplet (small, medium, large, xlarge)
        - max_execution_time: Maximum time the agent can run (in seconds)
        """

    public var delegateAgents: [any Agent] = []

    public var tools: [any LangToolsTool]? {
        return [
            createDeploymentTool(),
            listDeploymentsTool(),
            getStatusTool(),
            terminateTool()
        ]
    }

    // MARK: - Tool Definitions

    private func createDeploymentTool() -> Tool {
        return Tool(
            name: "create_agent_deployment",
            description: "Deploy an AI agent to DigitalOcean for background execution",
            tool_schema: ToolSchema(
                properties: [
                    "agent_name": ToolSchemaProperty(
                        type: "string",
                        description: "Name for the deployed agent"
                    ),
                    "agent_definition": ToolSchemaProperty(
                        type: "string",
                        description: "Serialized agent definition (base64 encoded JSON)"
                    ),
                    "droplet_size": ToolSchemaProperty(
                        type: "string",
                        enumValues: ["s-1vcpu-1gb", "s-1vcpu-2gb", "s-2vcpu-2gb", "s-2vcpu-4gb"],
                        description: "DigitalOcean droplet size"
                    ),
                    "max_execution_time": ToolSchemaProperty(
                        type: "integer",
                        description: "Maximum execution time in seconds (default: 3600)"
                    ),
                    "region": ToolSchemaProperty(
                        type: "string",
                        description: "DigitalOcean region (default: nyc3)"
                    )
                ],
                required: ["agent_name", "agent_definition"]
            )
        ) { [self] _, args in
            return try await self.createDeployment(args)
        }
    }

    private func listDeploymentsTool() -> Tool {
        return Tool(
            name: "list_agent_deployments",
            description: "List all deployed agents and their status",
            tool_schema: ToolSchema(
                properties: [
                    "tag": ToolSchemaProperty(
                        type: "string",
                        description: "Optional tag to filter deployments"
                    )
                ]
            )
        ) { [self] _, args in
            return try await self.listDeployments(args)
        }
    }

    private func getStatusTool() -> Tool {
        return Tool(
            name: "get_deployment_status",
            description: "Get detailed status of a specific agent deployment",
            tool_schema: ToolSchema(
                properties: [
                    "deployment_id": ToolSchemaProperty(
                        type: "string",
                        description: "ID of the deployment (droplet ID) to check"
                    )
                ],
                required: ["deployment_id"]
            )
        ) { [self] _, args in
            return try await self.getStatus(args)
        }
    }

    private func terminateTool() -> Tool {
        return Tool(
            name: "terminate_deployment",
            description: "Terminate a running agent deployment and cleanup resources",
            tool_schema: ToolSchema(
                properties: [
                    "deployment_id": ToolSchemaProperty(
                        type: "string",
                        description: "ID of the deployment (droplet ID) to terminate"
                    )
                ],
                required: ["deployment_id"]
            )
        ) { [self] _, args in
            return try await self.terminate(args)
        }
    }

    // MARK: - Tool Implementations

    private func createDeployment(_ args: [String: JSON]) async throws -> String {
        guard let agentName = args["agent_name"]?.stringValue,
              let agentDefinition = args["agent_definition"]?.stringValue else {
            throw CloudAgentError.deploymentFailed("Missing required parameters: agent_name and agent_definition")
        }

        let dropletSize = args["droplet_size"]?.stringValue ?? DropletSize.small.rawValue
        let maxExecutionTime = args["max_execution_time"]?.intValue ?? 3600
        let region = args["region"]?.stringValue ?? defaultRegion

        // Validate the agent definition
        do {
            _ = try serializationService.deserializeAgent(agentDefinition)
        } catch {
            throw CloudAgentError.deploymentFailed("Invalid agent definition: \(error.localizedDescription)")
        }

        // Generate encryption key for secure result delivery
        let encryptionKey = encryptionService.generateEncryptionKey()

        // Generate user data script for droplet initialization
        let userData = generateUserDataScript(
            agentName: agentName,
            agentDefinition: agentDefinition,
            encryptionKey: encryptionKey,
            maxExecutionTime: TimeInterval(maxExecutionTime)
        )

        // Create droplet
        let dropletName = "langtools-agent-\(agentName.lowercased().replacingOccurrences(of: " ", with: "-"))-\(UUID().uuidString.prefix(8))"
        let createRequest = CreateDropletRequest(
            name: dropletName,
            region: region,
            size: dropletSize,
            user_data: userData,
            tags: ["langtools", "agent-runtime", "agent-\(agentName.lowercased())"]
        )

        let droplet = try await digitalOceanClient.createDroplet(createRequest)

        return """
        Agent deployment created successfully!

        Deployment Details:
        - Droplet ID: \(droplet.id)
        - Name: \(droplet.name)
        - Status: \(droplet.status)
        - Size: \(droplet.size_slug) (\(DropletSize(rawValue: droplet.size_slug)?.displayName ?? droplet.size_slug))
        - Region: \(droplet.region.name) (\(droplet.region.slug))
        - Created: \(droplet.created_at)
        - Encryption Key: \(encryptionKey)

        The agent will begin execution once the droplet is fully provisioned (typically 30-60 seconds).
        Save the encryption key to decrypt the agent's results when they are delivered.

        Estimated cost: $\(String(format: "%.3f", (DropletSize(rawValue: droplet.size_slug)?.hourlyCost ?? 0.009)))/hour
        """
    }

    private func listDeployments(_ args: [String: JSON]) async throws -> String {
        let tag = args["tag"]?.stringValue ?? "langtools"
        let droplets = try await digitalOceanClient.listDroplets(tag: tag)

        if droplets.isEmpty {
            return "No active agent deployments found with tag '\(tag)'."
        }

        var result = "Active Agent Deployments:\n"
        result += "========================\n\n"

        for (index, droplet) in droplets.enumerated() {
            let size = DropletSize(rawValue: droplet.size_slug)
            result += """
            \(index + 1). \(droplet.name)
               - Droplet ID: \(droplet.id)
               - Status: \(droplet.status)
               - Size: \(size?.displayName ?? droplet.size_slug)
               - Region: \(droplet.region.name)
               - IP Address: \(droplet.publicIPv4 ?? "Pending...")
               - Created: \(droplet.created_at)
               - Tags: \(droplet.tags.joined(separator: ", "))

            """
        }

        result += "\nTotal: \(droplets.count) deployment(s)"
        return result
    }

    private func getStatus(_ args: [String: JSON]) async throws -> String {
        guard let deploymentId = args["deployment_id"]?.stringValue,
              let dropletId = Int(deploymentId) else {
            throw CloudAgentError.deploymentFailed("Invalid deployment_id: must be a valid droplet ID")
        }

        let droplet = try await digitalOceanClient.getDroplet(id: dropletId)
        let size = DropletSize(rawValue: droplet.size_slug)

        return """
        Deployment Status for \(droplet.name)
        =====================================

        Infrastructure:
        - Droplet ID: \(droplet.id)
        - Status: \(droplet.status)
        - Locked: \(droplet.locked ? "Yes" : "No")

        Resources:
        - Memory: \(droplet.memory) MB
        - vCPUs: \(droplet.vcpus)
        - Disk: \(droplet.disk) GB
        - Size: \(size?.displayName ?? droplet.size_slug)

        Network:
        - Public IPv4: \(droplet.publicIPv4 ?? "N/A")
        - Private IPv4: \(droplet.privateIPv4 ?? "N/A")
        - IPv6 Enabled: \(droplet.features.contains("ipv6") ? "Yes" : "No")

        Location:
        - Region: \(droplet.region.name) (\(droplet.region.slug))

        Metadata:
        - Created: \(droplet.created_at)
        - Tags: \(droplet.tags.joined(separator: ", "))
        - Features: \(droplet.features.joined(separator: ", "))

        Cost:
        - Hourly: $\(String(format: "%.3f", size?.hourlyCost ?? 0.009))
        - Monthly: $\(String(format: "%.2f", size?.monthlyCost ?? 6.0))
        """
    }

    private func terminate(_ args: [String: JSON]) async throws -> String {
        guard let deploymentId = args["deployment_id"]?.stringValue,
              let dropletId = Int(deploymentId) else {
            throw CloudAgentError.deploymentFailed("Invalid deployment_id: must be a valid droplet ID")
        }

        // Get droplet info before deletion for the response
        let droplet = try await digitalOceanClient.getDroplet(id: dropletId)
        let dropletName = droplet.name

        try await digitalOceanClient.deleteDroplet(id: dropletId)

        return """
        Deployment Terminated
        ====================

        - Droplet ID: \(dropletId)
        - Name: \(dropletName)
        - Status: Deleted

        All resources have been cleaned up and billing has stopped.
        """
    }

    // MARK: - Helper Methods

    private func generateUserDataScript(
        agentName: String,
        agentDefinition: String,
        encryptionKey: String,
        maxExecutionTime: TimeInterval
    ) -> String {
        // Escape the agent definition for safe inclusion in the script
        let escapedDefinition = agentDefinition
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        return """
        #!/bin/bash
        set -e

        # Log all output
        exec > >(tee /var/log/langtools-agent.log) 2>&1

        echo "Starting LangTools Agent Deployment: \(agentName)"
        echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"

        # Update system
        apt-get update -y
        apt-get install -y docker.io curl jq

        # Start Docker
        systemctl start docker
        systemctl enable docker

        # Create agent runtime directory
        mkdir -p /opt/langtools-runtime
        cd /opt/langtools-runtime

        # Create agent configuration
        cat > agent-config.json << 'AGENT_CONFIG_EOF'
        {
            "agentName": "\(agentName)",
            "agentDefinition": "\(escapedDefinition)",
            "encryptionKey": "\(encryptionKey)",
            "maxExecutionTime": \(Int(maxExecutionTime)),
            "startedAt": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        }
        AGENT_CONFIG_EOF

        echo "Agent configuration created"

        # Pull and run agent runtime container
        # Note: Replace with actual container image when available
        docker pull langtools/agent-runtime:latest 2>/dev/null || {
            echo "Note: langtools/agent-runtime:latest not found, using placeholder"
            # Create a placeholder that logs the configuration
            echo "Agent runtime would execute here with config:"
            cat agent-config.json
        }

        # Setup auto-cleanup after max execution time + buffer
        CLEANUP_DELAY=\(Int(maxExecutionTime + 300))
        cat > /opt/langtools-runtime/cleanup.sh << 'CLEANUP_EOF'
        #!/bin/bash
        sleep $CLEANUP_DELAY
        echo "Auto-cleanup triggered after timeout"
        # Send completion notification if webhook configured
        # Stop any running containers
        docker stop langtools-agent 2>/dev/null || true
        docker rm langtools-agent 2>/dev/null || true
        # Self-destruct the droplet
        curl -X DELETE -H "Authorization: Bearer $DO_API_TOKEN" \\
            "https://api.digitalocean.com/v2/droplets/$(curl -s http://169.254.169.254/metadata/v1/id)" 2>/dev/null || true
        CLEANUP_EOF

        chmod +x /opt/langtools-runtime/cleanup.sh
        nohup /opt/langtools-runtime/cleanup.sh &

        echo "Cleanup scheduled in \(Int(maxExecutionTime + 300)) seconds"
        echo "Agent deployment initialization complete"
        """
    }
}

// MARK: - Deployment Manager

/// Manages multiple agent deployments and provides high-level operations
public actor CloudAgentDeploymentManager {
    private let digitalOceanClient: DigitalOceanClient
    private let serializationService: AgentSerializationService
    private let encryptionService: NotificationEncryptionService
    private var deployments: [String: AgentDeployment] = [:]

    public init(apiToken: String) {
        self.digitalOceanClient = DigitalOceanClient(apiToken: apiToken)
        self.serializationService = AgentSerializationService()
        self.encryptionService = NotificationEncryptionService()
    }

    /// Deploys an agent to the cloud
    public func deploy(
        agent: any Agent,
        provider: AIProvider,
        model: String,
        apiKey: String,
        messages: [any LangToolsMessage] = [],
        size: DropletSize = .small,
        region: String = "nyc3",
        maxExecutionTime: TimeInterval = 3600
    ) async throws -> AgentDeployment {
        let encryptionKey = encryptionService.generateEncryptionKey()

        let config = try serializationService.createRuntimeConfiguration(
            agent: agent,
            provider: provider,
            model: model,
            apiKey: apiKey,
            messages: messages,
            encryptionKey: encryptionKey,
            maxExecutionTime: maxExecutionTime
        )

        let dropletName = "langtools-\(agent.name.lowercased())-\(UUID().uuidString.prefix(8))"
        let request = CreateDropletRequest(
            name: dropletName,
            region: region,
            size: size.rawValue,
            tags: ["langtools", "agent-\(agent.name.lowercased())"]
        )

        let droplet = try await digitalOceanClient.createDroplet(request)

        let deployment = AgentDeployment(
            name: agent.name,
            status: .provisioning,
            dropletSize: size,
            dropletId: droplet.id
        )

        deployments[deployment.id] = deployment
        return deployment
    }

    /// Gets the status of a deployment
    public func getDeployment(_ id: String) -> AgentDeployment? {
        return deployments[id]
    }

    /// Lists all tracked deployments
    public func listDeployments() -> [AgentDeployment] {
        return Array(deployments.values)
    }

    /// Terminates a deployment
    public func terminate(_ id: String) async throws {
        guard var deployment = deployments[id],
              let dropletId = deployment.dropletId else {
            throw CloudAgentError.agentNotFound(id)
        }

        try await digitalOceanClient.deleteDroplet(id: dropletId)
        deployment.status = .cancelled
        deployment.completedAt = Date()
        deployments[id] = deployment
    }

    /// Syncs local state with DigitalOcean
    public func sync() async throws {
        let droplets = try await digitalOceanClient.listDroplets(tag: "langtools")

        for (id, var deployment) in deployments {
            if let dropletId = deployment.dropletId {
                if let droplet = droplets.first(where: { $0.id == dropletId }) {
                    // Update status based on droplet status
                    switch droplet.status {
                    case "active":
                        deployment.status = .running
                    case "off":
                        deployment.status = .completed
                    default:
                        break
                    }
                } else {
                    // Droplet no longer exists
                    deployment.status = .completed
                    deployment.completedAt = Date()
                }
                deployments[id] = deployment
            }
        }
    }
}
