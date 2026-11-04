# SystemOneLangTools

Routes tools with [System One](https://github.com/rchatham/SystemOne.swift) models
such as d1-omni. Before each request, d1 scores the tools for the message, and the
language model only receives the plausible ones. The model still writes the tool's
arguments and the reply, because System One only scores options.

This is a separate package so that System One's MLX stack and exact dependency pins
reach only the apps that opt in, not every consumer of LangTools. `LangToolsToolRouter`
itself lives in the `LangTools` module and has no such dependencies.

## Usage

```swift
let router = try await SystemOneToolRouter.d1(
    modelFolder: modelFolder,
    routingDescriptions: ["calendarAgent": "Their calendar, events, meetings, or schedule"]
)
messageService.toolRouter = router
```

`SystemOneToolRouter.server(endpoint:)` asks `system-one serve` instead, for the iOS
Simulator, where MLX cannot run.

Tool descriptions written for a language model say what a tool does, while d1 routes
best on the request it handles, so `routingDescriptions` replaces them for routing.

## In the LangTools app

Routing is off by default. Turn it on in **Settings › System One** and choose a
[LiquidAI/d1-omni-600M](https://huggingface.co/LiquidAI/d1-omni-600M) snapshot folder.
Each routed message then shows its route, such as `System One: calendarAgent 0.93`.
Build the app in Release for routing speed, because MLX is far slower in Debug.

## Which tools a request receives

A model given a tool may call it even when the message doesn't need it: `llama3.1`
ran a web search for "hi". So `MessageService` applies these rules:

- **Normally:** the tools scoring at least `toolRoutingMinimumProbability`, most likely
  first, or none if no tool reaches it.
- **After a routed turn:** those tools plus the previous turn's, because "yes, do it" has
  no tool intent of its own, while a new request needs its own tools. Kept tools are
  dropped when the router is at least 95% sure that no tool is needed.
- **If the router fails:** every enabled tool, as if routing were off.

Both mistakes remain possible. A cutoff can hide a tool the message needed, and a model
can still misuse a tool it was given. Add labeled messages for your tools to the routing
probe before relying on them.

## Model limits

Routing narrows what a model can call, but the model still decides what to do with it.
Small local models show these problems, which routing does not fix:

- **Invented tool calls:** `llama3.1` can write a call to a tool that doesn't exist as plain
  text, such as `{"name": "weatherAgent", ...}`. Ollama returns it as ordinary content, so
  the app displays it as the reply. This reproduces against Ollama without the app.
- **Answers without calling a tool:** an agent may reply without using its tools, so treat
  results as unverified unless the transcript shows the tool ran, such as `get_events`
  under `calendarReadAgent`.

## Testing

```bash
xcodebuild test -scheme SystemOneLangTools -destination 'platform=macOS,arch=arm64'
```

To also run the routing probe against real d1, set `TEST_RUNNER_D1_MODEL_FOLDER` to the
snapshot folder. Use `xcodebuild`, not `swift test`, because MLX needs its Metal library.
