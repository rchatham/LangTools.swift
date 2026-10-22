# Public helper API presentation verification

Current production SwiftUI pairing modifier rendered and inspected on macOS 15.6, 2026-10-09. The AppKit fixture hosts a real attached sheet, not a replica of the pairing UI.

| Default title | Custom title | Invalid link |
|---|---|---|
| ![Connect LangToolsHelper](langtools-default-confirmation.png) | ![Connect Botsworth Helper](botsworth-custom-confirmation.png) | ![Invalid pairing link](botsworth-invalid-link.png) |

The titles, synthetic Mac identity/endpoint, complete consent/capability/security text and confirmation/Cancel controls are readable without clipping. Only the production Cancel button is pressed. The invalid-link alert is dismissed without pairing. Three tests verify sheet attachment, accessibility content, dismissal, unchanged configuration and zero selection callbacks.

```bash
MOBILE_HELPER_PRESENTATION_ARTIFACTS=/tmp/botsworth-phase1/presentation \
  swift test --package-path Apps/LangTools --jobs 4 --no-parallel \
  --filter MobileHelperPairingPresentationTests
```

Artifact-enabled and artifact-disabled runs each passed 3 tests, exit 0. The final combined helper/configuration/lifetime/TLS/presentation run passed 52 tests, exit 0. Logs: `/tmp/botsworth-phase1/{presentation-tests,presentation-no-artifacts,public-api-final-client}.log`.

## iOS production presentation — verified 2026-10-13

A dedicated, Debug-only SwiftUI app and XCUITest bundle under [`Tests/PublicHelperPresentationFixture/FixtureHost`](../../../Tests/PublicHelperPresentationFixture/FixtureHost/README.md) host the actual injected production modifier, independently of ordinary LangToolsApp startup. **Three tests passed on each of iPhone 17 and iPad (A16), iOS Simulator 26.3.1**, with no failures or skips. Runtime version and counts were checked in both `.xcresult` summaries, not inferred from the SDK version.

<table>
<tr><th>Viewport</th><th>Default title</th><th>Custom title</th><th>Invalid link</th></tr>
<tr><td>iPhone</td><td><a href="iphone-default-confirmation.png"><img src="iphone-default-confirmation.png" height="240" alt="iPhone default title"></a></td><td><a href="iphone-custom-confirmation.png"><img src="iphone-custom-confirmation.png" height="240" alt="iPhone custom title"></a></td><td><a href="iphone-invalid-link.png"><img src="iphone-invalid-link.png" width="240" alt="iPhone invalid link"></a></td></tr>
<tr><td>iPad</td><td><a href="ipad-default-confirmation.png"><img src="ipad-default-confirmation.png" height="240" alt="iPad default title"></a></td><td><a href="ipad-custom-confirmation.png"><img src="ipad-custom-confirmation.png" height="240" alt="iPad custom title"></a></td><td><a href="ipad-invalid-link.png"><img src="ipad-invalid-link.png" width="240" alt="iPad invalid link"></a></td></tr>
</table>

All six images were inspected: titles, endpoint, consent/capability/security text and controls are readable without clipping. Confirmation images are application screenshots; invalid-link images are native alert-element crops. XCUITest also retains `keepAlways` attachments. These are simulator captures, not physical-device or packaged Botsworth evidence. iPhone uses dark appearance; iPad uses light appearance.

Tests press only the real production Cancel or alert OK, then explicitly refresh fixture diagnostics and assert unchanged revision/helper selection, zero selection callbacks, zero credential-store operations and zero session-factory calls. In-memory storage and a deny-all URL protocol prevent real credential/network I/O even on an accidental Confirm tap. Missing/unknown scenario, wrong bundle, non-Debug build, failed defaults creation or inherited helper selection fail closed before configuration construction. `@testable` is limited to fixture dependency injection; ordinary-import API coverage remains in `PublicHelperAPISmoke`.

[Repeatable commands and setup](../../../Tests/PublicHelperPresentationFixture/FixtureHost/README.md). Final logs: `/tmp/langtools-pr78-fixes/test-xctest-{iphone,ipad}-parent.log`; result bundles: `results-xctest-{iphone,ipad}-parent.xcresult`; both runs exited 0. Earlier failed SPM-only harness attempts are retained under `/tmp/langtools-pr78-fixes/` and the superseded draft under `superseded-spm-draft/`; that attempted host did not mount SwiftUI modals on this setup. A dedicated app/UI-test lifecycle resolved it, without ordinary app startup or macro-trust bypass.

Independent read-only QA verified both result bundles and current source; fixture-safety review found no blocking issues. These are scoped reviews, not a security audit. The new iOS fixture is not wired into hosted CI.

## Boundaries

- Synthetic, non-redeemable payloads only; fresh UUID defaults suites and custom credential namespaces. An inherited selection is rejected before construction. No confirmation, Keychain I/O, network request or listener occurs.
- Default-title evidence uses an injected coordinator; the legacy no-argument `.shared` wiring is compile-checked and code-reviewed, not exercised at runtime.
- Images are attached-sheet content-view layer bitmaps at 2× with Aqua appearance and the actual window background color beneath compositor-backed materials. They are not full screen/compositor captures; shadow, material vibrancy and active-window accent fidelity are not verified. The alert's icon belongs to the test process, not a packaged application.
- The in-process accessibility hierarchy is enabled like the existing ChatUI harness. No cross-process accessibility or screenshot-permission changes are used.
- macOS 14 runtime, iOS 17 runtime and physical-device pairing remain unverified. At head `62376cc`, [hosted CI](https://github.com/rchatham/LangTools.swift/actions/runs/38007370392/job/114079158696) passed 126 app tests including all three AppKit presentation cases, with no skipped AppKit tests. The existing `MobileHelper` filter includes these cases. This confirms that run, not future heads or iOS rendering.
