import Foundation
import XCTest
import Ollama
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

    /// Follow requests queued while already pinned (every input submission
    /// queues one) must be drained on that layout pass — otherwise they linger
    /// and snap the user back to the bottom after an explicit Home/PageUp.
    func testStaleFollowRequestDoesNotHijackExplicitScroll() {
        let scroll = ScrollControl()
        let content = FixedHeightControl(height: 60)
        scroll.contentControl = content

        ScrollView<EmptyView>.requestFollowBottom()
        scroll.layout(size: Size(width: 80, height: 20))
        XCTAssertEqual(content.layer.frame.position.line, -40)

        scroll.scrollToTop()
        scroll.layout(size: Size(width: 80, height: 20))
        XCTAssertEqual(scroll.contentOffset, 0, "stale follow request must not re-pin")
        XCTAssertEqual(content.layer.frame.position.line, 0)
        XCTAssertFalse(scroll.pinnedToBottom)

        // A follow request queued while scrolled up (new message submit) still
        // re-pins to the response.
        ScrollView<EmptyView>.requestFollowBottom()
        scroll.layout(size: Size(width: 80, height: 20))
        XCTAssertTrue(scroll.pinnedToBottom)
        XCTAssertEqual(content.layer.frame.position.line, -40)
    }

    func testHomeAndEndUseAbsoluteOffsetsAndPinState() {
        let scroll = ScrollControl()
        let content = FixedHeightControl(height: 60)
        scroll.contentControl = content
        scroll.layout(size: Size(width: 80, height: 20))

        scroll.scrollToTop()
        XCTAssertEqual(scroll.contentOffset, 0)
        XCTAssertFalse(scroll.pinnedToBottom)

        scroll.scrollToBottom()
        XCTAssertEqual(scroll.contentOffset, 40)
        XCTAssertTrue(scroll.pinnedToBottom)
    }

    /// Scroll keys run outside `layout(size:)`, so they must re-apply the
    /// offset to the child layer frame — otherwise the offset changes but
    /// the visible rows never move.
    func testScrollKeysMoveChildLayerFrame() {
        let scroll = ScrollControl()
        let content = FixedHeightControl(height: 60)
        scroll.contentControl = content
        scroll.layout(size: Size(width: 80, height: 20))
        XCTAssertEqual(content.layer.frame.position.line, -40, "initial layout pins to the bottom")

        scroll.scrollToTop()
        XCTAssertEqual(content.layer.frame.position.line, 0)

        scroll.scrollToBottom()
        XCTAssertEqual(content.layer.frame.position.line, -40)

        // Positive lines scroll towards older content (offset shrinks).
        scroll.scrollBy(lines: 15)
        XCTAssertEqual(content.layer.frame.position.line, -25)
        XCTAssertFalse(scroll.pinnedToBottom)

        // Above the top, the offset clamps to 0.
        scroll.scrollToTop()
        scroll.scrollBy(lines: 5)
        XCTAssertEqual(content.layer.frame.position.line, 0, "cannot scroll above the top")
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

    func testExistingSystemMessageDoesNotSuppressWorkingDirectoryContext() {
        let warning = Message(text: "Tool warning", role: .system)
        let outgoing = MessageService.messagesWithContext(
            [warning, Message(text: "Hello", role: .user)],
            cwd: "/tmp/example-repo"
        )

        XCTAssertEqual(outgoing.first?.role, .system)
        XCTAssertTrue(outgoing.first?.text?.contains("/tmp/example-repo") == true)
        XCTAssertEqual(outgoing.dropFirst().first?.text, "Tool warning")
    }

    func testAnthropicRequestSeparatesSystemMessagesWithoutFatalRoleConversion() throws {
        let messages = [
            Message(text: "cwd context", role: .system),
            Message(text: "developer instruction", role: .developer),
            Message(text: "Hello", role: .user),
            Message(text: "Hi", role: .assistant),
        ]

        XCTAssertNil(Role.system.toAnthropicRole())
        XCTAssertNil(Role.developer.toAnthropicRole())
        XCTAssertEqual(messages.toAnthropicMessages().map(\.role.rawValue), ["user", "assistant"])
        XCTAssertEqual(
            messages.toAnthropicSystemMessage(),
            "cwd context\n---\ndeveloper instruction"
        )

        let request = NetworkClient().request(
            messages: messages,
            model: .anthropic(.claude46Sonnet),
            stream: false,
            tools: nil,
            toolChoice: nil
        )
        let encoded = try JSONEncoder().encode(request)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(
            payload["system"] as? String,
            "cwd context\n---\ndeveloper instruction"
        )
        let payloadMessages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
        XCTAssertEqual(payloadMessages.compactMap { $0["role"] as? String }, ["user", "assistant"])
    }

    // MARK: - --model argument parsing

    func testModelFromArgumentAcceptsBareIDs() {
        XCTAssertEqual(CLI.model(fromArgument: "llama3.2:latest"), .ollama(Ollama.Model(rawValue: "llama3.2:latest")!))
    }

    func testModelFromArgumentAcceptsProviderPrefixes() {
        XCTAssertEqual(
            CLI.model(fromArgument: "ollama-cloud/glm-5.2:cloud"),
            .ollama(Ollama.Model(rawValue: "glm-5.2:cloud")!)
        )
        XCTAssertEqual(
            CLI.model(fromArgument: "ollama/llama3.2:latest"),
            .ollama(Ollama.Model(rawValue: "llama3.2:latest")!)
        )
    }

    func testModelFromArgumentRejectsUnknownProviderPrefixes() {
        // Ollama model names are user-defined, so bare identifiers are always
        // valid Ollama candidates; but an explicit unknown provider prefix is
        // rejected rather than silently treated as a model name.
        XCTAssertNil(CLI.model(fromArgument: "unknown-provider/some-model"))
        XCTAssertEqual(
            CLI.model(fromArgument: "not-a-real-model"),
            .ollama(Ollama.Model(rawValue: "not-a-real-model")!)
        )
    }

    func testRequestedModelArgumentParsesFlagForms() {
        XCTAssertEqual(CLI.requestedModelArgument(["langtools", "--model", "llama3.2:latest"]), "llama3.2:latest")
        XCTAssertEqual(CLI.model(fromArgument: CLI.requestedModelArgument(["langtools", "--model=glm-5.2:cloud"]) ?? ""), .ollama(Ollama.Model(rawValue: "glm-5.2:cloud")!))
        XCTAssertNil(CLI.requestedModelArgument(["langtools", "--tui"]))
    }

    func testEnvironmentAPIKeysAreAvailableToPreModeConfiguration() {
        let keys = CLI.apiKeysFromEnvironment([
            "ANTHROPIC_API_KEY": " anthropic-key ",
            "OPENAI_API_KEY": "openai-key",
            "XAI_API_KEY": "   ",
            "GEMINI_API_KEY": "gemini-key",
        ])

        XCTAssertEqual(keys[.anthropic], "anthropic-key")
        XCTAssertEqual(keys[.openAI], "openai-key")
        XCTAssertNil(keys[.xAI])
        XCTAssertEqual(keys[.gemini], "gemini-key")
    }

    func testEnvironmentLoaderRegistersEnvOnlyKey() {
        let previous = UserDefaults.getApiKey(for: .xAI)
        UserDefaults.removeApiKey(for: .xAI)
        defer {
            if let previous {
                UserDefaults.setApiKey(previous, for: .xAI)
            } else {
                UserDefaults.removeApiKey(for: .xAI)
            }
        }

        CLI.loadAPIKeysFromEnvironment(["XAI_API_KEY": "env-only-key"])

        XCTAssertEqual(UserDefaults.getApiKey(for: .xAI), "env-only-key")
    }
}

private final class FixedHeightControl: Control {
    private let height: Extended

    init(height: Extended) {
        self.height = height
    }

    override func size(proposedSize: Size) -> Size {
        Size(width: proposedSize.width, height: height)
    }
}