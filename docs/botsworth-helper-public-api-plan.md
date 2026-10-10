# Botsworth Helper public API foundation

Status: API foundation implemented; protocol tests, focused client/TLS/presentation tests, external-import smoke, inspected macOS presentation artifacts and independent code/security reviews completed on 2026-10-09. Upstream publication is pending; hosted CI and current iOS presentation/runtime evidence remain unverified. Baseline: `0d17fa9`, branch `feature/botsworth-helper-public-apis`.

This upstream slice exposes reusable APIs; Botsworth packaging/client wiring is a later slice. No new listener, credential relay, Bonjour, conversation sync or remote action capability. Preserve the existing LangTools defaults and security implementation.

## Contract

Retain the original declarations, including function-reference compatibility:

```swift
// HelperLink
public static func parse(_ url: URL) throws -> Self
public static func parse(_ url: URL, scheme: String) throws -> Self
public func pairingURL() throws -> URL
public func pairingURL(scheme: String) throws -> URL
// Chat.OllamaEndpointConfiguration.Snapshot
public func provider(directSession: URLSession) throws -> Ollama
// Chat.OllamaEndpointConfiguration
public convenience init(userDefaults: UserDefaults = .standard)
public convenience init(userDefaults: UserDefaults, keychainService: String) throws
// Chat.MobileHelperPairingCoordinator (@MainActor)
public convenience init()
public convenience init(configuration: OllamaEndpointConfiguration, scheme: String,
                        didSelect: @escaping () -> Void) throws
public static func isPairingURL(_ url: URL) -> Bool
public static func isPairingURL(_ url: URL, scheme: String) -> Bool
// SwiftUI.View
public func mobileHelperPairingPresentation() -> some View
public func mobileHelperPairingPresentation(coordinator: MobileHelperPairingCoordinator,
                                           brandingTitle: String) -> some View
```

- Export `.library(name: "HelperCore", targets: ["HelperCore"])` from `cli/Package.swift`; do not vendor its code.
- Scheme grammar: ASCII `[A-Za-z][A-Za-z0-9+.-]*`. No trimming, URL delimiters or inference from incoming links. Invalid configured schemes throw existing `MobileHelperLinkError.invalidPayload`; classifier returns false. Parse keeps exact matching semantics and all existing payload checks. Old overloads use `langtools-example-auth`.
- Scheme is immutable per coordinator/client. The custom initializer uses ONLY injected configuration/callback; default initializer retains shared LangTools service notifications.
- Namespace constructor rejects empty/blank or control-character services with an explicit configuration/persistence error, before Keychain work. Pass accepted service unchanged. This is the one deliberate refinement to the planner's nonthrowing proposal: new custom initialization must report misconfiguration rather than silently share an invalid namespace or crash.
- App owns a unique Keychain service and its defaults domain/suite. Internal credential types/store remain internal; use existing `.afterFirstUnlockThisDeviceOnly` persistence. Never migrate or import LangTools credentials into a custom namespace.
- Snapshot provider change is visibility only: retain captured helper errors, disconnected guard, pinned session lease and ordinary direct-session behavior. No silent direct fallback.
- Preserve confirmation-generation, A→B→A consent invalidation, health-before-persistence, configuration revisions and stale/persistence-failed session retirement.
- Private presentation modifier receives coordinator/title; old View overload passes `.shared` and `Connect LangToolsHelper`. Other UI text/layout/identifiers remain unchanged.
- No NEW public raw-credential APIs. Existing public `Ollama.configuration.apiKey` is introspectable; do not promise absolute token secrecy from the owning application.

## Disjoint implementation scopes

1. Protocol/export worker: `Sources/HelperLink/MobileHelperModels.swift`, `Tests/HelperLinkTests/MobileHelperModelsTests.swift`, `cli/Package.swift` only.
2. Client worker: `Apps/LangTools/Modules/Chat/Services/{OllamaEndpointConfiguration,MobileHelperPairing,MobileHelperTransport}.swift`, `Views/MobileHelperPairingPresentation.swift`, and `Tests/ChatTests/MobileHelperTests.swift` (all under `Apps/LangTools/`). Modify internal store only if namespace wiring requires it; preserve test injection hooks.
3. Parent integration: external-import smoke package `Tests/PublicHelperAPISmoke/` using root, CLI and LangToolsApp products, then review/security review and verification. No worker commits or submodule pointer changes.

## Verification

