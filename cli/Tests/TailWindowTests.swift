import XCTest
@testable import CLI

final class TailWindowTests: XCTestCase {

    // MARK: - MessageLineBuilder

    func testAssistantBodyLinesDropsTrailingEmptyLine() {
        let lines = MessageLineBuilder.assistantBodyLines(for: "Hello\nWorld\n")
        XCTAssertEqual(lines, ["Hello", "World"])
    }

    func testAssistantBodyLinesDedentsCommonLeadingWhitespace() {
        let lines = MessageLineBuilder.assistantBodyLines(for: "    line one\n    line two")
        XCTAssertEqual(lines, ["line one", "line two"])
    }

    func testAssistantBodyLinesPreservesRelativeIndentation() {
        let lines = MessageLineBuilder.assistantBodyLines(for: "  title\n    nested\n  back")
        XCTAssertEqual(lines, ["title", "  nested", "back"])
    }

    func testSystemLinesAreSplitOnlyNeverDedented() {
        let lines = MessageLineBuilder.systemLines(for: "  keep indent\n  yes")
        XCTAssertEqual(lines, ["  keep indent", "  yes"])
    }

    func testToolPreviewLinesForCallAreBounded() {
        let long = String(repeating: "x", count: 300)
        let lines = MessageLineBuilder.toolPreviewLines(content: long, isResult: false)
        XCTAssertTrue(lines.count <= 2)
        XCTAssertTrue(lines.last?.hasSuffix("…") ?? false)
    }

    func testToolPreviewLinesForResultAllowMoreRows() {
        let content = "a\nb\nc\nd\ne"
        let lines = MessageLineBuilder.toolPreviewLines(content: content, isResult: true)
        XCTAssertEqual(lines, ["a", "b", "c …"])
    }

    // MARK: - renderedHeight

    func testUserMessageHeightIsOneRow() {
        XCTAssertEqual(ChatTailWindow.renderedHeight(of: ChatMessage(role: .user, content: "hi")), 1)
    }

    func testAssistantMessageHeightIncludesHeaderAndBody() {
        let m = ChatMessage(role: .assistant, content: "one\ntwo\nthree")
        XCTAssertEqual(ChatTailWindow.renderedHeight(of: m), 4)
    }

    func testSystemMessageHeightIsLineCount() {
        let m = ChatMessage(role: .system, content: "a\nb\nc")
        XCTAssertEqual(ChatTailWindow.renderedHeight(of: m), 3)
    }

    func testToolCallHeightIncludesHeaderAndPreview() {
        let m = ChatMessage(role: .toolCall, content: "{\"a\":1}\n{\"b\":2}", toolName: "Bash")
        // header + up to 2 preview lines
        XCTAssertEqual(ChatTailWindow.renderedHeight(of: m), 3)
    }

    // MARK: - tailWindow

    func testEmptyMessagesReturnsEmptyWindow() {
        XCTAssertTrue(ChatTailWindow.tailWindow(messages: [], isStreaming: false, availableHeight: 10).isEmpty)
    }

    func testStreamingReservesOneRow() {
        let msgs = [ChatMessage](repeating: ChatMessage(role: .user, content: "x"), count: 5)
        let window = ChatTailWindow.tailWindow(messages: msgs, isStreaming: true, availableHeight: 3)
        // 3 rows - 1 streaming = 2 user messages fit
        XCTAssertEqual(window.count, 2)
    }

    func testTailWindowKeepsNewestMessages() {
        let msgs = (0..<5).map { ChatMessage(role: .user, content: "msg\($0)") }
        let window = ChatTailWindow.tailWindow(messages: msgs, isStreaming: false, availableHeight: 3)
        XCTAssertEqual(window.map(\.content), ["msg2", "msg3", "msg4"])
    }

    func testTailWindowAlwaysIncludesNewestEvenIfItOverflows() {
        let big = ChatMessage(role: .assistant, content: String(repeating: "line\n", count: 20))
        let window = ChatTailWindow.tailWindow(messages: [big], isStreaming: false, availableHeight: 3)
        XCTAssertEqual(window.count, 1)
        XCTAssertEqual(window.first?.content, big.content)
    }

    func testTailWindowStopsWhenAnOlderMessageNoLongerFits() {
        let msgs = [
            ChatMessage(role: .user, content: "old"),
            ChatMessage(role: .assistant, content: "a\nb\nc\nd"), // 5 rows
            ChatMessage(role: .user, content: "new")
        ]
        let window = ChatTailWindow.tailWindow(messages: msgs, isStreaming: false, availableHeight: 3)
        // newest "new" (1) + assistant (5) won't fit in remaining 2 → stop
        XCTAssertEqual(window.map(\.content), ["new"])
    }

    func testRenderedHeightOfWindowIncludesStreamingRow() {
        let window = [ChatMessage(role: .user, content: "hi")]
        XCTAssertEqual(ChatTailWindow.renderedHeight(of: window, isStreaming: false), 1)
        XCTAssertEqual(ChatTailWindow.renderedHeight(of: window, isStreaming: true), 2)
    }
}