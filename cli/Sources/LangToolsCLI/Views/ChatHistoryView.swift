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
/// SwiftTUI's `ScrollView` only follows focused controls and exposes no
/// programmatic scroll position. Chat messages are intentionally non-selectable
/// so keyboard focus stays in the message/approval field, so `ScrollView` would
/// pin the *top* of the content and hide the newest messages below the fold.
///
/// Instead this view renders a **tail window**: only the most recent messages
/// that fit the available visible height above the fixed footer are placed in
/// the tree, and the block is bottom-anchored so the newest content is always
/// visible (effectively auto-scroll-to-bottom). The available height is taken
/// from the SwiftTUI layout size (derived from the window/terminal size); when
/// that is not yet available it falls back to `TIOCGWINSZ` and a bounded
/// default.
struct ChatHistoryView: View {
    let messages: [ChatMessage]
    let isStreaming: Bool

    var body: some View {
        GeometryReader { size in
            let available = ChatTailWindow.availableHeight(
                layoutHeight: size.height.intValue,
                fallback: TerminalSize.rows()
            )
            let window = ChatTailWindow.tailWindow(
                messages: messages,
                isStreaming: isStreaming,
                availableHeight: available
            )
            VStack(alignment: .leading) {
                if window.isEmpty && !isStreaming {
                    emptyStateView
                } else {
                    ForEach(window.indices, id: \.self) { index in
                        MessageView(message: window[index])
                    }
                }

                if isStreaming {
                    streamingIndicator
                }
            }
            // Bottom-anchor so the newest content sits just above the fixed
            // footer and any leftover space appears at the top (not above the
            // footer). When a single message overflows the window, the bottom is
            // kept visible and the top is clipped.
            .frame(maxHeight: .infinity, alignment: .bottomLeading)
        }
        .frame(maxHeight: .infinity)
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
/// The row-count computation mirrors exactly what `MessageView` draws, via the
/// shared `MessageLineBuilder` helpers, so the selected window matches the
/// on-screen layout.
enum ChatTailWindow {

    /// Number of terminal rows a rendered message occupies.
    static func renderedHeight(of message: ChatMessage) -> Int {
        switch message.role {
        case .user:
            // Single-line `HStack { "You:" + content }`.
            return 1
        case .assistant:
            // Header row + dedented body lines.
            return 1 + MessageLineBuilder.assistantBodyLines(for: message.content).count
        case .system:
            // No header; one row per line (always at least one).
            return max(1, MessageLineBuilder.systemLines(for: message.content).count)
        case .toolCall, .toolResult:
            // Header row + bounded preview lines.
            let isResult = message.role == .toolResult
            return 1 + MessageLineBuilder.toolPreviewLines(content: message.content, isResult: isResult).count
        }
    }

    /// Resolve the available visible height (rows) from a SwiftTUI layout
    /// height, falling back to a terminal-derived or bounded default before the
    /// layout has reported a usable size.
    static func availableHeight(layoutHeight: Int, fallback rows: Int) -> Int {
        if layoutHeight >= 2 { return layoutHeight }
        return max(2, rows)
    }

    /// Select the most recent messages that fit within `availableHeight` rows.
    ///
    /// The newest message is always included even if it alone overflows the
    /// budget (it is bottom-anchored on screen so its newest lines stay
    /// visible). Older messages are added while they fit; once one does not fit
    /// no older message is considered.
    static func tailWindow(
        messages: [ChatMessage],
        isStreaming: Bool,
        availableHeight: Int
    ) -> [ChatMessage] {
        guard !messages.isEmpty else { return [] }

        var remaining = max(1, availableHeight) - (isStreaming ? 1 : 0)
        var selected: [ChatMessage] = []
        for message in messages.reversed() {
            let height = renderedHeight(of: message)
            if height > remaining, !selected.isEmpty {
                break
            }
            selected.append(message)
            remaining -= height
            if remaining <= 0 {
                break
            }
        }
        return selected.reversed()
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
