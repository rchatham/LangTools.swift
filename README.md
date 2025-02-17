# LangTools

LangTools is a Swift framework for working with Large Language Models (LLMs) and AI services. It provides a unified interface for multiple AI providers and includes tools for building agents and specialized AI assistants.

## Features

- 🤖 **Multiple LLM Support**: OpenAI, Anthropic, X.AI, Google Gemini, and Ollama
- 🔧 **Unified Interface**: Common protocols for working with different AI providers
- 🤝 **Extensible Agent System**: Build specialized AI assistants with tools and delegation
- 📝 **Streaming Support**: Handle streaming responses from AI models
- 🛠️ **Tool Integration**: Add custom capabilities to your AI interactions

## Modules

### [LangTools Core](Sources/LangTools/README.md)
Base protocols and utilities for working with LLMs. Provides the foundation for model interactions and common interfaces.

### [Agents](Sources/Agents/README.md)
Framework for building specialized AI assistants with tools and delegation capabilities. Create agents that can perform specific tasks and collaborate.

### [OpenAI](Sources/OpenAI/README.md)
Integration with OpenAI's GPT models, including chat completions, embeddings, and audio capabilities.

### [Anthropic](Sources/Anthropic/README.md)
Support for Anthropic's Claude models with streaming and tool integration.

### [X.AI](Sources/XAI/README.md)
Integration with X.AI's Grok models.

### [Gemini](Sources/Gemini/README.md)
Support for Google's Gemini AI models.

### [Ollama](Sources/Ollama/README.md)
Integration with local Ollama models and server.

## Installation

### Swift Package Manager

Add LangTools to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/reidchatham/langtools-swift.git", from: "0.1.0")
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
    typealias LangTool = Anthropic
    
    let langTool: Anthropic
    let model: Anthropic.Model
    
    let name = "simpleAgent"
    let description = "A simple agent that responds to user queries"
    let instructions = "You are a simple agent that responds to user queries."
    
    var delegateAgents: [any Agent] = []
    var tools: [any LangToolsTool]? = nil
    
    init(langTool: Anthropic, model: Anthropic.Model) {
        self.langTool = langTool
        self.model = model
    }
}
```

## Documentation

See individual module README files for detailed documentation and examples:

- [LangTools Core Documentation](Sources/LangTools/README.md)
- [Agents Documentation](Sources/Agents/README.md)
- [OpenAI Documentation](Sources/OpenAI/README.md)
- [Anthropic Documentation](Sources/Anthropic/README.md)
- [X.AI Documentation](Sources/XAI/README.md)
- [Gemini Documentation](Sources/Gemini/README.md)
- [Ollama Documentation](Sources/Ollama/README.md)

## Contributing

Contributions are welcome! See our [Contributing Guide](CONTRIBUTING.md) for details.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
