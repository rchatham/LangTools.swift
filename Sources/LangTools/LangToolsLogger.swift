//
//  LangToolsLogger.swift
//  LangTools
//
//  Created by Reid Chatham on 2/9/26.
//

import Foundation

/// Protocol for optional logging in LangTools.
/// When no logger is provided (the default), no debug output is produced.
/// Pass a `PrintLogger` instance to enable debug output.
public protocol LangToolsLogger {
    func debug(_ message: String)
    func info(_ message: String)
    func warning(_ message: String)
    func error(_ message: String)
}

/// Default logger implementation that prints to console with emoji prefixes.
/// Use this for opt-in debugging:
/// ```swift
/// let anthropic = Anthropic(
///     configuration: .init(apiKey: "...", logger: PrintLogger())
/// )
/// ```
public struct PrintLogger: LangToolsLogger {
    public init() {}

    public func debug(_ message: String) {
        print("🔍 \(message)")
    }

    public func info(_ message: String) {
        print("ℹ️ \(message)")
    }

    public func warning(_ message: String) {
        print("⚠️ \(message)")
    }

    public func error(_ message: String) {
        print("❌ \(message)")
    }
}
