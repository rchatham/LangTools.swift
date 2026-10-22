import UIKit
import XCTest

/// Drives the real `PresentationFixtureHost` app (a minimal, Debug-only
/// fixture — not LangToolsApp) through XCUITest, exercising the actual
/// production `mobileHelperPairingPresentation` modifier. Only the real
/// Cancel/"OK" controls are tapped; Confirm is never tapped. Diagnostic
/// labels exposed by the fixture host (never the production modal itself)
/// are read, after an explicit fixture-only "Refresh Diagnostics" tap, to
/// assert zero credential/session/callback side effects.
final class MobileHelperPairingPresentationUITests: XCTestCase {
    enum ScreenshotError: Error, CustomStringConvertible {
        case invalidArtifactDirectory(String)
        case directoryCreationFailed(String, Error)
        case pngEncodingUnavailable
        case writeFailed(String, Error)

        var description: String {
            switch self {
            case .invalidArtifactDirectory(let path):
                return "Refusing to write a screenshot outside the expected artifact directory: \(path)"
            case .directoryCreationFailed(let path, let error):
                return "Could not create artifact directory \(path): \(error)"
            case .pngEncodingUnavailable:
                return "XCUIScreenshot had no PNG representation"
            case .writeFailed(let path, let error):
                return "Could not write screenshot to \(path): \(error)"
            }
        }
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testDefaultTitleConfirmationSheetAndCancel() throws {
        try runConfirmationScenario(scenario: "defaultTitle", title: "Connect LangToolsHelper",
            artifact: "default-confirmation")
    }

    func testCustomTitleConfirmationSheetAndCancel() throws {
        try runConfirmationScenario(scenario: "customTitle", title: "Connect Botsworth Helper",
            artifact: "custom-confirmation")
    }

    func testInvalidLinkPresentsFailureWithoutPairing() throws {
        let app = XCUIApplication()
        app.launchEnvironment["FIXTURE_SCENARIO"] = "invalid"
        app.launch()

        let alert = app.alerts["Helper Pairing Failed"]
        XCTAssertTrue(alert.waitForExistence(timeout: 15), "Production failure alert did not appear")
        let messagePredicate = NSPredicate(format: "label CONTAINS[c] %@", "Invalid helper pairing QR")
        XCTAssertTrue(alert.staticTexts.containing(messagePredicate).firstMatch.exists,
            "Alert message missing expected text")
        XCTAssertFalse(alert.buttons["Confirm"].exists, "Invalid-link alert must not expose a Confirm action")

        try attachScreenshot(named: "invalid-link", of: alert)

        // Exercise only the real "OK" control. Confirm does not exist on this alert.
        alert.buttons["OK"].tap()
        XCTAssertFalse(app.alerts["Helper Pairing Failed"].waitForExistence(timeout: 3),
            "Failure alert should dismiss after OK")

        try refreshDiagnosticsAndAssertStillDismissed(app: app, navigationBarTitle: nil)
        assertZeroSideEffects(app: app)
    }

    // MARK: - Shared confirmation-sheet flow

    private func runConfirmationScenario(scenario: String, title: String, artifact: String) throws {
        let app = XCUIApplication()
        app.launchEnvironment["FIXTURE_SCENARIO"] = scenario
        app.launch()

        let navBar = app.navigationBars[title]
        XCTAssertTrue(navBar.waitForExistence(timeout: 15), "Production confirmation sheet title not found: \(title)")

        let confirmButton = app.buttons["mobile-helper-confirm"]
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 5), "Production Confirm control not found")

        for text in [
            "Pair with Synthetic Verification iPhone?",
            "192.168.255.254:8086",
            "Requested capability: Ollama",
            "Pair and Use Helper",
            "Allow this Mac to provide Ollama models and process your chats. Confirm only if you scanned this QR from your trusted Mac.",
            "Encrypted connection pinned to this helper's certificate. No account, filesystem, or command access is granted.",
        ] {
            let predicate = NSPredicate(format: "label CONTAINS[c] %@", text)
            let found = app.staticTexts.containing(predicate).firstMatch.exists
                || app.buttons.containing(predicate).firstMatch.exists
            XCTAssertTrue(found, "Missing production sheet text: \(text)")
        }

