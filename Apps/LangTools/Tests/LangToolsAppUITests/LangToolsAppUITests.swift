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