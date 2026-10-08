//
//  LangToolsAppUITests.swift
//  LangToolsAppUITests
//
//  Created by Reid Chatham on 9/23/24.
//

import XCTest

final class LangToolsAppUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    override func tearDownWithError() throws {}

#if !os(macOS)
    @MainActor
    func testPromotedAppLaunch() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["LangTools"].firstMatch.waitForExistence(timeout: 10))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "LangTools app"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testMobileHelperConfirmationFailureAndDirectSettings() throws {
        let app = XCUIApplication()
        app.launch()
        // Synthetic expired/non-redeemable URL: no live QR code or bearer token.
        var components = URLComponents(string: "langtools-example-auth://helper/pair")!
        components.queryItems = [
            .init(name: "v", value: "1"),
            .init(name: "endpoint", value: "https://192.168.255.254:8086"),
            .init(name: "identity", value: "11111111-1111-4111-8111-111111111111"),
            .init(name: "fingerprint", value: String(repeating: "a", count: 64)),
            .init(name: "code", value: String(repeating: "0", count: 64)),
            .init(name: "name", value: "Screenshot Mac"),
        ]
        app.open(try XCTUnwrap(components.url))
        XCTAssertTrue(app.buttons["mobile-helper-confirm"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Pair with Screenshot Mac?"].exists)
        XCTAssertTrue(app.staticTexts["Requested capability: Ollama"].exists)
        keepScreenshot(app, named: "helper-confirmation-iphone16pro")
        app.buttons["Cancel"].tap()

        components.queryItems?.append(.init(name: "unknown", value: "rejected"))
        app.open(try XCTUnwrap(components.url))
        XCTAssertTrue(app.alerts["Helper Pairing Failed"].waitForExistence(timeout: 10))
        keepScreenshot(app, named: "helper-invalid-qr-iphone16pro")
        app.alerts.buttons["OK"].tap()

        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        let models = app.buttons["Manage Ollama Models"]
        if !models.isHittable { app.swipeUp() }
        XCTAssertTrue(models.waitForExistence(timeout: 5))
        models.tap()
        XCTAssertTrue(app.staticTexts["Direct Ollama"].waitForExistence(timeout: 10))
        keepScreenshot(app, named: "helper-direct-alternative-iphone16pro")
    }

    @MainActor
    private func keepScreenshot(_ app: XCUIApplication, named name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
#endif

#if os(macOS)
    @MainActor
    func testAdvancedGenerationSettingsScreenshots() throws {
        let app = XCUIApplication()
        app.launchEnvironment["LANGTOOLS_UI_TEST_MODE"] = "standard"
        app.launch()

        let chatWindow = app.windows.firstMatch
        XCTAssertTrue(chatWindow.waitForExistence(timeout: 10))

        let settingsButton = chatWindow.toolbars.firstMatch.buttons.firstMatch
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        settingsButton.click()

        let settingsWindow = app.windows.allElementsBoundByIndex.last!
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5))

        let advancedBtn = settingsWindow.outlines.firstMatch
            .descendants(matching: .button)
            .matching(NSPredicate(format: "label == 'Advanced'"))
            .firstMatch
        XCTAssertTrue(advancedBtn.waitForExistence(timeout: 5))
        advancedBtn.click()
        sleep(2)

        XCTAssertTrue(settingsWindow.staticTexts["Advanced Parameters"]
            .waitForExistence(timeout: 5), "Advanced tab heading not found")

        // Screenshot: compact checkbox layout with all controls at default
        takeScreenshot(settingsWindow, name: "advanced_params_default")

        // Toggle some checkboxes on to show active state
        for label in ["Temperature", "Top P", "Frequency Penalty", "Seed"] {
            let cb = settingsWindow.checkBoxes[label]
            if cb.waitForExistence(timeout: 2) {
                cb.click()
                sleep(1)
            }
        }
        takeScreenshot(settingsWindow, name: "advanced_params_active")

        settingsWindow.buttons[XCUIIdentifierCloseWindow].click()
    }

    @MainActor
    func testToolSettingsScreenshots() throws {
        let app = XCUIApplication()
        app.launchEnvironment["LANGTOOLS_UI_TEST_MODE"] = "standard"
        app.launch()

        let chatWindow = app.windows.firstMatch
        XCTAssertTrue(chatWindow.waitForExistence(timeout: 10))

        let settingsButton = chatWindow.toolbars.firstMatch.buttons.firstMatch
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        settingsButton.click()

        let settingsWindow = app.windows.allElementsBoundByIndex.last!
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5))

        // Navigate to Tools tab
        let toolsBtn = settingsWindow.outlines.firstMatch
            .descendants(matching: .button)
            .matching(NSPredicate(format: "label == 'Tools'"))
            .firstMatch
        XCTAssertTrue(toolsBtn.waitForExistence(timeout: 5))
        toolsBtn.click()
        sleep(2)

        XCTAssertTrue(settingsWindow.staticTexts["AI Tools"]
            .waitForExistence(timeout: 5), "Tools tab heading not found")

        // Screenshot: tool execution settings at default
        takeScreenshot(settingsWindow, name: "tool_settings_default")

        // Set some values to show active state
        let maxIterField = settingsWindow.textFields.firstMatch
        if maxIterField.waitForExistence(timeout: 3) {
            maxIterField.click()
            maxIterField.typeText("3")
            sleep(1)
        }

        takeScreenshot(settingsWindow, name: "tool_settings_active")

        settingsWindow.buttons[XCUIIdentifierCloseWindow].click()
    }

    private func takeScreenshot(_ element: XCUIElement, name: String) {
        let screenshot = element.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let dirURL = FileManager.default.temporaryDirectory.appendingPathComponent("langtools-screenshots")
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        let path = dirURL.appendingPathComponent("\(name).png").path
        do {
            try screenshot.pngRepresentation.write(to: URL(fileURLWithPath: path))
            print("Screenshot saved: \(path)")
        } catch {
            print("Failed to save \(name): \(error)")
        }
    }
#endif

#if !os(macOS)
    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
#endif
}