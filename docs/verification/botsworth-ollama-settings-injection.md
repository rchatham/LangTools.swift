# App-owned Ollama settings prerequisite

Verified locally 2026-10-14 on isolated `feature/botsworth-ollama-settings-injection`, based on published `62376cc`. This is a prerequisite for Botsworth Phase 1C, not completed app client wiring.

## Scope

- Preserve actual `ChatSettingsView.init(viewModel:)`; add `init(viewModel:ollamaService:)`.
- Both existing macOS/mobile sheets use one lazy presentation selector. The injected path passes the supplied service into the existing internal `OllamaSettingsView` constructor, which derives endpoint configuration from that service. Legacy defaults resolve only when its sheet is constructed.
- Preserve actual public `AuthSessionStore.init(keychain:)` and its defaults, same Keychain object/options, `openAI:accountSession` / `claudeCode:accountSession` keys, JSON format and thrown errors. Its private backing uses the existing `KeychainSecretStoring` adapter; an **internal** initializer permits memory-only tests. No public secret-storage API, migration or namespace change.
- Existing `OllamaSettingsView` constructors, manifests, resolved pins and nested ChatUI gitlink are unchanged.

## Results

| Check | Result |
|---|---|
| Initial safe baseline | 4 Codex token-store memory tests passed |
| New-API TDD red | Exit 1; missing overload, selector and internal storage initializer |
| Accepted isolated focused run | **12 passed, 0 failed**, exit 0: 5 auth-memory, 3 settings-injection, 4 safe baseline |
| Ordinary-import public consumer | **Build passed**, exit 0; consumer never executed |
| Diff check | Passed |
| Independent scoped code/security reviews | Passed, no required fixes; construction/lifecycle and global-settings limits below remain |

Logs: `/tmp/botsworth-phase1-resume/settings-seam-v2/accepted-tests.log` and `accepted-smoke-build.log`, with adjacent `.exit` files; reviews `reviewer-final.md` and `security-reviewer-final.md`. The test consumer retains typed references to both real settings initializer declarations without invoking them.

```bash
env GIT_ALLOW_PROTOCOL=file swift test --package-path Apps/LangTools \
  --jobs 4 --disable-automatic-resolution --disable-experimental-prebuilts \
  --filter '^ChatTests.(CodexHelperTokenStoreTests|AuthSessionStoreMemoryTests|OllamaSettingsInjectionTests)'
env GIT_ALLOW_PROTOCOL=file swift build --package-path Tests/PublicHelperAPISmoke \
  --jobs 4 --disable-automatic-resolution --disable-experimental-prebuilts
```

## Isolation and superseded attempts

A fresh worktree and separate local ChatUI worktree at `ddd53cb` protect concurrent upstream work. Existing pinned dependency checkouts/repositories were copied locally; no remote fetch or cache deletion was used. The first copied SwiftPM state left old `fileSystem.state.path` values and a duplicate root reference. Its 8-test green is **not** the accepted isolation result; the first consumer build failed before compile. Both failures/audits remain in the log directory.

Parent normalized **all** local dependency locations, state paths and identities, and removed a name-only duplicate root reference. The accepted workspace-state files and generated build plans contain no original-worktree paths. Accepted logs contain no fetch/download messages. Disabled prebuilts prevent remote compiler-plugin retrieval; Git transport is restricted to local files.

Runtime tests explicitly use memory account/helper stores, an API-key-store subclass overriding every operation used by the manager, unique defaults and an ephemeral URLProtocol intercepting all requests. Constructing its superclass's Keychain configuration is inert; no host Keychain operation is performed. The sole explicit mocked connection operation reaches the fixture `/api/version` handler. No production Helper, listener, credential migration or consumer execution.

## Limits / remaining verification

The whole `ChatSettingsView` and its ViewModel are **not instantiated** in tests: the existing Codex pairing singleton and other globals are outside this Ollama seam. Injecting this overload is not a claim of whole-settings isolation; callers must supply the same access manager/configuration graph to their service and settings model.

Tests construct the internal injected sheet, but do not mount/render it. SwiftUI `StateObject` activation, appearance callbacks and navigation through both real sheet routes remain unverified. No screenshots accompany this API-only prerequisite: it adds no layout/text/control changes, and whole-settings rendering requires further safe fixture isolation. Current mounted macOS/iOS state artifacts are an outstanding downstream integration requirement, not satisfied by construction or compile checks.

Botsworth-owned backend/service/coordinator routing, pairing URL registration, real helper TLS, physical-device access, full suites, signing/notarization and distribution are not established. No new PR was created for this separate branch. This prerequisite and MR !22 are **not merge-ready** from these results.
