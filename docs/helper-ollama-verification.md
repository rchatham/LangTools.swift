# iPhone Ollama helper pairing — verification

The helper provides an opt-in, encrypted, Ollama-only LAN transport. Direct Ollama remains an explicit alternative; helper failures never downgrade to direct HTTP. See the [helper setup and security boundaries](../cli/README.md#iphone-ollama-pairing-opt-in-lan).

## Recorded verification

- Shared pairing contract: 6 tests passed.
- Helper mobile relay, token/pairing and QR lifecycle: 31 focused tests passed. Real TLS tests cover scoped authorization, revocation, incremental responses, disconnect, oversized records and downstream backpressure. The flooding test uses a separate send deadline, not merely the overall request lifetime.
- Root stream validation: post-merge full suite passed (370 tests, 5 skipped). The earlier focused Ollama follow-up passed 51 tests with 1 skipped. Chat/generate require a final `done: true`; pulls require a final `status: "success"`. Incomplete streams retain emitted content but throw before tool execution.
- App helper tests: 20 passed, including 5 real pinned-TLS provider tests. Wrong pins send no bearer request; redirects are not followed; clean truncated EOF throws, including before tool execution.
- Post-merge app verification: 86 focused tests passed, covering helper transport, endpoint/configuration routing, generation settings, model capabilities, and proxy catalog isolation. The previously Keychain-blocked unavailable-model regression now uses isolated dependencies and passes without exclusion.
- Post-merge helper verification: 14 mobile relay/lifecycle tests passed, including real TLS and downstream send-specific backpressure.
- Before upstream integration, signed iOS build and strict signature verification passed; simulator build and one production-UI smoke test passed. Macro validation remained enabled using the existing approved JSON.swift revision.
- Independent code and security reviews found no remaining code blockers after the pull-completion fix.

Post-merge checks retain upstream generation settings and authoritative proxy catalogs alongside captured helper credentials and effective agent-model routing. They do not constitute physical-iPhone acceptance or a completely green full application/CLI suite.

## Known verification blockers

- Physical iPhone Camera scan, Local Network permission, actual redemption, reconnect/relaunch, models/chat/agents, revocation, helper shutdown and interface/IP changes remain unverified.
- Full app testing encountered an external Ollama E2E timeout and then a legacy real-account Keychain access permission wait. No Keychain ACL bypass was used.
- Full CLI runs encountered existing Codex test failures/timeouts and a separately reproduced loopback-server restart connection-refused failure. The privileged loopback server was not changed for this feature.
- The post-merge simulator UI rerun timed out after 600 seconds while compiling SwiftSyntax, before running the smoke test. The screenshots below come from the successful pre-merge UI run; refreshing visual evidence against the merged build remains a verification blocker.
- Screenshots do not show a verified physically paired/connected or revoked phone, or the merged proxy-catalog state. Do not treat the feature as merge-ready until acceptance and visual verification are completed.

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