- [x] Clean baseline: `swift test -j 4 --filter HelperLinkTests` — 6 passed, exit 0; `/tmp/botsworth-phase1/upstream-helperlink-baseline.log`.
- [x] Protocol red/green tests: missing overloads failed compilation (exit 1), then 10 tests passed (exit 0), including custom round trip, cross-scheme rejection, malformed matrix and original function references. Logs: `protocol-{red,green}.log`.
- [x] Safe client tests: baseline 13 passed; new API red failed compilation; focused green 39 passed (26 helper, 7 lifetime, 6 endpoint), exit 0. Namespace wiring uses inert reflection and behavioral isolation uses mocks, not real Keychain storage. Two existing real-Keychain/shared-settings tests were explicitly excluded; real socket TLS tests were not run.
- [x] External-product smoke built successfully (exit 0), compiling the exported HelperCore product and client API graph. Log: `public-smoke-build.log`.
- [x] Public-import smoke: ordinary imports, no `@testable`, old function references, new constructors/provider and branded presentation compiled. Library-only fixture has no executable entry point; no runtime/defaults/network activity.
- [x] Focused rerun: root HelperLink 10 passed; Chat helper/lifetime/configuration 39 passed, both exit 0. Inert stores/protocol fixtures; explicitly excluded `testRealKeychainRoundtripRejectsInvalidRecord` and `testSettingsInitDoesNotStartNetworkAndStatusUsesVerifiedHelper`.
- [x] External-import smoke rerun built successfully, exit 0. Package-local ignores keep generated `.build/` and `.swiftpm/` artifacts out of Git.
- [x] Loopback TLS/provider/lease suite: 10 passed, no failures/skips, exit 0 on macOS 15.6. Checked Docker/listeners and fixture binding first; listeners use OS-assigned ephemeral ports on `127.0.0.1`. Fixture PKCS#12 import now uses memory-only import on macOS 15+; macOS 14 retains existing import behavior. No private-interface pairing tests or opt-in LAN server were run.
- [x] Current default/custom macOS confirmation and invalid-link presentation rendered and inspected; 3 tests passed with artifact output and 3 without, exit 0. [Evidence and capture limitations](verification/botsworth-helper-public-api/README.md). Default-title evidence uses injection, not runtime `.shared` wiring. Current iOS evidence is still unverified.
- [x] Final reviewer + security-reviewer returned no actionable findings. Initial managed-provider attempts were blocked; the active exact model route completed both reviews. No full-suite/physical-device readiness is claimed.
- [ ] Atomic commit preview/approval and upstream draft PR publication, separately from any Botsworth gitlink update.
- [ ] Hosted CI run, including new AppKit tests included by the existing `MobileHelper` filter; current iOS presentation/runtime evidence before merge readiness.

## Phased continuation

1. **API foundation — implemented.** Public product/scheme APIs, isolated configuration/coordinator, provider access and injectable presentation; preserve existing overloads.
2. **Noninteractive verification — passed locally.** Commands below rerun protocol, inert client/configuration/lifetime, external-product smoke and loopback TLS coverage. Real-Keychain/shared-settings tests and private-interface TLS pairing remain excluded.
3. **macOS presentation evidence — passed locally.** Three tests render actual production confirmation sheets with default/custom branding and an invalid-link alert, using synthetic, non-redeemable payloads and isolated configuration. Current screenshots are inspected and retained in `docs/verification/botsworth-helper-public-api/`. No confirmation or network/Keychain I/O; see capture limitations. Current iOS evidence remains pending.
4. **Independent review — completed; upstream publication — pending.** Both final reviews found no actionable code/security findings. The final combined app suite passed 52 XCTest tests, no failures/skips, exit 0. Keep the PR draft while hosted CI and current iOS verification remain pending. Commit/push upstream independently of any Botsworth gitlink update.

Botsworth packaging/client wiring remains a separate, later slice; this document does not authorize changes in the parent app or other worktrees.

### Repeatable local commands

```bash
swift test --jobs 4 --no-parallel --filter HelperLinkTests
swift test --package-path Apps/LangTools --jobs 4 --no-parallel \
  --filter 'MobileHelperTests|MobileHelperSessionLifetimeTests|OllamaEndpointConfigurationTests' \
  --skip 'MobileHelperTests/testRealKeychainRoundtripRejectsInvalidRecord|MobileHelperTests/testSettingsInitDoesNotStartNetworkAndStatusUsesVerifiedHelper'
swift build --package-path Tests/PublicHelperAPISmoke --jobs 4
# Run locally only on macOS 15+ for memory-only certificate import.
swift test --package-path Apps/LangTools --jobs 4 --no-parallel \
  --filter MobileHelperTLSProviderTests
MOBILE_HELPER_PRESENTATION_ARTIFACTS=/tmp/botsworth-phase1/presentation \
  swift test --package-path Apps/LangTools --jobs 4 --no-parallel \
  --filter MobileHelperPairingPresentationTests
```

Baseline/implementation logs stay under `/tmp/botsworth-phase1/`. Current rerun logs: `public-api-protocol-rerun.log` (10 tests), `public-api-client-rerun.log` (39 tests), `public-api-smoke-rerun.log` (build), `public-api-loopback-tls.log` (10 tests); adjacent `.exit` files all contain `0`. Final combined app log: `public-api-final-client.log` (52 tests, exit 0); presentation logs: `presentation-tests.log` and `presentation-no-artifacts.log` (3 each, exit 0). Do not delete caches, retained screenshots, other worktrees or credentials.
