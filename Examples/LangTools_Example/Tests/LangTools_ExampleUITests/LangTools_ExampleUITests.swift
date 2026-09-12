import XCTest

final class LangTools_ExampleUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

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
}
