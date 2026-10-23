# Owned access prompts (MR22 F3 SDK prerequisite)

This narrow API seam builds on `1212c1e`; it is not whole-settings isolation or completed Botsworth wiring.

## Public surface and ownership

The actual existing `ChatSettingsView.init(viewModel:)`, `init(viewModel:ollamaService:)`, `View.manageAccessPrompts(networkClient:priority:)` declaration/defaults, `NetworkClient` initializer/protocol defaults, and `AuthSessionStore.init(keychain:)` remain intact. Typed references are compile-checked without constructing settings or its ViewModel.

The new `ChatSettingsView.init(viewModel:ollamaService:accessPrompts:)` and `View.manageAccessPrompts(accessPrompts:priority:)` require an explicit `AccessPromptContext`. Both platform layouts select that context lazily, retaining fixture/proxy suppression and priority 10. Injected presentation never selects `NetworkClient.shared` or `ProviderAccessManager.shared`. Shared presentation/login-progress coordinators retain their existing passive arbitration behavior; their browser actions are not invoked by injection tests.

An owning App must pass the **same manager** to its settings ViewModel, Ollama service and access context. Key closures must update/reconfigure that App's backend. The injected Serper path uses those same supplied operations; any App-specific defaults update belongs in its supplied closure. The legacy adapter alone retains SDK Serper defaults/Keychain behavior.

`ProviderAccountAccessOperations(providerAccessManager:loginServiceProvider:)` requires a manager and lazy login-service factory, with no singleton defaults. Only the four existing account/Helper mutation methods are extracted from `NetworkClient`, which delegates without signature changes. Helper canonicalization, marker routing, pre-suspension session identity, replacement protection, local cleanup after remote failure, persistence errors and diagnostics are retained. No credential API, transport or namespace changes.

## Audited checks

Memory tests cover inert context/modifier construction, owned manager refresh after key/account changes, trimming/empty validation, remove/Serper routing, CLI versus Helper branches, lazy login resolution, canonicalization, failed persistence, remote logout failures and replacement sessions. Account/helper secret stores are memory-only; API-key overrides never call host Keychain; defaults use unique suites. No whole settings/ViewModel, Codex settings, AuthManager, live login, App/Helper, provider traffic or listeners execute.

The ordinary-import library consumer compiles typed old/new API references; **never invoke its functions**. It is a build-only fixture, not a safe runtime fixture.

Recovery evidence (commands, full logs, exits, fixture/cache audits and final file lists/patches) is under the parent App worktree:
`Botsworth/.build/verification/mr22-review-loop/pass-1/sdk-fixes/worker/`.

The F3 run passed **26 tests** (14 new F3 + 12 existing approved memory tests). See `HANDOFF.md` for the final combined F3/F4 count and commands. The first F3 attempt failed to compile an unqualified nested error name, then was fixed. Initial inherited commands omitted explicit shared-manifest-cache isolation; global manifest writes cannot be ruled out. Final accepted commands explicitly use task-owned cache/config/security paths, local manifest caching and disabled dependency caching. No global cache was altered or deleted deliberately; see the handoff's deviation disclosure.

## Limits

No mounted/rendered settings/auth UI, screenshots, iOS build, full root/message service isolation, live account login, device TLS/LAN, signing or distribution proof. Existing global Codex/settings architecture is deliberately not expanded. No dependency pins or nested ChatUI changes. Parent independent review, source commits, clean gitlink consumption and App-owned wiring/tests remain separate work. MR22 is not merge-ready from this API prerequisite.
