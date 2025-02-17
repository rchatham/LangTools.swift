# LangTools.swift

LangTools for working with LLM apis in Swift. 

This package provides a simple Swift interface for interacting with OpenAI and Anthropic's Chat APIs, with full support for functions.


## Features

- Support for various LLM model APIs including OpenAI, Anthropic, xAI, Google Gemini & Ollama.
- Handling both regular and streaming API requests.
- Built-in error handling and response parsing.
- Support for functions.
    - Streaming functions.
    - Multiple/Parrellel functions. - Dependent on model and api support

## Requirements

- iOS 16.0+ / macOS 13.0+
- Swift 5+

## Installation

Include the following dependency in your `Package.swift` file:

```swift
dependencies: [
    .package(url: "https://github.com/rchatham/LangTools.swift.git", branch: "main")
]
```

## Usage

The best way to learn how it works is to run the LangTools_Example in XCode!

### Build your own Agents!

Create an agent in just a few lines of code:

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
    Anthropic.Message(role: .user, string: "Hello!")
])
let response = try await agent.execute(context: context)
```

For more detailed information about Agents, including tools, delegation, and event tracking, see the Agents [documentation](/Sources/Agents/AGENTS.md).


### Initializing the Client

```swift
let langToolsClient = OpenAI(apiKey: "your-api-key")
// OR let langToolsClient = Anthropic(apiKey: "your-api-key")
// OR let langToolsClient = XAI(apiKey: "your-api-key")
// OR let langToolsClient = Gemini(apiKey: "your-api-key")
```

### Performing a Chat Completion Request

```swift
// OpenAI
let request = OpenAI.ChatCompletionRequest(
    model: .gpt4,
    messages: [ /* Your messages here */ ],
    /* Other optional parameters */
)
// XAI uses OpenAI.ChatCompletionRequest with .grok and .grokVision models.
// Gemini uses OpenAI.ChatCompletionRequest with .gemini models.

// Anthropic
let request = Anthropic.MessageRequest(
    model: .claude35Sonnet_20240620,
    messages: [ /* Your messages here */ ]
)

// Ollama
let request = Ollama.ChatRequest(
    model: "llama3.2",
    messages: [ /* Your messages here */ ]
)

// Using async/await
// Non-streaming - stream is set to false regardless of request config
let response = try await langToolsClient.perform(request: request)

// Streaming - returns message as streamed or not depending on request config
for try await response in langToolsClient.stream(request: request) {
    
    // handle non-streaming messages
    if let message = response.message {
        print("message received: \(message)")
    }

    // handle stream messages
    if let delta = response.delta {
        if let chunk = delta.content {
            content += chunk
        }
    }

    // receive text content from response - works for both streaming and non-streaming
    if let text = response.content.text {
        content += text
    }

    // handle finish reason - api depends on response type
    if let finishReason = response.choices.first?.finish_reason {
        switch finishReason {
        case .stop:
            guard !content.isEmpty else { return }
            print("message received: \(content)")
        case .tool_calls, .length, .content_filter: break
        }
    }
}

// Using completion handler
langToolsClient.perform(request: chatRequest) { result in
    switch result {
    case .success(let response):
        print(response)
    case .failure(let err):
        print(err.localizedDescription)
    }
}
```

### Implementation Steps for Using Functions

#### Define the Function Schema

Before using a function in a chat completion request, define its schema. This includes the function name, description, and parameters. Here's an example for a hypothetical `getCurrentWeather` function:

```swift
let getCurrentWeatherFunction = OpenAI.Tool.FunctionSchema(
    name: "getCurrentWeather",
    description: "Get the current weather for a specified location.",
    parameters: .init(
        properties: [
            "location": .init(
                type: "string",
                description: "The city and state, e.g., San Francisco, CA"
            ),
            "format": .init(
                type: "string",
                enumValues: ["celsius", "fahrenheit"],
                description: "The temperature unit to use."
            )
        ],
        required: ["location", "format"]),
    callback: { [weak self] in
        // Run your custom function logic here.
        self?.functionThatReturnsCurrentWeather(location: $0["location"] as! String, format: $0["format"] as! String)
    })
)
```

That's it! This works for streaming, and even works with multiple functions.

### Handling Image Content in Array Messages
When dealing with messages that contain arrays of content, including image content, follow these steps to handle them appropriately in your LangTools.swift client implementation.

#### Step 1: Create Messages with Image Content
```swift
let imageMessage = OpenAI.Message(
    role: .user, 
    content: .array([
        .image(.init(
            image_url: .init(
                url: "https://example.com/image.jpg",
                detail: .high
            )
        ))
    ])
)
```

#### Step 2: Include Image Messages in the Chat Request
```swift
let chatRequest = OpenAI.ChatCompletionRequest(
    model: .gpt4,
    messages: [imageMessage, /* other messages here */],
    /* Other optional parameters */
)
```

---
### Embeddings

```swift
let request = OpenAI.EmbeddingsRequest(
        input: .string("Your text here"),
        model: .textEmbeddingAda002
)

let response = try await langToolsClient.perform(request: request)

// The response contains:
// - response.data[0].embedding - The embedding vector
// - response.usage.prompt_tokens - Token usage information
// - response.model - Model used
```

---

## Contributing

Contributions are welcome. Please open an issue or submit a pull request with your changes.

## TODO

- [x] Use async/await
- [x] Pass closures for function calling
    - [ ] Verfiy parameters using JsonSchema
    - [ ] Codable paramter objects
    - [ ] Allow typed parameters?
    - [ ] Allow configuration of subsequent requests after a function call
- [x] Call LangTools functions without returning intermediate tool message to dev
    - [ ] Optionally return intermediate tool message to devs
    - [ ] Needs more testing
- [ ] Implement Assistants endpoint
- [ ] Implement other api endpoints
    - [ ] Needs more testing
- [ ] Add docs

## License

This project is free to use under the [MIT LICENSE](LICENSE).

The other guys:
- https://github.com/MacPaw/OpenAI
- https://github.com/adamrushy/OpenAISwift
- https://github.com/OpenDive/OpenAIKit
- https://github.com/dylanshine/openai-kit
- https://github.com/SwiftBeta/SwiftOpenAI
