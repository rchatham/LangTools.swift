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

        let stopToggle = settingsWindow.checkBoxes["generation.stop.toggle"]
        XCTAssertTrue(stopToggle.waitForExistence(timeout: 5))
        stopToggle.click()
        XCTAssertEqual(checkboxValue(stopToggle), 1)

        let addStop = settingsWindow.buttons["generation.stop.add"]
        XCTAssertTrue(addStop.waitForExistence(timeout: 5))
        addStop.click()
        let stopField = settingsWindow.textFields["generation.stop.sequence.0"]
        XCTAssertTrue(stopField.waitForExistence(timeout: 5))
        XCTAssertEqual(stopField.value as? String, "")
        stopField.click()
        XCTAssertTrue(stopField.exists, "Focusing an Add-created blank draft must not remove it")
        XCTAssertEqual(checkboxValue(stopToggle), 1)
        takeScreenshot(settingsWindow, name: "advanced_stop_blank_focused")

        stopField.typeText("END")
        XCTAssertEqual(stopField.value as? String, "END")
        stopField.typeKey("a", modifierFlags: .command)
        stopField.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(stopField.exists, "Clearing a stop sequence must retain its editing row")
        XCTAssertEqual(stopField.value as? String, "")
        XCTAssertEqual(checkboxValue(stopToggle), 1)
        stopField.typeText("END")
        XCTAssertEqual(stopField.value as? String, "END")
        takeScreenshot(settingsWindow, name: "advanced_stop_retyped")

        // Settings is a navigation destination in the chat's sole window.
        // Closing the window would terminate the fixture rather than exercise persistence.
        print("Settings navigation hierarchy before Back:\n\(settingsWindow.debugDescription)")
        let backButton = settingsWindow.toolbars.firstMatch.buttons["Back"]
        guard backButton.waitForExistence(timeout: 5) else {
            XCTFail("Expected the settings navigation Back toolbar control")
            return
        }
        XCTAssertTrue(backButton.isHittable)
        backButton.click()
        let sidebarGone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: settingsWindow.outlines.firstMatch
        )
        XCTAssertEqual(XCTWaiter.wait(for: [sidebarGone], timeout: 5), .completed)
        let chatSettingsButton = chatWindow.toolbars.firstMatch.buttons["Settings"].firstMatch
        XCTAssertTrue(chatSettingsButton.waitForExistence(timeout: 5))
        let settingsReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"),
            object: chatSettingsButton
        )
        XCTAssertEqual(XCTWaiter.wait(for: [settingsReady], timeout: 5), .completed)
        chatSettingsButton.click()
        let reopenedWindow = app.windows.allElementsBoundByIndex.last!
        XCTAssertTrue(reopenedWindow.waitForExistence(timeout: 5))
        let reopenedAdvanced = reopenedWindow.outlines.firstMatch
            .descendants(matching: .button)
            .matching(NSPredicate(format: "label == 'Advanced'"))
            .firstMatch
        XCTAssertTrue(reopenedAdvanced.waitForExistence(timeout: 5))
        reopenedAdvanced.click()
        let reopenedStop = reopenedWindow.textFields["generation.stop.sequence.0"]
        XCTAssertTrue(reopenedStop.waitForExistence(timeout: 5))
        XCTAssertEqual(reopenedStop.value as? String, "END", "Committed stop must persist on reopen")
        takeScreenshot(reopenedWindow, name: "advanced_stop_reopened")

        let reset = reopenedWindow.buttons["Reset to Automatic"]
        XCTAssertTrue(reset.waitForExistence(timeout: 5))
        reset.click()
        XCTAssertEqual(checkboxValue(reopenedWindow.checkBoxes["generation.stop.toggle"]), 0)
        XCTAssertFalse(reopenedStop.exists)
        XCTAssertFalse(reopenedWindow.buttons["generation.stop.add"].exists)
        takeScreenshot(reopenedWindow, name: "advanced_stop_reset_automatic")
        reopenedWindow.buttons[XCUIIdentifierCloseWindow].click()
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

    private func checkboxValue(_ element: XCUIElement) -> Int? {
        if let number = element.value as? NSNumber {
            if number == NSNumber(value: 0) { return 0 }
            if number == NSNumber(value: 1) { return 1 }
            return nil
        }
        if let string = element.value as? String, let value = Int(string), value == 0 || value == 1 {
            return value
        }
        return nil
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