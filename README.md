# LangTools

LangTools is a Swift framework for working with Large Language Models (LLMs) and AI services. It provides a unified interface for multiple AI providers and includes tools for building agents and specialized AI assistants.

## Features

- 🤖 **Multiple LLM Support**: OpenAI, Anthropic, X.AI, Google Gemini, and Ollama
- 🔧 **Unified Interface**: Common protocols for working with different AI providers
- 🤝 **Extensible Agent System**: Build specialized AI assistants with tools and delegation
- 📝 **Streaming Support**: Handle streaming responses from AI models
- 🛠️ **Tool Integration**: Add custom capabilities to your AI interactions

## Installation

### Swift Package Manager

Add LangTools to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/rchatham/langtools.swift.git", from: "0.2.0")
]
```

## Basic Usage

```swift
// Initialize a language model service
let anthropic = Anthropic(apiKey: "your-key")

// Create a simple chat request
let messages = [
    anthropic.systemMessage("You are a helpful assistant."),
    anthropic.userMessage("Hello!")
]

// Get a response
let response = try await anthropic.perform(request: 
    Anthropic.MessageRequest(
        model: .claude35Sonnet_latest,
        messages: messages
    )
)

print(response.message?.content.text ?? "No response")
```

## Quick Start with Agents

```swift
struct SimpleAgent: Agent {
    let langTool: Anthropic
    let model: Anthropic.Model
    
    let name = "simpleAgent"
    let description = "A simple agent that responds to user queries"
    let instructions = "You are a simple agent that responds to user queries."
    
    var delegateAgents: [any Agent] = []
    var tools: [any LangToolsTool]? = nil
}

// Use your agent
let agent = SimpleAgent(
    langTool: Anthropic(apiKey: "your-key"), 
    model: .claude35Sonnet_latest
)
let context = AgentContext(messages: [
    LangToolsMessageImpl(role: .user, string: "Hello!")
])
let response = try await agent.execute(context: context)
```

## Documentation

See individual module README files for detailed documentation and examples:

- [LangTools](Sources/LangTools/README.md)
- [Agents](Sources/Agents/README.md)
- [OpenAI](Sources/OpenAI/README.md)
- [Anthropic](Sources/Anthropic/README.md)
- [XAI](Sources/XAI/README.md)
- [Gemini](Sources/Gemini/README.md)
- [Ollama](Sources/Ollama/README.md)

## Contributing

Contributions are welcome! See our [Contributing Guide](CONTRIBUTING.md) for details.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
