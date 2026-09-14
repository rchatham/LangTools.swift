//
//  TailWindowTests.swift
//  CLI
//
//  Focused tests for the tail-window message selection and alignment helpers.
//

import XCTest
@testable import CLI

final class TailWindowTests: XCTestCase {

    // MARK: - Tail window selection

    func testTailWindowReturnsAllMessagesWhenEverythingFits() {
        let messages: [ChatMessage] = [
            ChatMessage(role: .user, content: "hi"),            // 1 row
            ChatMessage(role: .assistant, content: "hello back") // 1 (header) + 1 (body) = 2 rows
        ]
        // 3 rows used, plenty available.
        let window = ChatTailWindow.tailWindow(messages: messages, isStreaming: false, availableHeight: 24)
        XCTAssertEqual(window.map(\.role), [.user, .assistant])
    }

    func testTailWindowDropsOldestMessagesThatDoNotFit() {
        // Each assistant message is header(1) + body(1) = 2 rows.
        let messages: [ChatMessage] = (0..<10).map {
            ChatMessage(role: .assistant, content: "line \($0)")
        }
        // 4 rows available -> at most 2 assistant messages (2 rows each).
        let window = ChatTailWindow.tailWindow(messages: messages, isStreaming: false, availableHeight: 4)
        XCTAssertEqual(window.count, 2)
        // Most recent two retained, in order.
        XCTAssertEqual(window[0].content, "line 8")
        XCTAssertEqual(window[1].content, "line 9")
    }

    func testTailWindowAlwaysIncludesNewestEvenIfItOverflows() {
        // Newest message is taller than the whole budget.
        let newest = ChatMessage(role: .assistant, content: "a\nb\nc\nd\ne") // 1 header + 5 body = 6 rows
        let messages: [ChatMessage] = [
            ChatMessage(role: .user, content: "old"), // would fit (1 row) but is older
            newest,
        ]
        let window = ChatTailWindow.tailWindow(messages: messages, isStreaming: false, availableHeight: 3)
        XCTAssertEqual(window.count, 1)
        XCTAssertEqual(window.first?.content, "a\nb\nc\nd\ne")
    }

    func testTailWindowReservesARowForStreamingIndicator() {
        // Assistant = 2 rows each. Available 5 with streaming -> reserve 1 -> 4 usable -> 2 messages.
        let messages: [ChatMessage] = (0..<5).map {
            ChatMessage(role: .assistant, content: "m\($0)")
        }
        let window = ChatTailWindow.tailWindow(messages: messages, isStreaming: true, availableHeight: 5)
        XCTAssertEqual(window.count, 2)
        XCTAssertEqual(window.last?.content, "m4")
    }

    func testTailWindowEmptyMessagesReturnsEmpty() {
        let window = ChatTailWindow.tailWindow(messages: [], isStreaming: false, availableHeight: 24)
        XCTAssertTrue(window.isEmpty)
    }

    func testTailWindowPreservesOrder() {
        let messages: [ChatMessage] = [
            ChatMessage(role: .user, content: "1"),
            ChatMessage(role: .assistant, content: "2"),
            ChatMessage(role: .user, content: "3"),
        ]
        let window = ChatTailWindow.tailWindow(messages: messages, isStreaming: false, availableHeight: 24)
        XCTAssertEqual(window.map(\.content), ["1", "2", "3"])
    }

    // MARK: - Rendered height

