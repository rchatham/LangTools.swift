# AgentRuntime

AgentRuntime runs agents from a JSON spec instead of Swift code. A spec names a provider, a model and a set of tools; the runtime builds the provider client, looks up the tools, runs the agent and returns a JSON result. This is the piece that lets an agent run somewhere other than the app that defined it: in a container, on a server, or on a schedule.

It has three parts:

- **`AgentRuntime`**: the spec and result types, the provider and tool registries, `AgentRunner`, and `AgentRuntimeCommand` (the command-line front end).
- **`AgentRuntimeProviders`**: registers every chat provider that ships with LangTools as `AgentProviderRegistry.builtIn`.
- **`langtools-agent`**: an executable with the built-in providers and tools.

## The spec

```json
{
  "name": "Researcher",
  "description": "Answers questions with sources.",
  "instructions": "Answer briefly. Use tools when you need current information.",
  "provider": "anthropic",
  "model": "claude-sonnet-4-6",
  "tools": ["current_time"],
  "timeoutSeconds": 300,
  "messages": [
    { "role": "user", "content": "What day of the week is it in Tokyo?" }
  ]
}
```

| Key | Required | Meaning |
|-----|----------|---------|
| `name`, `instructions` | yes | The agent's name and system instructions. |
| `provider` | yes | A registered provider ID. Run `langtools-agent providers` for the list. |
| `model` | yes | The provider's model ID. OpenAI and OpenAI-compatible providers accept any ID; Anthropic, Gemini and xAI accept the IDs in their `Model` enums. |
| `messages` | yes | The conversation; it must contain at least one user message. Roles are `system`, `user` and `assistant`. |
| `description` | no | Shown to a parent agent when this agent is a delegate. |
| `tools` | no | Names of registered tools. Run `langtools-agent tools` for the list. |
| `delegates` | no | Nested specs this agent can transfer work to. Delegates use the parent's provider and model; their `messages`, `baseURL` and `timeoutSeconds` are ignored. |
| `responseSchema` | no | A JSON Schema the final answer must match, where the provider supports structured output. |
| `baseURL` | no | Overrides the provider's API URL, for a proxy or self-hosted server. |
| `timeoutSeconds` | no | Wall-clock limit for the whole run. |
| `version` | no | Spec format version; defaults to the current version (1). |

**A spec never contains an API key.** Keys come from the environment of the process that runs it, using each provider's variable (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, and so on). A spec can be stored, logged or sent anywhere without exposing credentials.

## Running a spec

```bash
swift build -c release --product langtools-agent
export ANTHROPIC_API_KEY=...

.build/release/langtools-agent validate spec.json   # checks provider, model, tools and key without calling the API
.build/release/langtools-agent run spec.json        # prints the result as JSON
.build/release/langtools-agent run - < spec.json --output result.json --quiet
```

Progress events go to standard error and the result goes to standard output (or `--output`). The exit status is `0` when the run completes, `1` when it fails or times out, and `2` for bad arguments or an invalid spec. A result is printed in every case except bad arguments or a spec file that can't be read or parsed:

```json
{
  "agent": "Researcher",
  "provider": "anthropic",
  "model": "claude-sonnet-4-6",
  "status": "completed",
  "output": "It's Wednesday in Tokyo.",
  "events": [
    { "kind": "started", "agent": "Researcher", "detail": "What day of the week is it in Tokyo?", "isError": false, "date": "..." },
    { "kind": "toolCalled", "agent": "Researcher", "tool": "current_time", "detail": "{\"time_zone\":\"Asia/Tokyo\"}", "isError": false, "date": "..." }
  ],
  "startedAt": "...",
  "finishedAt": "..."
}
```

`status` is one of `completed`, `failed`, `timedOut` or `invalid`. `error` holds the message when the run did not complete.

## Adding tools

Tools are Swift code, so they can't travel inside a spec; a spec lists tool names and the runtime that executes it decides which names exist. To add tools, build your own executable around `AgentRuntimeCommand`:

```swift
// Sources/my-agent-runtime/main.swift
import Foundation
import AgentRuntime
import AgentRuntimeProviders
import LangTools

let searchTool = Tool(
    name: "search_docs",
    description: "Search the internal documentation.",
    tool_schema: .init(properties: ["query": .init(type: "string")], required: ["query"]),
    callback: { _, args in try await DocsIndex.search(args["query"]?.stringValue ?? "") }
)

var tools = AgentToolRegistry.builtIn
tools.register(searchTool)

let command = AgentRuntimeCommand(providers: .builtIn, tools: tools)
exit(await command.run(Array(CommandLine.arguments.dropFirst())))
```

A spec that names a tool the runtime doesn't have fails validation and lists the tools that are available.

The only built-in tool is `current_time`, which has no side effects. Other tools are left to each runtime on purpose, because what an agent is allowed to touch depends on where it runs.

## Using the runner from Swift

```swift
import AgentRuntime
import AgentRuntimeProviders

let spec = try AgentSpec.decode(from: Data(contentsOf: specURL))
let runner = AgentRunner(
    providers: .builtIn,
    tools: .builtIn,
    credentials: .environment(),          // or .keys([LangToolsProviderID(rawValue: "openai"): key])
    onEvent: { print($0.kind, $0.detail ?? "") }
)
try runner.validate(spec)                 // optional: fail fast without calling the provider
let result = await runner.run(spec)       // never throws; failures are in result.status and result.error
```

## Adding a provider

Register a `ProviderRegistration` that builds the client and parses model IDs:

```swift
var providers = AgentProviderRegistry.builtIn
providers.register(ProviderRegistration(
    id: LangToolsProviderID(rawValue: "my-gateway"),
    displayName: "My Gateway",
    apiKeyEnvironmentVariable: "MY_GATEWAY_API_KEY",
    makeClient: { config in
        OpenAI(baseURL: config.baseURL ?? URL(string: "https://gateway.example.com/v1/")!,
               apiKey: try config.requireAPIKey(for: LangToolsProviderID(rawValue: "my-gateway")),
               session: config.session)
    },
    makeModel: { OpenAI.Model(customModelID: $0) }
))
```

Set `requiresAPIKey: false` for providers, like a local Ollama server, that work without a key.

## Built-in providers

`openai`, `anthropic`, `gemini`, `xai`, `ollama` (key optional), `openrouter`, `groq`, `mistral`, `deepseek`, `cerebras`, `together`, `fireworks`, `vercel`, `perplexity`, `cohere`.
