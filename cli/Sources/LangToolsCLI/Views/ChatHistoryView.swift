//
//  ChatHistoryView.swift
//  CLI
//
//  Tail-window chat history view (auto-scroll-to-bottom)
//

import SwiftTUI
import Foundation

/// Tail-window chat history view.
///
/// SwiftTUI's `ScrollView` lays out a layer as tall as its content, and the
/// renderer has **no clipping**: any layer that extends past the window makes
/// the root invalidation rect exceed the renderer cache (which is sized to the
/// window) and `Renderer.drawPixel` traps. There is also no programmatic
/// scroll position, and `ScrollView` pins the *top* of the content so the
/// newest messages are hidden below the fold.
///
/// Instead this view renders a **tail window**: only the most recent messages
/// that fit the available visible height above the fixed footer are placed in
/// the tree, and the block is bottom-anchored (`.frame(maxHeight: .infinity,
/// alignment: .bottomLeading)`) so the newest content is always visible
/// (effectively auto-scroll-to-bottom).
///
/// Two invariants keep the rendered layer inside the window at all times:
/// 1. The row budget counts **wrapped rows** (not logical lines) using the
///    same `MessageLineBuilder` helpers the message views draw with, at a
///    conservative width, so real wrapping never produces more rows.
/// 2. The newest message is *clipped* to the remaining budget when it alone
///    exceeds it — rendered as its newest wrapped rows — instead of being
///    included in full.
struct ChatHistoryView: View {
    let messages: [ChatMessage]
    let isStreaming: Bool

    var body: some View {
        VStack(alignment: .leading) {
            if window.messages.isEmpty && !isStreaming && availableHeight >= 2 {
                emptyStateView
            } else {
                ForEach(window.messages.indices, id: \.self) { index in
                    MessageView(message: window.messages[index])
                }
            }

            if isStreaming {
                streamingIndicator
            }
        }
        // Bottom-anchor so the newest content sits just above the fixed footer
        // and any leftover space appears at the top (not above the footer).
        .frame(maxHeight: .infinity, alignment: .bottomLeading)
    }

    private var window: ChatTailWindow.Selection {
        ChatTailWindow.tailWindow(
            messages: messages,
            isStreaming: isStreaming,
            availableHeight: availableHeight,
            availableWidth: availableWidth
        )
    }

    /// Rows reserved for the fixed footer (outer padding, VStack spacing gaps,
    /// separator, info line, input/approval rows, status line, and a safety
    /// margin). Over-reserved on purpose: under-reserving lets the tail window
    /// exceed the real frame and crash SwiftTUI's renderer.
    private var footerBudget: Int {
        Self.footerBudget(columns: TerminalSize.columns())
    }

    /// Rows reserved for the fixed footer at a given terminal width. Narrow
    /// terminals wrap footer lines (info/status text), so the reservation grows.
    static func footerBudget(columns: Int) -> Int {
        var rows = 4      // outer .padding(2): top + bottom
        rows += 1         // separator
        rows += 1         // info line
        rows += 2         // input row + autocomplete hint row
        rows += 1         // status line
        rows += 3         // approval prompt rows (worst case replaces input)
        rows += 5         // VStack spacing gaps (up to 6 children)
        rows += 2         // safety margin for footer text wrapping
        if columns < 60 { rows += 2 }
        if columns < 40 { rows += 4 }
        return rows
    }

    private var availableHeight: Int {
        max(1, TerminalSize.rows() - footerBudget)
    }

    /// Chat content width inside the outer `.padding(2)`, with a safety margin
    /// so wrap estimates never under-count.
    private var availableWidth: Int {
        ChatTailWindow.contentWidth(columns: TerminalSize.columns())
    }

    private var emptyStateView: some View {
        VStack(alignment: .leading) {
            Text("Welcome to LangTools CLI!")
                .foregroundColor(.cyan)
            Text("Type a message to start chatting, or /help for commands.")
                .foregroundColor(.white)
        }
    }

    private var streamingIndicator: some View {
        HStack {
            Text("⠋")
                .foregroundColor(.yellow)
            Text("Thinking...")
                .foregroundColor(.yellow)
                .italic()
        }
    }
}

/// Selects the most recent chat messages that fit an available row budget so
/// the newest content stays visible (tail window / auto-scroll-to-bottom).
///
/// The row-count computation wraps lines exactly the way the rendered views
/// wrap them (via the shared `MessageLineBuilder` helpers), so the selected
/// window matches the on-screen layout and can never exceed the window bounds.
enum ChatTailWindow {

    /// The selected tail window. `clipLastMessageToRows` is non-nil when the
    /// newest message alone exceeded the budget: the view then renders only
    /// its newest `clipLastMessageToRows` rows (via `clippedRows(for:)`).
    struct Selection: Equatable {
        let messages: [ChatMessage]
        let clipLastMessageToRows: Int?
    }

    /// Chat content width inside the outer `.padding(2)` (4 columns), with a
    /// safety margin so wrap estimates are conservative.
    static func contentWidth(columns: Int) -> Int {
        max(10, columns - 6)
    }

