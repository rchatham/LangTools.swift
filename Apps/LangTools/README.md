# LangTools app

The official LangTools app for **macOS 14.6+** and **iOS 18+**. It uses the
LangTools library for multi-provider chat, agents, content cards, and voice input.
The app was previously located at `Examples/LangTools_Example`.

## Build and run

From the repository root:

```bash
git submodule update --init --recursive
open LangTools.xcworkspace
```

Select **LangToolsApp**, then My Mac or an iOS simulator/device. The standalone
project is `Apps/LangTools/LangTools.xcodeproj`. Device installation and distribution
require your signing configuration; unsigned builds are useful for compilation checks.

```bash
xcodebuild -workspace LangTools.xcworkspace -scheme LangToolsApp \
  -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
xcodebuild -workspace LangTools.xcworkspace -scheme LangToolsApp \
  -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
swift test
swift test --package-path Apps/LangTools
```

`swift build` inside this directory builds the supporting modules, **not** the
application executable. Build the app using Xcode/the workspace.

## Layout

- `Sources/LangToolsApp.swift`: shared SwiftUI entry point and chat container.
- `Sources/ContentCards`: app-specific content card views.
- `Modules/Chat`: conversation services, settings, and provider integration.
- `Modules/Audio`: voice-input adapters and recording.
- `Modules/ExampleAgents`: existing calendar, reminder, and research agents.
  Its module name is retained to avoid an unrelated API rename.
- `Modules/ToolKit`: tool registration and preferences.
- `ChatUI`: separately maintained submodule; do not vendor edits into this repo.
- `Tests`: hosted identity tests, UI launch tests, and package unit tests.

The core library remains in the repository's top-level `Sources` and `Package.swift`.
No app dependencies are added to library consumers. `LangToolsApp` is the internal
app target/Swift module and package name, preventing a collision with `import LangTools`.
The built application and user-visible name are **LangTools**.

## Compatibility

The application bundle ID remains `com.reidchatham.LangTools-Example`, and the keychain
service remains `com.reidchatham.LangTools_Example`. This intentionally preserves
existing preferences, app-container identity, and credential lookup. The test bundle
IDs, signing team, deployment versions, and sandbox entitlements are also retained.
A future identifier change needs an explicit migration/distribution decision.

The ChatUI gitlink revision is retained while its submodule section and checkout path
move to `Apps/LangTools/ChatUI`. For existing checkouts, save any submodule changes
before switching across the move, then synchronize and initialize the new path:

```bash
git submodule sync -- Apps/LangTools/ChatUI
git submodule update --init --recursive Apps/LangTools/ChatUI
```

An obsolete local `submodule.Examples/LangTools_Example/ChatUI` configuration entry may
remain harmlessly after migration. Do not delete a leftover old submodule directory
without checking it for work. Existing Xcode bookmarks/scheme selections may need updating.

The Xcode dependency lock now matches the app's already-declared JSON.swift `main`
dependency and existing SPM lock. No dependency requirement or ChatUI revision changes.
Historical reorganization notes retain the example's old name as historical context.

## Tests and visual verification

`LangToolsApp` runs the hosted identity test. `LangToolsAppUITests` provides a launch
smoke test that asserts the LangTools title and attaches a screenshot to the result bundle:

```bash
# Replace the destination with an available simulator from `xcrun simctl list devices`.
xcodebuild -workspace LangTools.xcworkspace -scheme LangToolsApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test CODE_SIGNING_ALLOWED=NO
xcodebuild -project Apps/LangTools/LangTools.xcodeproj -scheme LangToolsAppUITests \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:LangToolsAppUITests/LangToolsAppUITests/testPromotedAppLaunch \
  -resultBundlePath /tmp/LangToolsLaunch.xcresult test CODE_SIGNING_ALLOWED=NO
```

Promotion validation: macOS and iOS Simulator builds passed; 253 core tests, 39 app
package tests, the simulator identity test, and simulator UI smoke test passed.
Unsigned simulator launches log expected missing-keychain-entitlement warnings;
credential access still needs a signed-app smoke test. macOS hosted test launches
timed out locally (both unsigned and ad-hoc-signed); macOS runtime tests remain an
open verification item rather than a claimed pass. Existing build warnings include
a missing AccentColor and retroactive content-card conformances.

The [iOS launch screenshot](../../docs/images/langtools-ios-launch.png) was exported
from the passing UI test. Only branding changes here; chat layout is otherwise unchanged.
See [voice input documentation](VOICE_INPUT_README.md) for existing audio integration.
