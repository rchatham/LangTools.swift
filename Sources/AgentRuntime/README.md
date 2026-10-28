# AgentRuntime

AgentRuntime runs agents from a JSON spec instead of Swift code. A spec names a provider, a model and a set of tools; the runtime builds the provider client, looks up the tools, runs the agent and returns a JSON result. This is the piece that lets an agent run somewhere other than the app that defined it: in a container, on a server, or on a schedule.

It has four parts:

- **`AgentRuntime`**: the spec and result types, the provider and tool registries, `AgentRunner`, and `AgentRuntimeCommand` (the command-line front end).
- **`AgentRuntimeProviders`**: registers every chat provider that ships with LangTools as `AgentProviderRegistry.builtIn`.
- **`langtools-agent`**: an executable with the built-in providers and tools.
- **`Dockerfile.agent`**: a container image for `langtools-agent`.

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

Progress events go to standard error and the result goes to standard output (or `--output`). The exit status is `0` when the run completes, `1` when it fails or times out, `2` for bad arguments, an invalid spec or an invalid webhook URL, and `3` when the result couldn't be delivered to the webhook. A result is printed in every case except bad arguments or a spec file that can't be read or parsed:

```json
{
  "runID": "4F1C2B7E-...",
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

`status` is one of `completed`, `failed`, `timedOut` or `invalid`. `error` holds the message when the run did not complete. `runID` comes from `--run-id` or `LANGTOOLS_RUN_ID`, or is generated.

## Delivering results to a webhook

```bash
export LANGTOOLS_WEBHOOK_SECRET=...   # shared with the receiver
langtools-agent run spec.json --webhook https://example.com/agent-results --run-id job-42
```

The URL can also come from `LANGTOOLS_WEBHOOK_URL`. The secret is read only from `LANGTOOLS_WEBHOOK_SECRET`, never from an argument, because arguments are visible to other processes. The runtime POSTs the same JSON result it prints, with these headers:

| Header | Value |
|--------|-------|
| `X-LangTools-Signature` | `t=<unix seconds>,v1=<hex HMAC-SHA256 of "<t>.<body>" keyed with the secret>` |
| `X-LangTools-Delivery` | A UUID that stays the same across retries; use it to ignore duplicates. |
| `X-LangTools-Run-ID` | The result's `runID`. |

Rules:

- The URL must be `https`; plain `http` is allowed only for `localhost`, `127.0.0.1` and `::1`. The URL is checked before the agent runs, so a bad one costs no provider call.
- Network errors and HTTP 408, 429 and 5xx are retried up to 5 attempts, waiting 1, 2, 4 and 8 seconds, or the server's `Retry-After` (at most 60 seconds). Other 4xx answers are not retried.
- Any 2xx answer counts as delivered. If every attempt fails, the exit status is `3`; the result is still printed or written to `--output`.
- Without a secret, deliveries are unsigned and a warning is printed. Anyone who knows the URL could then post a fake result, so set a secret outside local testing.

To verify a delivery, recompute the HMAC over the raw request body and reject timestamps more than five minutes old. In Swift, use `WebhookSignature.verify(body:header:secret:)`. In Python:

```python
import hashlib, hmac, time

def verify(body: bytes, header: str, secret: str, tolerance: int = 300) -> bool:
    parts = dict(p.split("=", 1) for p in header.split(","))
    if abs(time.time() - int(parts["t"])) > tolerance:
        return False
    expected = hmac.new(secret.encode(), f"{parts['t']}.".encode() + body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, parts["v1"])
```

## Running in a container

`Dockerfile.agent` at the repository root builds an Ubuntu 24.04 image with a statically linked `langtools-agent`. It runs as an unprivileged user (uid 10001) in `/work`.

```bash
docker build -f Dockerfile.agent -t langtools-agent .

docker run --rm \
  -e ANTHROPIC_API_KEY -e LANGTOOLS_WEBHOOK_SECRET \
  -v "$PWD/Examples/AgentRuntime:/work:ro" \
  langtools-agent run clock.json --webhook https://example.com/agent-results
```

Pass keys with `-e`, not in the image. A spec can also come in on standard input with `docker run -i ... run -`. To add your own tools, copy the Dockerfile and change the build target to your executable (see below).

## Running as a worker

`langtools-agent worker` is a long-lived process that runs jobs from a spool directory: a queue on disk that survives restarts.

```bash
export LANGTOOLS_SPOOL_DIR=/var/lib/langtools-agent ANTHROPIC_API_KEY=... LANGTOOLS_WEBHOOK_SECRET=...
langtools-agent worker --concurrency 4 &

langtools-agent enqueue spec.json --webhook https://example.com/agent-results --run-id job-42
langtools-agent status job-42        # {"runID": "job-42", "state": "queued" | "running" | "done", "result": {...}}
```

- `enqueue` validates the spec against the worker's providers, tools and keys, so it needs the same environment as the worker. `--job` reads a whole job as JSON on standard input instead: `{"runID", "spec", "webhookURL", "webhookSecret", "owner"}`. A secret sent that way never appears in a process list.
- Jobs run oldest first, up to `--concurrency` at a time. Jobs move between `queue/`, `running/` and `done/` by atomic rename, so several workers can share one spool.
- SIGTERM or SIGINT stops the worker from taking new jobs and waits for running ones. A job cut off by a crash or kill is started once more on the next start, then reported as `failed`.
- Results stay in `done/` for 7 days. Job files, which can hold a webhook secret, are readable only by their owner.

To run workers in Docker on your machine, on servers over SSH, or on DigitalOcean, see [AgentDeploy](../AgentDeploy/README.md).

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
