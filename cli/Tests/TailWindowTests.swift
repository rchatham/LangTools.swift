import XCTest
@testable import CLI
@testable import SwiftTUI

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

    func testAssistantBodyLinesCollapsesBlankRuns() {
        let lines = MessageLineBuilder.assistantBodyLines(for: "a\n\n\n\n\nb")
        XCTAssertEqual(lines, ["a", "", "", "b"])
    }

    func testAssistantBodyLinesTrimsTrailingWhitespace() {
        let lines = MessageLineBuilder.assistantBodyLines(for: "a   \n\tb\t")
        XCTAssertEqual(lines, ["a", "\tb"])
    }

    func testAssistantBodyLinesWhitespaceOnlyRunCountsAsBlankRun() {
        // A degenerate reply of padded blank lines collapses to two blanks.
        let padded = Array(repeating: "          ", count: 20).joined(separator: "\n")
        let lines = MessageLineBuilder.assistantBodyLines(for: padded)
        XCTAssertEqual(lines.count, 2)
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

    func testWrapSegmentsNeverExceedWidth() {
        let line = String(repeating: "ab", count: 40) // 80 columns
        let segments = MessageLineBuilder.wrapSegments(of: line, width: 30)
        XCTAssertEqual(segments.reduce(0) { max($0, MessageLineBuilder.displayWidth(of: $1)) }, 30)
    }

    // MARK: - Scroll math (vendored ScrollControl)

    func testScrollOffsetClampsToZeroAndMax() {
        // Content shorter than the viewport: no scrolling at all.
        XCTAssertEqual(ScrollMath.clampOffset(5, contentHeight: 10, viewport: 20), 0)
        // Content taller than the viewport: clamped between 0 and the overflow.
        XCTAssertEqual(ScrollMath.clampOffset(-10, contentHeight: 60, viewport: 20), 0)
        XCTAssertEqual(ScrollMath.clampOffset(100, contentHeight: 60, viewport: 20), 40)
        XCTAssertEqual(ScrollMath.clampOffset(15, contentHeight: 60, viewport: 20), 15)
    }

    func testScrollMaxOffsetNeverNegative() {
        XCTAssertEqual(ScrollMath.maxOffset(contentHeight: 5, viewport: 20), 0)
        XCTAssertEqual(ScrollMath.maxOffset(contentHeight: 60, viewport: 20), 40)
    }

    // MARK: - Working-directory grounding

    func testContextSystemMessageIncludesWorkingDirectory() {
        let message = MessageService.contextSystemMessage(cwd: "/Users/me/Developer/langtools-cli")
        guard let text = message.text else {
            return XCTFail("context system message has no text")
        }
        XCTAssertTrue(text.contains("/Users/me/Developer/langtools-cli"))
        XCTAssertTrue(text.contains("current working directory"))
    }
}