    /// Number of terminal rows a rendered message occupies, counting wrapped
    /// rows rather than logical lines.
    static func renderedRows(of message: ChatMessage, width: Int) -> Int {
        let width = max(1, width)
        switch message.role {
        case .user:
            // Single-row `HStack { "You:" + content }`; the prefix consumes
            // columns of the first wrapped row.
            return MessageLineBuilder.wrappedRowCount(
                of: message.content,
                width: width,
                firstLinePrefixColumns: 5
            )
        case .assistant:
            // Header row + wrapped dedented body lines.
            return 1 + MessageLineBuilder.wrappedRowCount(
                ofLines: MessageLineBuilder.assistantBodyLines(for: message.content),
                width: width
            )
        case .system:
            // No header; one wrapped row per line (always at least one).
            return max(1, MessageLineBuilder.wrappedRowCount(
                ofLines: MessageLineBuilder.systemLines(for: message.content),
                width: width
            ))
        case .toolCall, .toolResult:
            // Header row + bounded, wrapped preview lines (indented two columns).
            let isResult = message.role == .toolResult
            let preview = MessageLineBuilder.toolPreviewLines(content: message.content, isResult: isResult)
            return 1 + MessageLineBuilder.wrappedRowCount(ofLines: preview, width: max(1, width - 2))
        }
    }

    /// Total rendered height of a window of messages, including the streaming
    /// indicator row when streaming. Clipped newest messages contribute their
    /// clip budget (not their full height).
    static func renderedRows(of selection: Selection, isStreaming: Bool, width: Int) -> Int {
        var messages = selection.messages
        var total = 0
        if let clip = selection.clipLastMessageToRows, let _ = messages.popLast() {
            total += clip
        }
        total += messages.reduce(0) { $0 + renderedRows(of: $1, width: width) }
        return total + (isStreaming ? 1 : 0)
    }

    /// Select the most recent messages that fit within `availableHeight` rows.
    ///
    /// The newest message is always shown. When it alone exceeds the budget it
    /// is *clipped* to the remaining rows (newest content kept) so the rendered
    /// layer never exceeds the window. Older messages are added while they fit;
    /// once one does not fit, no older message is considered.
    static func tailWindow(
        messages: [ChatMessage],
        isStreaming: Bool,
        availableHeight: Int,
        availableWidth: Int
    ) -> Selection {
        guard !messages.isEmpty else {
            return Selection(messages: [], clipLastMessageToRows: nil)
        }

        let width = max(1, availableWidth)
        var remaining = availableHeight - (isStreaming ? 1 : 0)
        var selected: [ChatMessage] = []
        var clipRows: Int? = nil

        // Degenerate budget: not even one row left after the streaming
        // indicator — render nothing so the layer stays inside the window.
        guard remaining > 0 else {
            return Selection(messages: [], clipLastMessageToRows: nil)
        }

        for message in messages.reversed() {
            let rows = renderedRows(of: message, width: width)
            if rows > remaining {
                if selected.isEmpty {
                    // Newest message alone overflows: clip it to the budget.
                    selected.append(message)
                    clipRows = max(1, remaining)
                    remaining = 0
                }
                break
            }
            selected.append(message)
            remaining -= rows
            if remaining <= 0 {
                break
            }
        }
        return Selection(messages: selected.reversed(), clipLastMessageToRows: clipRows)
    }

    /// Exact rows to draw for a message clipped to `maxRows`, keeping the
    /// newest content. Headers are kept when the budget allows (assistant/tool
    /// messages), and body rows are the newest wrapped rows so the tail of the
    /// message stays visible. Output never exceeds `maxRows` rows.
    static func clippedRows(for message: ChatMessage, width: Int, maxRows: Int) -> [String] {
        let width = max(1, width)
        let maxRows = max(1, maxRows)

        func wrappedBodyRows(_ lines: [String], bodyWidth: Int) -> [String] {
            lines.flatMap { MessageLineBuilder.wrapSegments(of: $0, width: bodyWidth) }
        }

        switch message.role {
        case .user:
            let rows = wrappedBodyRows(message.content.components(separatedBy: .newlines), bodyWidth: width)
            return Array(rows.suffix(maxRows))
        case .system:
            let rows = wrappedBodyRows(MessageLineBuilder.systemLines(for: message.content), bodyWidth: width)
            return Array(rows.suffix(maxRows))
        case .assistant:
            let body = wrappedBodyRows(MessageLineBuilder.assistantBodyLines(for: message.content), bodyWidth: width)
            guard maxRows > 1 else { return Array(body.suffix(1)) }
            return ["Assistant:"] + Array(body.suffix(maxRows - 1))
        case .toolCall, .toolResult:
            let isResult = message.role == .toolResult
            let preview = MessageLineBuilder.toolPreviewLines(content: message.content, isResult: isResult)
            let header: String
            switch message.role {
            case .toolCall:
                header = "↳ Call \(message.toolName ?? "Tool")"
            case .toolResult:
                header = message.toolFailed
                    ? "  ✗ Result \(message.toolName ?? "Tool")"
                    : "  ✓ Result \(message.toolName ?? "Tool")"
            default:
                header = ""
            }
            let body = wrappedBodyRows(preview, bodyWidth: max(1, width - 2))
            guard maxRows > 1 else { return Array(body.suffix(1)) }
            return [header] + Array(body.suffix(maxRows - 1))
        }
    }
}

#if DEBUG
extension ChatHistoryView {
    static var preview: ChatHistoryView {
        ChatHistoryView(
            messages: [
                ChatMessage(role: .user, content: "Hello!"),
                ChatMessage(role: .assistant, content: "Hi there! How can I help?")
            ],
            isStreaming: false
        )
    }
}
#endif