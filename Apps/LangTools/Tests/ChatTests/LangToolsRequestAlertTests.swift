import Chat
import LangTools
import XCTest

final class LangToolsRequestAlertTests: XCTestCase {
    func testRequestErrorMappingPreservesAppPresentation() {
        let cases: [(LangToolsRequestError, String, String)] = [
            (.multipleChoiceIndexOutOfBounds(7), "Invalid Selection", "The selected choice was out of bounds."),
            (.failedToDecodeFunctionArguments("synthetic arguments"), "Decoding Error", "Failed to decode function arguments."),
            (.missingRequiredFunctionArguments("synthetic name"), "Missing Arguments", "Required function arguments are missing."),
            (.toolIterationLimitReached, "Tool Iteration Limit", "Tool iteration limit reached."),
        ]
        for (error, title, message) in cases {
            let alert = error.chatAlertInfo
            XCTAssertEqual(alert.title, title)
            XCTAssertEqual(alert.message, message)
            XCTAssertNil(alert.textField)
            XCTAssertNil(alert.button)
        }
    }

    func testToolLimitUsesLocalizedErrorDescription() {
        let error = LangToolsRequestError.toolIterationLimitReached
        XCTAssertEqual(error.chatAlertInfo.message, error.localizedDescription)
    }
}
