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
    ///
    /// Runs of blank lines are additionally collapsed and trailing whitespace
    /// trimmed: models occasionally emit whitespace-heavy degenerate replies
    /// (observed after failed tool calls), which would otherwise fill the
    /// entire tail window with blank rows and push all real content out of
    /// view. Trimming and collapsing happen here so the tail-window row
    /// estimator and the rendered view always agree.
    static func assistantBodyLines(for content: String) -> [String] {
        var lines = content.components(separatedBy: .newlines)
        if let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        return collapseBlankRuns(dedented(lines).map { String($0.reversed().drop(while: { $0 == " " || $0 == "\t" }).reversed()) })
    }

    /// Replace runs of more than `maxConsecutive` blank lines with exactly
    /// `maxConsecutive` blank lines, preserving paragraph spacing while keeping
    /// degenerate whitespace-heavy content compact.
    static func collapseBlankRuns(_ lines: [String], maxConsecutive: Int = 2) -> [String] {
        let limit = max(0, maxConsecutive)
        var result: [String] = []
        var blankRun = 0
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                blankRun += 1
                if blankRun <= limit {
                    result.append(line)
                }
            } else {
                blankRun = 0
                result.append(line)
            }
        }
        return result
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

    // MARK: - Wrapping
    //
    // SwiftTUI's renderer has no clipping: any layer taller than the window
    // traps in `Renderer.drawPixel`. The tail-window budget must therefore
    // count *wrapped rows*, not logical lines. These helpers wrap lines at a
    // conservative width (the real terminal offers at least as many columns,
    // so real wrapping never produces more rows than estimated).

    /// Approximate display width of a line in terminal columns. Wide CJK/emoji
    /// glyphs count as 2 columns; tabs conservatively count as 8.
    static func displayWidth(of line: String) -> Int {
        var width = 0
        for character in line {
            width += characterColumns(character)
        }
        return width
    }

    /// Terminal columns a character occupies.
    static func characterColumns(_ character: Character) -> Int {
        if character == "\t" { return 8 }
        return isWide(character) ? 2 : 1
    }

    /// Whether a character renders double-width (East Asian Wide/Fullwidth or
    /// emoji presentation).
    static func isWide(_ character: Character) -> Bool {
        for scalar in character.unicodeScalars {
            if scalar.properties.isEmojiPresentation { return true }
            switch scalar.value {
            case 0x1100...0x115F,       // Hangul Jamo
                 0x2E80...0x303E,       // CJK Radicals .. CJK Symbols
                 0x3041...0x33FF,       // Hiragana .. CJK Compatibility
                 0x4E00...0x9FFF,       // CJK Unified Ideographs
                 0xA000...0xA4CF,       // Yi
                 0xAC00...0xD7A3,       // Hangul Syllables
                 0xF900...0xFAFF,       // CJK Compatibility Ideographs
                 0xFE30...0xFE4F,       // CJK Compatibility Forms
                 0xFF00...0xFF60,       // Fullwidth Forms
                 0xFFE0...0xFFE6,       // Fullwidth Signs
                 0x1F300...0x1F64F,     // Emoji (misc + emoticons)
                 0x1F680...0x1F6FF,     // Emoji transport
                 0x1F900...0x1F9FF,     // Supplemental Symbols
                 0x20000...0x3FFFD:     // CJK Extensions
                return true
            default:
                continue
            }
        }
        return false
    }

    /// Wrap a line into segments of at most `width` display columns. The first
    /// segment is shortened by `firstLinePrefixColumns` (inline prefixes such
    // as "You: "). An empty line produces a single empty segment.
    static func wrapSegments(of line: String, width: Int, firstLinePrefixColumns: Int = 0) -> [String] {
        let width = max(1, width)
        var segments: [String] = []
        var current = ""
        var currentWidth = firstLinePrefixColumns
        for character in line {
            let columns = characterColumns(character)
            if currentWidth + columns > width, !current.isEmpty {
                segments.append(current)
                current = ""
                currentWidth = 0
            }
            current.append(character)
            currentWidth += columns
        }
        segments.append(current)
        return segments
    }

    /// Number of wrapped rows a single logical line occupies.
    static func wrappedRowCount(of line: String, width: Int, firstLinePrefixColumns: Int = 0) -> Int {
        wrapSegments(of: line, width: width, firstLinePrefixColumns: firstLinePrefixColumns).count
    }

    /// Total wrapped rows for a sequence of logical lines.
    static func wrappedRowCount<S: Sequence>(ofLines lines: S, width: Int) -> Int where S.Element == String {
        lines.reduce(0) { $0 + wrappedRowCount(of: $1, width: width) }
    }

    /// The last `maxRows` wrapped rows of a single logical line, so the newest
    /// content stays visible when a message alone exceeds the tail budget.
    static func tailWrappedRows(of line: String, width: Int, firstLinePrefixColumns: Int = 0, maxRows: Int) -> [String] {
        Array(wrapSegments(of: line, width: width, firstLinePrefixColumns: firstLinePrefixColumns).suffix(max(1, maxRows)))
    }

    /// The last `maxRows` wrapped rows across a sequence of logical lines.
    static func tailWrappedRows<S: Sequence>(ofLines lines: S, width: Int, maxRows: Int) -> [String] where S.Element == String {
        let segments = lines.flatMap { wrapSegments(of: $0, width: width) }
        return Array(segments.suffix(max(1, maxRows)))
    }
}