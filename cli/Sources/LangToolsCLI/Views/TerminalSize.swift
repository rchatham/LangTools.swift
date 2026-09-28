//
//  TerminalSize.swift
//  CLI
//
//  Terminal viewport size detection (rows/columns) via TIOCGWINSZ, with a
//  bounded default fallback.
//

import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Reads the terminal viewport size. Used to size the tail window so the
/// rendered chat layer never exceeds the window bounds (which would crash
/// SwiftTUI's renderer, whose cache is sized to the window).
enum TerminalSize {

    /// Number of terminal rows, or a bounded default of `24` when the size
    /// cannot be determined (e.g. non-tty/piped output).
    static func rows() -> Int {
        var size = winsize()
        if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &size) == 0, size.ws_row > 0 {
            return Int(size.ws_row)
        }
        return defaultRows
    }

    /// Number of terminal columns, or a bounded default of `80`.
    static func columns() -> Int {
        var size = winsize()
        if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &size) == 0, size.ws_col > 0 {
            return Int(size.ws_col)
        }
        return defaultColumns
    }

    /// Reasonable bounded default rows, used when no terminal size is available.
    static let defaultRows = 24
    static let defaultColumns = 80
}