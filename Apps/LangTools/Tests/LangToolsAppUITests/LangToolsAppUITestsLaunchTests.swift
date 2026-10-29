//
//  LangToolsAppUITestsLaunchTests.swift
//  LangToolsAppUITests
//
//  Created by Reid Chatham on 9/23/24.
//

import XCTest

final class LangToolsAppUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        #if os(macOS)
        // The template's appearance matrix changes the entire desktop and
        // synchronizes unrelated apps. Keep the Mac fixture launch isolated.
        false
        #else
        true
        #endif
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        #if os(macOS)
        app.launchEnvironment["LANGTOOLS_UI_TEST_MODE"] = "standard"
        #endif
        app.launch()

        // Insert steps here to perform after app launch but before taking a screenshot,
        // such as logging into a test account or navigating somewhere in the app

        let window = app.windows.firstMatch
        guard window.waitForExistence(timeout: 10) else {
            XCTFail("Expected the fixture app window before capturing its launch screen")
            return
        }
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