    func testRenderedHeightMatchesViewStructure() {
        XCTAssertEqual(ChatTailWindow.renderedHeight(of: ChatMessage(role: .user, content: "hi")), 1)

        // Assistant: header + one body line.
        XCTAssertEqual(ChatTailWindow.renderedHeight(of: ChatMessage(role: .assistant, content: "hi")), 2)

        // Assistant with multiple body lines.
        XCTAssertEqual(ChatTailWindow.renderedHeight(of: ChatMessage(role: .assistant, content: "a\nb\nc")), 4)

        // Empty assistant content: header only (trailing empty line dropped).
        XCTAssertEqual(ChatTailWindow.renderedHeight(of: ChatMessage(role: .assistant, content: "")), 1)

        // System: one row per line.
        XCTAssertEqual(ChatTailWindow.renderedHeight(of: ChatMessage(role: .system, content: "x\ny")), 2)

        // Tool call: header + bounded preview lines.
        let call = ChatMessage(role: .toolCall, content: "one\ntwo\nthree\nfour", toolName: "read")
        XCTAssertEqual(ChatTailWindow.renderedHeight(of: call), 1 + 2) // call limit = 2

        // Tool result: header + bounded preview lines (result limit = 3).
        let result = ChatMessage(role: .toolResult, content: "one\ntwo\nthree\nfour", toolName: "read")
        XCTAssertEqual(ChatTailWindow.renderedHeight(of: result), 1 + 3) // result limit = 3
    }

    // MARK: - Available height fallback

    func testAvailableHeightUsesLayoutSizeWhenUsable() {
        XCTAssertEqual(ChatTailWindow.availableHeight(layoutHeight: 30, fallback: TerminalSize.defaultRows), 30)
    }

    func testAvailableHeightFallsBackWhenLayoutNotReady() {
        XCTAssertEqual(ChatTailWindow.availableHeight(layoutHeight: 1, fallback: 40), 40)
        XCTAssertEqual(ChatTailWindow.availableHeight(layoutHeight: 1, fallback: TerminalSize.defaultRows), TerminalSize.defaultRows)
    }

    // MARK: - Alignment helpers

    func testAssistantBodyLinesDedentsCommonLeadingIndentation() {
        let lines = MessageLineBuilder.assistantBodyLines(for: "    line one\n    line two\n      nested")
        XCTAssertEqual(lines, ["line one", "line two", "  nested"])
    }

    func testAssistantBodyLinesPreservesUnindentedContent() {
        let lines = MessageLineBuilder.assistantBodyLines(for: "first\nsecond")
        XCTAssertEqual(lines, ["first", "second"])
    }

    func testAssistantBodyLinesDropsTrailingEmptyLine() {
        let lines = MessageLineBuilder.assistantBodyLines(for: "first\n")
        XCTAssertEqual(lines, ["first"])
    }

    func testAssistantBodyLinesEmptyContentYieldsNoBodyRows() {
        let lines = MessageLineBuilder.assistantBodyLines(for: "")
        XCTAssertTrue(lines.isEmpty)
    }

    func testToolBodyIndentAlignsUnderHeaderPrefix() {
        // Call header has no leading spaces -> body flush at column 0.
        XCTAssertEqual(MessageLineBuilder.bodyIndent(forPrefix: "↳ Call"), "")
        // Result header is nested two spaces -> body indented two spaces.
        XCTAssertEqual(MessageLineBuilder.bodyIndent(forPrefix: "  ✓ Result"), "  ")
        XCTAssertEqual(MessageLineBuilder.bodyIndent(forPrefix: "  ✗ Result"), "  ")
    }

    func testToolPreviewLinesRespectsResultAndCallLimits() {
        let content = "one\ntwo\nthree\nfour"
        // Call limit = 2 lines.
        XCTAssertEqual(MessageLineBuilder.toolPreviewLines(content: content, isResult: false), ["one", "two …"])
        // Result limit = 3 lines.
        XCTAssertEqual(MessageLineBuilder.toolPreviewLines(content: content, isResult: true), ["one", "two", "three …"])
    }

    func testDedentedPreservesRelativeIndentation() {
        let dedented = MessageLineBuilder.dedented(["  a", "    b", "  c"])
        XCTAssertEqual(dedented, ["a", "  b", "c"])
    }

    func testDedentedNoCommonIndentIsNoOp() {
        let dedented = MessageLineBuilder.dedented(["a", "  b", "c"])
        XCTAssertEqual(dedented, ["a", "  b", "c"])
    }
}