        let cancelButton = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancelButton.exists, "Production Cancel control not found")

        try attachScreenshot(named: artifact, of: app)

        // Exercise only the real production Cancel control. Confirm is never tapped.
        cancelButton.tap()

        XCTAssertFalse(app.navigationBars[title].waitForExistence(timeout: 3),
            "Sheet should dismiss after Cancel")

        try refreshDiagnosticsAndAssertStillDismissed(app: app, navigationBarTitle: title)
        assertZeroSideEffects(app: app)
    }

    // MARK: - Fixture-only diagnostics refresh (not production UI, not a fake Cancel)

    /// Taps the fixture-only "Refresh Diagnostics" control so the diagnostic
    /// labels reflect current state rather than values cached at the view's
    /// initial render (the nested counters/configuration are not themselves
    /// `@Published`). Then re-confirms the real production sheet/alert is
    /// still dismissed and was not retriggered by the refresh.
    private func refreshDiagnosticsAndAssertStillDismissed(app: XCUIApplication, navigationBarTitle: String?) throws {
        let refreshButton = app.buttons["fixture-refresh-diagnostics"]
        XCTAssertTrue(refreshButton.waitForExistence(timeout: 5), "Fixture refresh-diagnostics control not found")
        refreshButton.tap()

        if let navigationBarTitle {
            XCTAssertFalse(app.navigationBars[navigationBarTitle].exists,
                "Refreshing diagnostics must not retrigger the production sheet")
        }
        XCTAssertFalse(app.alerts["Helper Pairing Failed"].exists,
            "Refreshing diagnostics must not retrigger the production alert")
    }

    // MARK: - Diagnostics (fixture-host-only; not production UI)

    private func assertZeroSideEffects(app: XCUIApplication) {
        func label(_ identifier: String) -> String {
            let element = app.staticTexts[identifier]
            XCTAssertTrue(element.waitForExistence(timeout: 5), "Diagnostic label missing: \(identifier)")
            return element.label
        }
        XCTAssertEqual(label("diagnostic-selections"), "selections:0", "didSelect callback must never fire")
        XCTAssertEqual(label("diagnostic-load-count"), "loadCount:0", "No Keychain-equivalent load may occur")
        XCTAssertEqual(label("diagnostic-save-count"), "saveCount:0", "No credential save may occur")
        XCTAssertEqual(label("diagnostic-remove-count"), "removeCount:0", "No credential removal may occur")
        XCTAssertEqual(label("diagnostic-session-count"), "sessionCount:0", "No network session may be created")

        let revision = label("diagnostic-revision").replacingOccurrences(of: "revision:", with: "")
        let initialRevision = label("diagnostic-initial-revision").replacingOccurrences(of: "initialRevision:", with: "")
        XCTAssertEqual(revision, initialRevision, "Configuration revision must be unchanged")

        let helperID = label("diagnostic-helper-id").replacingOccurrences(of: "helperID:", with: "")
        let initialHelperID = label("diagnostic-initial-helper-id").replacingOccurrences(of: "initialHelperID:", with: "")
        XCTAssertEqual(helperID, initialHelperID, "Configuration helper selection must be unchanged")
    }

    // MARK: - Screenshot capture

    /// The single exact (not prefix-matched) directory screenshots may be
    /// written to. `xcodebuild`'s invoking shell environment does not
    /// propagate into the XCUITest runner process (confirmed empirically),
    /// so this is a literal constant rather than read from the environment.
    private static let artifactDirectory = "/tmp/langtools-pr78-fixes/ios-presentation"

    private func attachScreenshot(named name: String, of element: XCUIElement) throws {
        let screenshot = element.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let directory = URL(fileURLWithPath: Self.artifactDirectory, isDirectory: true).standardizedFileURL
        guard directory.path == Self.artifactDirectory else {
            throw ScreenshotError.invalidArtifactDirectory(directory.path)
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ScreenshotError.directoryCreationFailed(directory.path, error)
        }
        guard let data = screenshot.pngRepresentation as Data? else {
            throw ScreenshotError.pngEncodingUnavailable
        }
        let idiom = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let path = directory.appendingPathComponent("\(idiom)-\(name).png")
        do {
            try data.write(to: path, options: .atomic)
        } catch {
            throw ScreenshotError.writeFailed(path.path, error)
        }
        print("Production UI screenshot: \(path.path)")
    }
}
