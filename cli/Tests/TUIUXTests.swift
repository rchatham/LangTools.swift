import XCTest
@testable import CLI

final class TUIUXTests: XCTestCase {
    func testToolDisplayEventsBecomeHierarchicalChatMessages() {
        let call = ChatMessage(toolEvent: .init(
            kind: .call,
            toolName: "read",
            detail: #"{"file_path":"README.md"}"#,
            selectionID: "call-1"
        ))
        let result = ChatMessage(toolEvent: .init(
            kind: .result(isError: true),
            toolName: "read",
            detail: "permission denied",
            selectionID: "call-1"
        ))

        XCTAssertEqual(call.role, .toolCall)
        XCTAssertEqual(call.toolName, "read")
        XCTAssertEqual(result.role, .toolResult)
        XCTAssertTrue(result.toolFailed)
    }

    func testParallelToolResultsAreGroupedUnderTheirCalls() {
        let events: [MessageService.ToolDisplayEvent] = [
            .init(kind: .call, toolName: "Read", detail: "a", selectionID: "a"),
            .init(kind: .call, toolName: "Read", detail: "b", selectionID: "b"),
            .init(kind: .result(isError: false), toolName: "Read", detail: "result b", selectionID: "b"),
            .init(kind: .result(isError: false), toolName: "Read", detail: "result a", selectionID: "a")
        ]

        let ordered = MessageService.hierarchicalToolEvents(events)

        XCTAssertEqual(ordered.map(\.detail), ["a", "result a", "b", "result b"])
    }

    func testToolMessagePreviewIsBoundedAndRetainsDetail() {
        let preview = ToolMessagePreview.lines(
            for: "line one\nline two\nline three",
            limit: 2,
            characterLimit: 100
        )

        XCTAssertEqual(preview, ["line one", "line two …"])
    }
}
