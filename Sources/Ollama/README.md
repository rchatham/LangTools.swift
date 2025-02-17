# Ollama

Swift interface for Ollama's local LLM server, part of the LangTools framework. Run and interact with open-source language models locally.

## Features

- 🤖 Local model management
- 💬 Chat and completion endpoints
- 🔄 Streaming support
- 🛠️ Tool integration
- 📦 Model pulling and pushing
- ⚙️ Custom model creation
- 📊 Model information and stats

## Basic Usage

### Initialize Ollama Client

```swift
// Connects to local Ollama server (default: http://localhost:11434)
let ollama = Ollama()

// Or specify custom server URL
let ollama = Ollama(baseURL: URL(string: "http://your-server:11434")!)
```

### Chat Completions

Basic chat completion:
```swift
let request = Ollama.ChatRequest(
    model: "llama2",
    messages: [
        Message(role: .user, content: "What is a language model?")
    ]
)

let response = try await ollama.perform(request: request)
print(response.message?.content.text ?? "")
```

Streaming chat completion:
```swift
let request = Ollama.ChatRequest(
    model: "llama2",
    messages: [
        Message(role: .user, content: "Tell me a story.")
    ],
    stream: true
)

for try await chunk in ollama.stream(request: request) {
    if let text = chunk.message?.content.text {
        print(text, terminator: "")
    }
}
```

### Generate Completions

For more direct control over generation:

```swift
let request = Ollama.GenerateRequest(
    model: "llama2",
    prompt: "Write a poem about coding.",
    options: GenerateOptions(
        temperature: 0.7,
        top_k: 40,
        top_p: 0.9,
        repeat_penalty: 1.1
    )
)

let response = try await ollama.generate(model: "llama2", prompt: "Once upon a time")
print(response.response)
```

## Model Management

### List Models

```swift
// List all available models
let models = try await ollama.listModels()
for model in models.models {
    print("Model: \(model.name)")
    print("Modified: \(model.modifiedAt)")
    print("Size: \(model.size)")
}

// List currently running models
let running = try await ollama.listRunningModels()
for model in running.models {
    print("Running: \(model.name)")
    print("Memory usage: \(model.sizeVRAM)")
}
```

### Pull Models

```swift
// Pull a model
let response = try await ollama.pullModel("llama2")

// Or stream the download progress
for try await chunk in ollama.streamPullModel("llama2") {
    print("Progress: \(chunk.completed ?? 0)/\(chunk.total ?? 0)")
}
```

### Push Models

```swift
// Push a model to a registry
try await ollama.pushModel("username/mymodel:latest")
```

### Create Custom Models

```swift
// Create a model from a Modelfile
let modelfile = """
FROM llama2
PARAMETER temperature 0.8
PARAMETER top_p 0.7
SYSTEM You are a helpful coding assistant.
"""

try await ollama.createModel(
    model: "my-coding-assistant",
    modelfile: modelfile
)
```

### Model Information

```swift
// Get detailed model info
let info = try await ollama.showModel("llama2")
print(info.parameters)
print(info.template)
print(info.details)

// Delete a model
try await ollama.deleteModel("old-model")

// Copy a model
try await ollama.copyModel(
    source: "llama2",
    destination: "llama2-backup"
)
```

## Advanced Features

### Tool Integration

```swift
let searchTool = OpenAI.Tool(
    name: "search",
    description: "Search for information",
    tool_schema: .init(
        properties: [
            "query": .init(
                type: "string",
                description: "Search query"
            )
        ],
        required: ["query"]
    ),
    callback: { args in
        guard let query = args["query"]?.stringValue else {
            throw AgentError("Missing query")
        }
        return "Search results for: \(query)"
    }
)

let request = Ollama.ChatRequest(
    model: "llama2",
    messages: [
        Message(role: .user, content: "Search for Swift programming.")
    ],
    tools: [searchTool]
)
```

### Generation Options

```swift
let options = Ollama.GenerateOptions(
    num_predict: 100,         // Maximum tokens to generate
    top_k: 40,               // Top-k sampling
    top_p: 0.9,              // Nucleus sampling
    temperature: 0.8,         // Randomness
    repeat_penalty: 1.1,      // Penalty for repetition
    presence_penalty: 0.0,    // Penalty for topic presence
    frequency_penalty: 0.0,   // Penalty for token frequency
    mirostat: 0,             // Mirostat sampling mode
    mirostat_tau: 5.0,       // Mirostat target entropy
    mirostat_eta: 0.1,       // Mirostat learning rate
    penalize_newline: true,   // Penalize newlines
    stop: ["END"],           // Stop sequences
    num_ctx: 4096,           // Context window size
    num_batch: 512,          // Batch size
    num_gpu: 1,              // Number of GPUs to use
    num_thread: 4            // Number of CPU threads
)
```

### Structured Output

```swift
let format = Ollama.GenerateFormat.schema(
    SchemaFormat(
        type: "object",
        properties: [
            "title": PropertyFormat(
                type: "string",
                description: "Article title"
            ),
            "summary": PropertyFormat(
                type: "string",
                description: "Article summary"
            )
        ],
        required: ["title", "summary"]
    )
)

let request = Ollama.GenerateRequest(
    model: "llama2",
    prompt: "Write an article about AI.",
    format: format
)
```

## Error Handling

```swift
do {
    let response = try await ollama.perform(request: request)
} catch let error as OllamaErrorResponse {
    print("Ollama error:", error.error.message)
} catch {
    print("Other error:", error)
}
```

## Best Practices

1. **Model Selection**:
   - Choose models based on task requirements
   - Consider resource constraints (RAM, GPU)
   - Test models for specific use cases

2. **Resource Management**:
   - Monitor memory usage with `listRunningModels`
   - Clean up unused models
   - Use appropriate batch sizes

3. **Performance**:
   - Use streaming for long responses
   - Adjust context and batch sizes
   - Configure GPU/CPU usage appropriately

4. **Error Handling**:
   - Handle network errors (server connection)
   - Monitor model loading errors
   - Implement retry logic for transient failures

5. **Model Updates**:
   - Keep models up to date
   - Backup custom models
   - Version control Modelfiles

## Additional Resources

- [Ollama GitHub Repository](https://github.com/ollama/ollama)
- [Ollama API Documentation](https://github.com/ollama/ollama/blob/main/docs/api.md)
- [Ollama Model Library](https://ollama.ai/library)
