# CloudAgents

CloudAgents enables deployment of AI agents to cloud infrastructure for background execution with secure result delivery.

## Features

- **DigitalOcean Integration**: Deploy agents to droplets with full lifecycle management
- **Secure Notifications**: End-to-end encrypted notifications using AES-GCM
- **Background Execution**: Run long-running tasks in isolated cloud environments
- **Cost Optimization**: Automatic cleanup and resource management
- **Resource Monitoring**: Track CPU, memory, and network usage

## Installation

Add CloudAgents to your dependencies:

```swift
dependencies: [
    .package(url: "https://github.com/rchatham/langtools.swift.git", from: "0.3.0")
]

.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "CloudAgents", package: "langtools.swift")
    ]
)
```

## Quick Start

### Using the Deployment Agent

```swift
import CloudAgents
import Anthropic
import Agents

// Create the deployment agent
let deploymentAgent = DigitalOceanDeploymentAgent(
    apiToken: "your-digitalocean-token"
)

// Use it with an AgentContext to deploy other agents
let context = AgentContext(
    langTool: anthropic,
    model: .sonnet,
    messages: [
        anthropic.userMessage("""
            Deploy my research agent with:
            - Name: Research Assistant
            - Droplet Size: medium
            - Max execution time: 7200 seconds
        """)
    ],
    eventHandler: { event in
        print(event.description)
    }
)

let response = try await deploymentAgent.execute(context: context)
print(response)
```

### Using the Deployment Manager

```swift
import CloudAgents

// Create the manager
let manager = CloudAgentDeploymentManager(apiToken: "your-do-token")

// Deploy an agent
let deployment = try await manager.deploy(
    agent: myAgent,
    provider: .anthropic,
    model: "claude-3-5-sonnet-20241022",
    apiKey: "your-anthropic-key",
    size: .medium,
    maxExecutionTime: 3600
)

print("Deployed: \(deployment.id)")

// Check status
if let status = await manager.getDeployment(deployment.id) {
    print("Status: \(status.status)")
}

// Terminate when done
try await manager.terminate(deployment.id)
```

## Core Components

### DigitalOcean Client

Direct API integration for droplet management:

```swift
let client = DigitalOceanClient(apiToken: "your-token")

// Create a droplet
let request = CreateDropletRequest(
    name: "my-agent",
    region: "nyc3",
    size: "s-1vcpu-2gb"
)
let droplet = try await client.createDroplet(request)

// Monitor status
let status = try await client.getDroplet(id: droplet.id)
print("IP: \(status.publicIPv4 ?? "pending")")

// Cleanup
try await client.deleteDroplet(id: droplet.id)
```

### Encryption Service

Secure notification encryption using AES-GCM:

```swift
let encryptionService = NotificationEncryptionService()

// Generate encryption key
let key = encryptionService.generateEncryptionKey()

// Encrypt notification
let notification = AgentNotification(
    agentName: "research-agent",
    result: executionResult,
    timestamp: Date()
)
let encrypted = try encryptionService.encrypt(
    notification: notification,
    userKey: key
)

// Decrypt notification
let decrypted = try encryptionService.decrypt(
    payload: encrypted,
    userKey: key
)
```

### Agent Serialization

Prepare agents for cloud deployment:

```swift
let serializationService = AgentSerializationService()

// Serialize an agent
let serialized = try serializationService.serializeAgent(
    myAgent,
    provider: .anthropic,
    model: "claude-3-5-sonnet-20241022",
    apiKey: "provider-api-key"
)

// Deserialize agent definition
let definition = try serializationService.deserializeAgent(serialized)
print("Agent: \(definition.name)")
```

## Security Considerations

- **API Keys**: Store DigitalOcean and LLM provider keys securely (use Keychain on Apple platforms)
- **Encryption**: All notifications use AES-GCM 256-bit encryption
- **Isolation**: Each deployment runs in its own isolated droplet
- **Cleanup**: Automatic resource cleanup prevents cost overruns
- **Networking**: Only essential ports exposed

## Cost Management

### Droplet Pricing

| Size    | vCPU | RAM  | Monthly | Hourly  |
|---------|------|------|---------|---------|
| Small   | 1    | 1 GB | $6      | $0.009  |
| Medium  | 1    | 2 GB | $12     | $0.018  |
| Large   | 2    | 2 GB | $18     | $0.027  |
| X-Large | 2    | 4 GB | $24     | $0.036  |

### Cost Optimization Tips

1. **Set Execution Timeouts**: Prevent runaway costs with `maxExecutionTime`
2. **Use Appropriate Sizes**: Match resources to workload requirements
3. **Enable Auto-Cleanup**: Droplets auto-delete after completion
4. **Monitor Usage**: Track deployments regularly with `listDeployments`

## Droplet Sizes

```swift
// Available sizes
DropletSize.small   // 1 vCPU, 1 GB - $6/month
DropletSize.medium  // 1 vCPU, 2 GB - $12/month
DropletSize.large   // 2 vCPU, 2 GB - $18/month
DropletSize.xlarge  // 2 vCPU, 4 GB - $24/month

// Access properties
let size = DropletSize.medium
print(size.displayName)   // "Medium (1 vCPU, 2 GB)"
print(size.monthlyCost)   // 12.0
print(size.hourlyCost)    // 0.018
```

## Regions

Common DigitalOcean regions:

- `nyc1`, `nyc3` - New York
- `sfo2`, `sfo3` - San Francisco
- `ams3` - Amsterdam
- `sgp1` - Singapore
- `lon1` - London
- `fra1` - Frankfurt
- `tor1` - Toronto
- `blr1` - Bangalore

## Error Handling

```swift
do {
    let deployment = try await manager.deploy(agent: myAgent, ...)
} catch CloudAgentError.deploymentFailed(let reason) {
    print("Deployment failed: \(reason)")
} catch CloudAgentError.serializationFailed(let reason) {
    print("Serialization failed: \(reason)")
} catch DigitalOceanError.apiError(let statusCode, let message) {
    print("DO API error \(statusCode): \(message ?? "unknown")")
} catch {
    print("Unexpected error: \(error)")
}
```

## Troubleshooting

### Common Issues

**Deployment Fails**
- Verify DigitalOcean API token has correct permissions (read/write for droplets)
- Check regional availability for the requested size
- Ensure sufficient account resources/limits

**Agent Execution Timeout**
- Increase `maxExecutionTime` parameter
- Use larger droplet size for compute-intensive tasks
- Optimize agent workload

**Serialization Errors**
- Ensure agent definition is valid JSON
- Check that all required fields are present
- Verify API keys are correct

### Debugging

Enable verbose logging by checking the droplet's logs:

```bash
# SSH into droplet
ssh root@<droplet-ip>

# View agent logs
cat /var/log/langtools-agent.log
```

## License

MIT License - see LICENSE for details.
