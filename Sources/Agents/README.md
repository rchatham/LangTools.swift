# Agents

The Agents framework provides a powerful way to create specialized AI assistants with specific capabilities, tools, and delegation abilities. Agents can handle complex tasks by breaking them down, using tools, and collaborating with other agents.

## Overview

An Agent in LangTools is a specialized AI assistant that:
- Has a specific role and set of responsibilities
- Can use tools to accomplish tasks
- Can delegate to other agents when needed
- Maintains context and state throughout interactions
- Provides structured event tracking

## Creating an Agent

To create an agent, implement the `Agent` protocol:

```swift
struct MyAgent<LangTool: LangTools>: Agent {
    let langTool: LangTool
    let model: LangTool.Model
    
    // Required protocol properties
    let name = "myAgent"
    let description = "Agent responsible for specific tasks"
    let instructions = """
        Your detailed instructions for the agent...
        """
    
    var delegateAgents: [any Agent] = []
    var tools: [any LangToolsTool]? = [
        Tool(
            name: "my_tool",
            description: "Tool description",
            tool_schema: .init(
                properties: [
                    "param1": .init(
                        type: "string",
                        description: "Parameter description"
                    )
                ],
                required: ["param1"]
            ),
            callback: { args in
                // Tool implementation
                return "Result"
            }
        )
    ]
}
```

## Using Tools

Agents can use tools to perform specific actions. Tools are defined with:
- Name and description
- JSON schema for parameters
- Callback function for implementation

```swift
let tool = Tool(
    name: "search_data",
    description: "Search through specified data",
    tool_schema: .init(
        properties: [
            "query": .init(
                type: "string",
                description: "Search query"
            ),
            "limit": .init(
                type: "integer",
                description: "Maximum results to return"
            )
        ],
        required: ["query"]
    ),
    callback: { args in
        guard let query = args["query"]?.stringValue else {
            throw AgentError("Missing query parameter")
        }
        // Implement search logic
        return "Search results..."
    }
)
```

## Agent Delegation

Agents can delegate tasks to other specialized agents:

```swift
struct MainAgent<LangTool: LangTools>: Agent {
    let langTool: LangTool
    let model: LangTool.Model
    
    var delegateAgents: [any Agent]
    
    init(langTool: LangTool, model: LangTool.Model) {
        self.langTool = langTool
        self.model = model
        
        // Initialize delegate agents
        delegateAgents = [
            SpecialistAgent()
        ]
    }
}
```

## Event Tracking

Agents provide detailed event tracking through the `AgentEvent` enum:

- `.started`: When an agent begins a task
- `.agentTransfer`: When work is delegated to another agent
- `.toolCalled`: When a tool is invoked
- `.toolCompleted`: When a tool operation completes
- `.completed`: When the agent completes its task
- `.error`: When an error occurs

Events can be tracked through the event handler:

```swift
let context = AgentContext(messages: messages) { event in
    switch event {
    case .started(let agent, let parent, let task):
        print("Agent '\(agent)' started: \(task)")
    case .toolCalled(let agent, let tool, let args):
        print("Agent '\(agent)' called tool '\(tool)' with args: \(args)")
    case .completed(let agent, let result):
        print("Agent '\(agent)' completed with result: \(result)")
    // Handle other events...
    }
}
```

## Executing Agents

Execute an agent with a context:

```swift
let agent = MyAgent()
let context = AgentContext(messages: [
    LangToolsMessageImpl(role: .user, string: "Process this request")
])

do {
    let result = try await agent.execute(context: context)
    print("Result: \(result)")
} catch {
    print("Error: \(error)")
}
```

## Example Agents

The LangTools example project includes several agents:

- `CalendarAgent`: Manages calendar operations (creating, reading, updating events)
- `ReminderAgent`: Handles reminders and tasks
- `ResearchAgent`: Performs internet research and information gathering

## Best Practices

1. Keep agent responsibilities focused and specific
2. Provide clear instructions in the agent's `instructions` property
3. Use delegate agents for specialized tasks
4. Implement proper error handling in tool callbacks
5. Use the event system to track and debug agent operations
6. Follow the principle of least privilege when defining tool capabilities
