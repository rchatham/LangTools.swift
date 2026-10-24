# Owned access prompt lifecycle

`AccessPromptContext` retains its original seven-argument initializer. An additive overload accepts `selectedModelBinding: Binding<Model>`, `presentationCoordinator: AuthPresentationCoordinator`, and `loginCoordinator: AccountLoginCoordinator` for an explicitly owned presentation graph.

Construct the binding and fresh coordinators before passing them to the context. SwiftUI's closure-backed `Binding` initializer may sample its getter; the context and modifier constructors only retain the supplied binding and coordinators. Do not snapshot the selected model: both prompt fallbacks read the binding dynamically. The prompt currently never calls its setter.

The original initializer selects deferred legacy presentation dependencies. Only resolving that legacy route constructs the standard-model binding and selects shared coordinators. Both existing modifiers and all three `ChatSettingsView` initializers remain unchanged. Account, key and Helper operations retain their existing policy and refresh behavior; this seam does not add transport or token APIs.

## Narrow verification

`AccessPromptInjectionTests` verifies inert injected construction, dynamic model resolution (including destination-less Ollama), and unchanged owner/priority/presentation/dismissal behavior. `AccessPromptNativePresentationTests` mounts the actual `EmptyView().manageAccessPrompts(accessPrompts: owned)` modifier, initially without a destination, then presents/dismisses consent, verifies post-dismiss model reads and unregisters. Its stores and binding are memory-only; it does not construct Settings, ViewModel, AuthManager, Codex, a network client or login service.

The ordinary-import `AccessPromptLifecycleSmoke` contains typed old/new initializer references. Build the consumer only; never invoke its compile-reference functions.

Native tests can write attached-sheet captures when `ACCESS_PROMPT_ARTIFACTS` is explicitly supplied. Inspect actual PNGs; passing lifecycle tests or accessibility labels do not establish valid visual artifacts. The initial macOS capture attempts were blank (light) or missing background/button labels (dark), including AppKit cache-display capture. They are retained as failed evidence, not screenshots suitable for review. This does not prove a production rendering defect.

The App consumer must first consume a clean published SDK pin before compiling its additive wiring. No broader root, persistence, Settings or auth construction is authorized by this prompt-local change.
