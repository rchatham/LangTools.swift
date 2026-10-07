# iPhone Ollama helper pairing — verification

The helper provides an opt-in, encrypted, Ollama-only LAN transport. Direct Ollama remains an explicit alternative; helper failures never downgrade to direct HTTP. See the [helper setup and security boundaries](../cli/README.md#iphone-ollama-pairing-opt-in-lan).

## Recorded verification

- Shared pairing contract: 6 tests passed.
- Helper mobile relay, token/pairing and QR lifecycle: 31 focused tests passed. Real TLS tests cover scoped authorization, revocation, incremental responses, disconnect, oversized records and downstream backpressure. The flooding test uses a separate send deadline, not merely the overall request lifetime.
- Root stream validation: full suite passed before the final pull completion follow-up (355 tests, 5 skipped). Final Ollama follow-up: 51 tests passed with 1 skipped. Chat/generate require a final `done: true`; pulls require a final `status: "success"`. Incomplete streams retain emitted content but throw before tool execution.
- App helper tests: 20 passed, including 5 real pinned-TLS provider tests. Wrong pins send no bearer request; redirects are not followed; clean truncated EOF throws, including before tool execution.
- Endpoint/configuration routing: 16 targeted tests passed; one legacy shared-account Keychain-dependent test was excluded after a permission-blocked rebuild.
- Signed iOS build and strict signature verification passed; simulator build and one production-UI smoke test passed. Macro validation remained enabled using the existing approved JSON.swift revision.
- Independent code and security reviews found no remaining code blockers after the pull-completion fix.

These results precede final integration with upstream `main`; they do not constitute physical-iPhone acceptance or a completely green full application/CLI suite.

## Known verification blockers

- Physical iPhone Camera scan, Local Network permission, actual redemption, reconnect/relaunch, models/chat/agents, revocation, helper shutdown and interface/IP changes remain unverified.
- Full app testing encountered an external Ollama E2E timeout and then a legacy real-account Keychain access permission wait. No Keychain ACL bypass was used.
- Full CLI runs encountered existing Codex test failures/timeouts and a separately reproduced loopback-server restart connection-refused failure. The privileged loopback server was not changed for this feature.
- Current screenshots do not show a verified physically paired/connected or revoked phone. Do not treat the feature as merge-ready until acceptance is completed.

## Inspected visual evidence

Actual Mac UI, with LAN opt-in disabled by default; active QR is fully redacted:

| LAN disabled | QR layout (redacted) |
|---|---|
| ![Mac LAN disabled](helper-ollama-screenshots/mac-connect-disabled.png) | ![Mac QR redacted](helper-ollama-screenshots/mac-qr-redacted.png) |

Production app on iPhone 16 Pro simulator. The confirmation uses a synthetic, non-redeemable QR URL; no paired state is fabricated. Direct model discovery uses the Mac's loopback daemon, not physical-phone LAN:

| Confirmation | Invalid QR | Explicit direct alternative |
|---|---|---|
| ![Confirmation](helper-ollama-screenshots/iphone-confirmation.png) | ![Invalid QR](helper-ollama-screenshots/iphone-invalid-qr.png) | ![Direct alternative](helper-ollama-screenshots/iphone-direct.png) |

No live pairing code, reusable token or certificate private key is shown. Test certificate resources are confined to the app test target.
