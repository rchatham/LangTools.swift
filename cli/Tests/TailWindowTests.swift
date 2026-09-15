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

    // MARK: - Wrapping estimates

    func testDisplayWidthCountsASCIIAsOne() {
        XCTAssertEqual(MessageLineBuilder.displayWidth(of: "hello"), 5)
    }

    func testDisplayWidthCountsWideCharactersAsTwo() {
        XCTAssertEqual(MessageLineBuilder.displayWidth(of: "你好"), 4)
        XCTAssertEqual(MessageLineBuilder.displayWidth(of: "👍"), 2)
    }

    func testWrappedRowCountSplitsLongLines() {
        // 60 characters at width 40 → two rows.
        let line = String(repeating: "a", count: 60)
        XCTAssertEqual(MessageLineBuilder.wrappedRowCount(of: line, width: 40), 2)
    }

    func testWrappedRowCountNeverReturnsZeroEvenForEmptyLines() {
        XCTAssertEqual(MessageLineBuilder.wrappedRowCount(of: "", width: 40), 1)
    }

    func testWrappedRowCountAccountsForFirstLinePrefix() {
        let line = String(repeating: "a", count: 40)
        // A 5-column prefix on the first row forces an extra wrap row.
        XCTAssertEqual(MessageLineBuilder.wrappedRowCount(of: line, width: 40, firstLinePrefixColumns: 5), 2)
    }

    func testWrapSegmentsNeverExceedWidth() {
        let line = String(repeating: "ab", count: 40) // 80 columns
        let segments = MessageLineBuilder.wrapSegments(of: line, width: 30)
        XCTAssertEqual(segments.reduce(0) { max($0, MessageLineBuilder.displayWidth(of: $1)) }, 30)
    }

    func testTailWrappedRowsKeepsNewestContent() {
        let line = (1...10).map { "row\($0)" }.joined(separator: "\n")
        let rows = MessageLineBuilder.tailWrappedRows(ofLines: line.components(separatedBy: "\n"), width: 40, maxRows: 3)
        XCTAssertEqual(rows, ["row8", "row9", "row10"])
    }

    // MARK: - renderedRows (wrap-aware)

    func testShortUserMessageIsOneRow() {
        XCTAssertEqual(ChatTailWindow.renderedRows(of: ChatMessage(role: .user, content: "hi"), width: 60), 1)
    }

    func testLongUserMessageCountsWrappedRows() {
        let long = String(repeating: "a", count: 120)
        // 120 columns of content in a 55-column field → 3 rows.
        XCTAssertEqual(ChatTailWindow.renderedRows(of: ChatMessage(role: .user, content: long), width: 60), 3)
    }

    func testAssistantMessageHeightIncludesHeaderAndWrappedBody() {
        let m = ChatMessage(role: .assistant, content: "one\ntwo\nthree")
        XCTAssertEqual(ChatTailWindow.renderedRows(of: m, width: 60), 4)
    }

    func testAssistantLongLineCountsWrappedRows() {
        let long = String(repeating: "a", count: 150)
        let m = ChatMessage(role: .assistant, content: long)
        // header + ceil(150/60) = 1 + 3
        XCTAssertEqual(ChatTailWindow.renderedRows(of: m, width: 60), 4)
    }

    func testSystemMessageHeightIsAtLeastOneRow() {
        XCTAssertEqual(ChatTailWindow.renderedRows(of: ChatMessage(role: .system, content: "a\nb\nc"), width: 60), 3)
        XCTAssertEqual(ChatTailWindow.renderedRows(of: ChatMessage(role: .system, content: ""), width: 60), 1)
    }

    func testToolCallHeightIncludesHeaderAndWrappedPreview() {
        let m = ChatMessage(role: .toolCall, content: "{\"a\":1}\n{\"b\":2}", toolName: "Bash")
        // header + 2 preview lines (each short enough to fit)
        XCTAssertEqual(ChatTailWindow.renderedRows(of: m, width: 60), 3)
    }

    func testToolResultLongPreviewCountsWrappedRows() {
        // Result previews cap content at 500 characters; a single 500-char
        // line at width 40 wraps to ceil(500/38) = 14 rows → header + 14.
        let long = String(repeating: "x", count: 500)
        let m = ChatMessage(role: .toolResult, content: long, toolName: "Bash")
        XCTAssertEqual(ChatTailWindow.renderedRows(of: m, width: 40), 15)
    }

    // MARK: - tailWindow selection

    func testEmptyMessagesReturnsEmptyWindow() {
        let window = ChatTailWindow.tailWindow(messages: [], isStreaming: false, availableHeight: 10, availableWidth: 60)
        XCTAssertTrue(window.messages.isEmpty)
        XCTAssertNil(window.clipLastMessageToRows)
    }

    func testStreamingReservesOneRow() {
        let msgs = [ChatMessage](repeating: ChatMessage(role: .user, content: "x"), count: 5)
        let window = ChatTailWindow.tailWindow(messages: msgs, isStreaming: true, availableHeight: 3, availableWidth: 60)
        // 3 rows - 1 streaming = 2 user messages fit
        XCTAssertEqual(window.messages.count, 2)
        XCTAssertNil(window.clipLastMessageToRows)
    }

    func testTailWindowKeepsNewestMessages() {
        let msgs = (0..<5).map { ChatMessage(role: .user, content: "msg\($0)") }
        let window = ChatTailWindow.tailWindow(messages: msgs, isStreaming: false, availableHeight: 3, availableWidth: 60)
        XCTAssertEqual(window.messages.map(\.content), ["msg2", "msg3", "msg4"])
    }

    func testNewestMessageAloneOverBudgetIsClipped() {
        // A 30-row assistant message in a 10-row budget: the selection keeps
        // only the newest message, clipped to the budget, never unbounded.
        let big = ChatMessage(role: .assistant, content: String(repeating: "line\n", count: 30))
        let window = ChatTailWindow.tailWindow(messages: [big], isStreaming: false, availableHeight: 10, availableWidth: 60)
        XCTAssertEqual(window.messages.count, 1)
        XCTAssertEqual(window.clipLastMessageToRows, 10)

        let rows = ChatTailWindow.clippedRows(for: big, width: 60, maxRows: window.clipLastMessageToRows!)
        XCTAssertEqual(rows.count, 10)
        // Header + newest body rows; the newest content is kept.
        XCTAssertEqual(rows.first, "Assistant:")
        XCTAssertTrue(rows.last?.hasSuffix("line") ?? false)
    }

    func testNewestMessageClippedToAtLeastOneRow() {
        let big = ChatMessage(role: .assistant, content: String(repeating: "line\n", count: 30))
        let window = ChatTailWindow.tailWindow(messages: [big], isStreaming: false, availableHeight: 1, availableWidth: 60)
        XCTAssertEqual(window.messages.count, 1)
        XCTAssertEqual(window.clipLastMessageToRows, 1)
    }

    func testClippedUserMessageKeepsNewestWrappedRows() {
        let long = String(repeating: "a", count: 120)
        let m = ChatMessage(role: .user, content: long)
        let rows = ChatTailWindow.clippedRows(for: m, width: 60, maxRows: 2)
        XCTAssertEqual(rows.count, 2)
        // Newest content is kept: the last row reaches the end of the content.
        XCTAssertEqual(rows.last, String(repeating: "a", count: 60))
        XCTAssertTrue(rows.allSatisfy { MessageLineBuilder.displayWidth(of: $0) <= 60 })
    }

    func testClippedToolMessageKeepsHeaderAndNewestPreviewRows() {
        let long = String(repeating: "x", count: 500)
        let m = ChatMessage(role: .toolResult, content: long, toolName: "Bash", toolFailed: true)
        let rows = ChatTailWindow.clippedRows(for: m, width: 40, maxRows: 5)
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows.first, "  ✗ Result Bash")
        XCTAssertEqual(rows.dropFirst().count, 4)
    }

    func testClippedRowsForClippedMessageNeverExceedBudget() {
        // For every budget the clipped rendering must stay within it.
        let m = ChatMessage(role: .assistant, content: String(repeating: "word ", count: 200))
        for maxRows in 1...12 {
            let rows = ChatTailWindow.clippedRows(for: m, width: 60, maxRows: maxRows)
            XCTAssertLessThanOrEqual(rows.count, maxRows)
            XCTAssertTrue(rows.allSatisfy { MessageLineBuilder.displayWidth(of: $0) <= 60 })
        }
    }

    func testTailWindowStopsWhenAnOlderMessageNoLongerFits() {
        let msgs = [
            ChatMessage(role: .user, content: "old"),
            ChatMessage(role: .assistant, content: "a\nb\nc\nd"), // 5 rows
            ChatMessage(role: .user, content: "new")
        ]
        let window = ChatTailWindow.tailWindow(messages: msgs, isStreaming: false, availableHeight: 3, availableWidth: 60)
        // newest "new" (1) + assistant (5) won't fit in remaining 2 → stop
        XCTAssertEqual(window.messages.map(\.content), ["new"])
    }

    func testRenderedRowsOfWindowIncludesStreamingRow() {
        let selection = ChatTailWindow.Selection(
            messages: [ChatMessage(role: .user, content: "hi")],
            clipLastMessageToRows: nil
        )
        XCTAssertEqual(ChatTailWindow.renderedRows(of: selection, isStreaming: false, width: 60), 1)
        XCTAssertEqual(ChatTailWindow.renderedRows(of: selection, isStreaming: true, width: 60), 2)
    }

    // MARK: - Overflow invariants (regression: Renderer.drawPixel trap)

    /// The selected window's rendered rows never exceed the available budget,
    /// even with adversarial content (long lines, tall messages, mixed roles).
    func testSelectionNeverExceedsAvailableHeight() {
        var messages: [ChatMessage] = []
        messages.append(ChatMessage(role: .system, content: String(repeating: "x", count: 500)))
        for i in 0..<40 {
            switch i % 4 {
            case 0: messages.append(ChatMessage(role: .user, content: String(repeating: "y", count: 300)))
            case 1: messages.append(ChatMessage(role: .assistant, content: String(repeating: "para \(i)\n", count: 12)))
            case 2: messages.append(ChatMessage(role: .toolCall, content: String(repeating: "{\"k\":", count: 40), toolName: "Bash"))
            default: messages.append(ChatMessage(role: .toolResult, content: String(repeating: "out ", count: 130), toolName: "Bash"))
            }
        }

        for height in 1...30 {
            for streaming in [false, true] {
                let window = ChatTailWindow.tailWindow(
                    messages: messages,
                    isStreaming: streaming,
                    availableHeight: height,
                    availableWidth: 60
                )
                let total = ChatTailWindow.renderedRows(of: window, isStreaming: streaming, width: 60)
                XCTAssertLessThanOrEqual(total, height, "overflow at height=\(height) streaming=\(streaming)")
            }
        }
    }

    /// A full history in a small window still renders every selected message
    /// within budget — the exact scenario that crashed before the fix.
    func testFullHistoryInSmallWindowStaysInBudget() {
        var messages: [ChatMessage] = []
        for i in 0..<30 {
            messages.append(ChatMessage(role: .user, content: "question \(i)"))
            messages.append(ChatMessage(role: .assistant, content: "answer \(i)\nwith a second line\nand a third"))
        }
        let window = ChatTailWindow.tailWindow(messages: messages, isStreaming: false, availableHeight: 8, availableWidth: 60)
        let total = ChatTailWindow.renderedRows(of: window, isStreaming: false, width: 60)
        XCTAssertLessThanOrEqual(total, 8)
        // The newest answer is present.
        XCTAssertEqual(window.messages.last?.content, "answer 29\nwith a second line\nand a third")
    }

    // MARK: - Footer budget

    func testFooterBudgetCoversWorstCaseFooter() {
        // padding(2)=4, separator 1, info 1, input+hint 2, status 1,
        // approval up to 3, VStack gaps up to 5, safety 2 → 15+
        XCTAssertGreaterThanOrEqual(ChatHistoryView.footerBudget(columns: 120), 15)
    }

    func testFooterBudgetGrowsOnNarrowTerminals() {
        let wide = ChatHistoryView.footerBudget(columns: 120)
        let narrow = ChatHistoryView.footerBudget(columns: 50)
        let tiny = ChatHistoryView.footerBudget(columns: 30)
        XCTAssertGreaterThan(narrow, wide)
        XCTAssertGreaterThan(tiny, narrow)
    }
}