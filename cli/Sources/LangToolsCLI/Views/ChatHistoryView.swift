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
/// SwiftTUI's `ScrollView` lays out a layer as tall as its content. When chat
/// content exceeds the terminal viewport, that layer becomes taller than the
/// renderer's cache (which is sized to the window), and `Renderer.drawPixel`
/// indexes out of bounds and traps. There is also no programmatic scroll
/// position, and `ScrollView` pins the *top* of the content so the newest
/// messages are hidden below the fold.
///
/// Instead this view renders a **tail window**: only the most recent messages
/// that fit the available visible height above the fixed footer are placed in
/// the tree, and the block is bottom-anchored (`.frame(maxHeight: .infinity,
/// alignment: .bottomLeading)`) so the newest content is always visible
/// (effectively auto-scroll-to-bottom). The available height is taken from the
/// terminal size (`TIOCGWINSZ`) minus a generously reserved footer budget so the
/// rendered layer never exceeds the window bounds (which would crash the
/// renderer).
struct ChatHistoryView: View {
    let messages: [ChatMessage]
    let isStreaming: Bool

    /// Rows reserved for the fixed footer (separator, info line, input/approval,
    /// status line, VStack spacing, and outer padding). Over-reserved on
    /// purpose: under-reserving would let the tail window exceed the real
    /// frame and crash SwiftTUI's renderer.
    static let footerRows = 10

    var body: some View {
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
        // Bottom-anchor so the newest content sits just above the fixed footer
        // and any leftover space appears at the top (not above the footer).
        .frame(maxHeight: .infinity, alignment: .bottomLeading)
    }

    private var window: [ChatMessage] {
        ChatTailWindow.tailWindow(
            messages: messages,
            isStreaming: isStreaming,
            availableHeight: availableHeight
        )
    }

    private var availableHeight: Int {
        max(1, TerminalSize.rows() - Self.footerRows)
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

    /// Total rendered height of a window of messages, including the streaming
    /// indicator row when streaming.
    static func renderedHeight(of window: [ChatMessage], isStreaming: Bool) -> Int {
        let messagesHeight = window.reduce(0) { $0 + renderedHeight(of: $1) }
        return messagesHeight + (isStreaming ? 1 : 0)
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