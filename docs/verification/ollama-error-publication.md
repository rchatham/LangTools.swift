# Ollama error-publication claims (MR22 F4 SDK prerequisite)

`OllamaService` now exposes synchronous MainActor methods:

- `beginErrorPublication(clearError:) -> ErrorPublicationClaim` (clear defaults to true)
- `isCurrentErrorPublication(_:) -> Bool`
- `publishError(_:for:) -> Bool`
- `invalidateErrorPublications()`

Claims are opaque and service-owned; a different service rejects them. Starting a new operation or explicitly invalidating supersedes older claims. `publishError` returns whether an assignment was accepted, not a promise that synchronous subscribers left that claim current. Recheck before subsequent work.

The actual writable `@Published public var error: Error?` and `$error` remain. Every external assignment, **including nil**, invalidates claims in `willSet`, before `$error` or `objectWillChange` subscribers run. Internal claimed publication consumes a one-shot permit before notification; nested external assignments therefore cannot inherit that permit. Assignment frames restore the latest nested value after the outer `@Published` setter returns, avoiding its normal overwrite of a subscriber's newer assignment. A reentrant write can cause one additional terminal publication during restoration; normal non-reentrant assignments publish once. Restoration does not invalidate a newer subscriber-owned claim.

`refreshModels()` takes its claim at start and clears/publishes only while it remains current, including explicit nil on success. Models, cache and loading still use the existing independent refresh generation and captured endpoint snapshot guards: losing an error claim does **not** discard current model/cache results or strand loading. Endpoint/transport changes retain existing refresh behavior and invalidate claims through their public error clear. Snapshot/provider and captured Helper session leases are untouched.

A future App check/startup should take a claim, retain all App mode/pairing/cancellation/endpoint guards, and publish through it. Do not continue using `$error` notifications to invalidate a separate competing App arbiter. The SDK tests simulate this public-API contract; no App source is changed here.

## Verification

Twelve memory-only F4 tests cover cross-service rejection, external error/nil pre-publication invalidation, ordinary and reentrant internal publication, nested new claims, nested claimed publication and stored-value restoration, `objectWillChange` reentrant clear, both held old-refresh/new-check polarities, external error/clear during both held operations, reverse refresh/check ordering, graph isolation, endpoint/transport invalidation, explicit successful completion nil, and retained models/cache/loading after losing only the error claim. tags/version use explicit request gates; ps returns intercepted memory JSON. Unknown URLs fail, never forward. No sleeps or live Helper credentials.

The ordinary-import library compiles claim API, writable-error and `$error` references; never execute its consumer functions. Final accepted test and build commands use task-owned cache/config/security directories, local manifest caching, disabled dependency cache, disabled automatic resolution/prebuilts, Git protocol=file and jobs=4. Full commands/logs/exits and the earlier shared-cache-isolation deviation are recorded in the parent evidence `sdk-fixes/worker/HANDOFF.md`.

No mounted UI, App integration, cancellation/pairing behavior in App, Helper transport/device runtime, iOS or distribution proof is claimed. Parent independent code/security review and App claim integration remain required. MR22 is not merge-ready from these SDK checks.
