//
//  LangToolsAppUITests.swift
//  LangToolsAppUITests
//
//  Created by Reid Chatham on 9/23/24.
//

import XCTest

final class LangToolsAppUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

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
    func testCodexBackedChatDisplaysAssistantReply() throws {
        let app = XCUIApplication()
        app.launchEnvironment["LANGTOOLS_UI_TEST_MODE"] = "codexSuccess"
        app.launch()

        let input = app.descendants(matching: .any)["chat.promptInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.click()
        input.typeText("Reply with exactly OK")

        let sendButton = app.buttons["chat.sendButton"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 2))
        sendButton.click()

        XCTAssertTrue(app.staticTexts["OK"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testCodexNotLoggedInDisplaysHelpfulAlert() throws {
        let app = XCUIApplication()
        app.launchEnvironment["LANGTOOLS_UI_TEST_MODE"] = "codexNotLoggedIn"
        app.launch()

        let input = app.descendants(matching: .any)["chat.promptInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.click()
        input.typeText("Test auth failure")

        let sendButton = app.buttons["chat.sendButton"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 2))
        sendButton.click()

        XCTAssertTrue(app.staticTexts["OpenAI Account Error"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Codex is not logged in.")).firstMatch.waitForExistence(timeout: 2))
    }
#endif

#if !os(macOS)
    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
#endif
}
