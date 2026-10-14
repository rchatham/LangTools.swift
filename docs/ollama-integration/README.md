# Shared Ollama settings integration evidence

Actual public `ChatSettingsView` rendered in a consuming host with isolated synthetic fixtures. These images show only shared package views and fake/default model state—not credentials, standalone LangTools transport, or live providers.

## Current macOS rendered evidence — 2026-10-13 local unpublished fix-all

Current images below replace exactly the three public shared-view PNGs using the
previously inspected guarded host run. They show actual synthetic
NSHostingView bitmaps captured using the renderer's own briefly visible NSWindows,
closed afterward: **not desktop screenshots, offscreen-only rendering, interactive
host app workflows or standalone LangTools transport proof**. No window/code
changes were needed or made. Only these three shared-view images belong in this
public evidence set. Publication SHA is **awaiting atomic commits**, not guessed or
published. This 2026-10-14 reconciliation changes documentation only, not images.

| Local daemon | Local `:cloud` ID | Distinct Cloud |
|---|---|---|
| [![Local](shared-settings-macos.png)](shared-settings-macos.png) | [![Local cloud tag](shared-settings-macos-local-cloud-tag.png)](shared-settings-macos-local-cloud-tag.png) | [![Cloud](shared-settings-macos-cloud.png)](shared-settings-macos-cloud.png) |

Captions: `ollama/llama3` has the local explanation; `ollama/llama3:cloud` retains
that local explanation and route; `ollama-cloud/glm-5.2` has an independent Cloud
description. Fake/default state only, not current live-provider availability.

## Current results / gates — 2026-10-14, draft-only and not merge-ready

- Local dependency target merge `514f071` remains unpublished; last recorded remote
  draft is `cf15ec9`. Preserve history. Final publication SHA awaits atomic commits.
- Implemented source fixes: HTTPS synthetic CI fixture without weakening endpoint
  policy; all THREE approved P3 fixes—DEBUG session read/swap locking with invalidation
  outside the lock, explicit local/Cloud preference retention using one eligibility
  snapshot, and concrete injected Cloud catalog isolation preserving production
  defaults/key/schema/API. Quiescence remains required; not active-request lifecycle
  or TSan proof. Bounded source/security review PASS is not whole-PR approval.
- Shared Chat **73 selected / 0 failures**. ProviderAccess is 14 selected of 23; nine
  credential-dependent methods were not executed, and two negative/override passes
  lack positive saved-key prerequisites. The exact CI fixture overlaps this total.
- Provider root **335 selected / 0 failures / 5 skipped**, including earlier 33
  callback tests (not additive). Both AppleSpeech classes, whole WhisperKit class and
  six HelperLink cases are excluded under TCC/no-download/no-socket boundaries.
  Full account, credential persistence, socket/helper TLS, live-provider and database
  behavior are not established by this selection.
- Consuming-host **macOS AND iOS Debug and Release app compilation PASS** with normal
  validation and narrow isolated macro approval. Compiler-only permission does not
  guarantee zero compiler network. Fresh UI build-for-testing **PASS in 48.075s**;
  initial timeout with UNKNOWN compiler exit remains a separate failed/incomplete
  attempt, not green. Independent iOS **Release fixture-exclusion PASS** uses fresh
  Debug-positive/Release-absent symbols/strings and compiler flags/source guards.
- All **14 fixture cases compiled, NOT executed**. The **28 total runtime outcomes**
  (14 on compact and 14 on large) and current iOS images remain missing. New isolated
  QA devices were recorded available/eligible but **never booted**. Runtime signature
  re-verification passed after an initial seal failure and normal re-import;
  stale unusable-image metadata remains, so full runtime usability is not claimed.
- Native execution stopped after a contained host driver metadata probe aborted with
  **SIGABRT (-6), no output and no guard activation marker**. Cause is unestablished;
  neither a source defect nor actual credential access is proved. Effective simulator
  fixture group was statically resolved from `__TEXT/__entitlements`; no actual
  signing occurred. Accepted simulator framework-egress residual does not waive host
  guards. No native continuation is authorized by this documentation pass.
- Last recorded CI at OLD `cf15ec9`: six successes, one app-helper failure, two Cloud
  skips. The repaired local fixture is not new-head CI. Both dependency and consuming
  integration remain **Draft, unmerged and not merge-ready** pending native outcomes,
  current iOS images, final review and new-head checks. No remote state was refreshed.

Existing receipts only; this offline reconciliation ran no tests/builds, probes or
publication. Current source and images are unchanged. Public evidence is limited to
shared Chat scope; operational identifiers and host-only evidence are not included.

## Historical macOS source-remediation evidence — 2026-10-08

The prior three images remain identifiable at published child `cf15ec9`; current
filenames above now hold the 2026-10-13 renders, not those old captures:
[local](https://github.com/rchatham/LangTools.swift/blob/cf15ec9c460255ef4b7226ddc642cf3f660625c8/docs/ollama-integration/shared-settings-macos.png),
[local cloud tag](https://github.com/rchatham/LangTools.swift/blob/cf15ec9c460255ef4b7226ddc642cf3f660625c8/docs/ollama-integration/shared-settings-macos-local-cloud-tag.png),
[Cloud](https://github.com/rchatham/LangTools.swift/blob/cf15ec9c460255ef4b7226ddc642cf3f660625c8/docs/ollama-integration/shared-settings-macos-cloud.png).

Earlier results: child **71 / 0**, provider root **375 / 0** (5 skipped),
Mac render/probe **6 / 0**. Those guarded runs
covered endpoint/cache/currentness/helper/settings/native fixtures and callbacks;
real-Keychain roundtrip was retained but excluded after guard denial. Full Chat/
account/helper and live socket/TLS proof were not claimed. At that checkpoint,
Xcode's nested manifest sandbox blocked app-target compilation; subsequent current
macOS and iOS builds resolved compilation; current iOS runtime/visual gates remain.

## Historical iOS evidence — not current source verification

| Compact iOS (pre-merge) | Large iOS (pre-merge) |
|---|---|
| [![Compact](shared-settings-ios-compact.png)](shared-settings-ios-compact.png) | [![Large](shared-settings-ios-large.png)](shared-settings-ios-large.png) |

These files remain pre-merge captures. Historical native fixtures passed 12 cases per viewport; a later startup correction passed three affected compact flows without a full rerun. Upstream settings/helper UI changed afterward. Fresh repaired-head compact/large inspection and screenshots remain a merge-readiness blocker; unchanged files do not prove visual equivalence.

Standalone Chat refuses Cloud completion/stream/agents without a host Cloud-capable transport; a consuming application must supply that integration. Snapshot exposes no direct raw helper credential/lease/session getter, but returned `AgentContext` retains normal `LangTools` semantics: trusted holders can access its session and prepared requests. This is not a transitive secrecy sandbox.

Do not use real host stores/providers to force green tests. Simulator fixtures use fake credentials in owned devices; never inject the host deny interposer into simulator apps. Current iOS Release fixture exclusion is verified, but live-provider/deployed-TLS, complete UI runtime verification and merge readiness are not. Previously exposed credentials require rotation through a separately authorized process; no values or credential operations belong in this evidence.
