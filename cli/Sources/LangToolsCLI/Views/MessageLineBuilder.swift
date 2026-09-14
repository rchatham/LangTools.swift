//
//  MessageLineBuilder.swift
//  CLI
//
//  Pure, testable helpers for chat message line layout and alignment.
//

import Foundation

/// Pure helpers that turn a `ChatMessage`'s raw content into the lines that the
/// TUI actually renders, with consistent alignment and no stray leading
/// indentation on continuation/wrapped lines.
///
/// These helpers are intentionally free of SwiftTUI dependencies so they can be
/// unit-tested directly. The rendered views (`MessageView` and friends) and the
/// tail-window selector (`ChatTailWindow`) both consume these helpers so that
/// computed row counts match what is drawn on screen.
enum MessageLineBuilder {

    // MARK: - Assistant

    /// Body lines for an assistant message.
    ///
    /// Continuation lines frequently arrive with a common leading indent (for
    /// example when a streamed block is uniformly indented). That common indent
    /// is a *stray* leading indentation relative to the "Assistant:" header, so
    /// it is stripped here (`dedented(_:)`). A single trailing empty line — a
    /// common artifact of streamed content — is dropped so it does not consume a
    /// visible row.
    static func assistantBodyLines(for content: String) -> [String] {
        var lines = content.components(separatedBy: .newlines)
        if let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        return dedented(lines)
    }

    // MARK: - System

    /// Body lines for a system message. System content is app-authored
    /// (help text, status blocks) and relies on intentional formatting, so it
    /// is split only — never dedented.
    static func systemLines(for content: String) -> [String] {
        return content.components(separatedBy: .newlines)
    }

    // MARK: - Tool

    /// Bounded preview lines for a tool call/result body, using the same limits
    /// as the on-screen rendering.
    static func toolPreviewLines(content: String, isResult: Bool) -> [String] {
        let lineLimit = isResult ? 3 : 2
        let characterLimit = isResult ? 500 : 240
        return ToolMessagePreview.lines(for: content, limit: lineLimit, characterLimit: characterLimit)
    }

    // MARK: - Dedent

    /// Remove the longest common leading whitespace run shared by all non-empty
    /// lines, preserving any *relative* indentation between lines.
    static func dedented(_ lines: [String]) -> [String] {
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let common = nonEmpty.map(leadingWhitespaceCount).min(), common > 0 else {
            return lines
        }
        return lines.map { line in
            String(line.dropFirst(min(common, line.count)))
        }
    }

    /// Number of leading whitespace characters on a line.
    static func leadingWhitespaceCount(_ line: String) -> Int {
        return line.prefix(while: { $0.isWhitespace }).count
    }
}