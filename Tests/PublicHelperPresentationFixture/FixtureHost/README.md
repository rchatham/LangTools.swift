# PresentationFixtureHost — isolated iOS presentation fixture

Minimal, Debug-only Xcode project (App target + UI Testing Bundle) used only
to render and inspect the real production
`mobileHelperPairingPresentation(coordinator:brandingTitle:)` modifier from
`Chat`, plus the actual ChatUI composer for request-error alerts, on isolated
iOS simulators. **Not LangToolsApp.** No ordinary app startup,
no `.shared` coordinator/settings/services/Keychain/discovery.

## What this is / is not

- Is: a from-scratch SwiftUI app hosting the real pairing modifier or real
  composer/error handler, plus a real XCUITest UI Testing Bundle that drives it.
- Is not: a replica of the production sheet/alert, a fake Cancel/Confirm
  action, or a path to any real credential/network I/O (the injected
  credential store is in-memory only; the injected session's transport is
  denied unconditionally by a custom `URLProtocol`, even on an accidental
  Confirm tap — which the tests never do anyway).
- `@testable import Chat` is used only to reach two internal dependency-
  injection initializers (`OllamaEndpointConfiguration(userDefaults:credentialStore:)`
  and `MobileHelperPairingCoordinator(configuration:scheme:client:didSelect:)`);
  `@testable import ChatUI` in the shared test-only
  `RequestErrorPresentationFixture.swift` reaches the real internal composer,
  using an inert service that delegates to the same `chatAlertInfo` mapper as
  the app. No ChatUI source change, ordinary service or voice handler is used.
  `ENABLE_TESTABILITY` is a legitimate Debug build setting, not a macro-trust
  bypass.

## Regenerating the project

The checked-in source of truth is `project.yml`; `PresentationFixtureHost.xcodeproj`
is generated and kept in version control (so a fresh checkout doesn't require
`xcodegen` to just build/run it), but must be regenerated after any
`project.yml` or added/removed source-file change:

```bash
brew install xcodegen   # if not already installed
cd Tests/PublicHelperPresentationFixture/FixtureHost
xcodegen generate
```

## Choosing simulator device IDs

The commands below need **your own currently-booted-or-bootable simulator
UDIDs** substituted in place of `<IPHONE_UDID>` / `<IPAD_UDID>` — do not reuse
UDIDs from another machine. List available devices and pick fresh ones:

```bash
xcrun simctl list devices available
```

## Build

```bash
cd Tests/PublicHelperPresentationFixture/FixtureHost
xcodebuild build-for-testing \
  -project PresentationFixtureHost.xcodeproj \
  -scheme PresentationFixtureHost \
  -destination 'platform=iOS Simulator,id=<IPHONE_UDID>' \
  -derivedDataPath /tmp/<your-own-derived-data-dir> \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

## Run the UI tests (one destination = one device class per invocation)

```bash
xcodebuild test \
  -project PresentationFixtureHost.xcodeproj \
  -scheme PresentationFixtureHost \
  -destination 'platform=iOS Simulator,id=<IPHONE_UDID>' \
  -derivedDataPath /tmp/<your-own-derived-data-dir> \
  -resultBundlePath /tmp/<your-own-result-bundle>.xcresult \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

Repeat with an iPad destination UDID for the second device class. All 4 test
cases (`testDefaultTitleConfirmationSheetAndCancel`,
`testCustomTitleConfirmationSheetAndCancel`,
`testInvalidLinkPresentsFailureWithoutPairing`,
`testToolIterationLimitAlertAndCancel`) run per invocation. The `toolIterationLimit`
scenario uses dark appearance on iPhone and light on iPad, without changing
simulator settings. It invokes the real composer's error handler with
`LangToolsRequestError.toolIterationLimitReached`, verifies the production
mapping's title/message and actual **Cancel** dismissal, then checks one mapping
and zero unexpected service/credential/session/selection operations.

If a destination simulator is in a stale `Shutdown` state and `xcodebuild`
reports a transient `FBSOpenApplicationServiceErrorDomain ... Busy` launch
failure, boot it directly first (ordinary lifecycle boot of the *same*
already-existing simulator — not an erase/reset of its content) and retry:

```bash
xcrun simctl boot <UDID>
```

## Screenshots

`MobileHelperPairingPresentationUITests.attachScreenshot` writes PNGs to the
single hardcoded, exact-path-validated directory
`/tmp/langtools-pr78-fixes/ios-presentation/<iphone|ipad>-<scenario>.png`,
and also attaches each one to the test as an `XCTAttachment` with
`.lifetime = .keepAlways` (visible in the `.xcresult`). The path is hardcoded
rather than read from an environment variable because `xcodebuild test`'s
invoking shell environment does not propagate into the XCUITest runner
process (confirmed empirically). Copy the PNGs you need out of that directory
after a run; nothing here publishes them anywhere automatically.

## Boundaries / safety

- Fresh, UUID-suffixed `UserDefaults` suite per launch; construction
  fails closed (crashes the fixture process on purpose) if a suite can't be
  created, if it unexpectedly has an inherited helper selection, if
  `FIXTURE_SCENARIO` is missing/unrecognized, if the bundle identifier
  doesn't match this fixture's own, or if not a Debug build.
- Confirm is never tapped by any test. Only the real Cancel ("Cancel") or
  pairing-failure alert "OK" control is tapped. The tool-limit composer alert
  genuinely uses Cancel, not OK.
- The fixture-only "Refresh Diagnostics" button (`fixture-refresh-diagnostics`)
  is not part of, and never embedded in, the production modal; it only forces
  a SwiftUI re-render of the diagnostic labels and is tapped after Cancel/OK,
  before the zero-side-effect assertions. It does not retrigger the
  production sheet/alert (each test re-checks dismissal after tapping it).
- No real Keychain access, no real network I/O (denied unconditionally by a
  custom `URLProtocol`, independent of whether Confirm is ever tapped), no
  `.shared` production services, no simulator erase/reset, no production
  source changes.
