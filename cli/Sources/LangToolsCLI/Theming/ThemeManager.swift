//
//  ThemeManager.swift
//  CLI
//
//  Manages color themes for the CLI interface
//

import SwiftTUI
import Foundation

/// Available color themes (named ChatTheme to avoid conflict with Configuration.Theme)
enum ChatTheme: String, CaseIterable, Codable {
    case `default` = "default"
    case dark = "dark"
    case light = "light"
    case monokai = "monokai"
    case solarized = "solarized"

    var displayName: String {
        rawValue.capitalized
    }
}

/// Color scheme definition
struct ChatColorScheme {
    // Primary colors
    let primary: Color
    let secondary: Color
    let accent: Color

    // Text colors
    let textPrimary: Color
    let textSecondary: Color
    let textMuted: Color

    // Role colors
    let userMessage: Color
    let assistantMessage: Color
    let systemMessage: Color
    let toolResult: Color

    // Status colors
    let success: Color
    let warning: Color
    let error: Color
    let info: Color

    // UI element colors
    let border: Color
    let highlight: Color
    let selection: Color
}

/// Manages theme state and provides colors
@MainActor
final class ThemeManager: ObservableObject {
    /// Shared singleton instance
    static let shared = ThemeManager()

    /// Current theme
    @Published var currentTheme: ChatTheme = .default {
        didSet {
            updateColorScheme()
        }
    }

    /// Current color scheme
    @Published private(set) var colors: ChatColorScheme

    private init() {
        self.colors = ThemeManager.colorScheme(for: .default)
    }

    private func updateColorScheme() {
        colors = ThemeManager.colorScheme(for: currentTheme)
    }

    // MARK: - Theme Definitions

    static func colorScheme(for theme: ChatTheme) -> ChatColorScheme {
        switch theme {
        case .default:
            return defaultTheme
        case .dark:
            return darkTheme
        case .light:
            return lightTheme
        case .monokai:
            return monokaiTheme
        case .solarized:
            return solarizedTheme
        }
    }

    private static let defaultTheme = ChatColorScheme(
        primary: .cyan,
        secondary: .blue,
        accent: .magenta,
        textPrimary: .white,
        textSecondary: .white,
        textMuted: .white,
        userMessage: .green,
        assistantMessage: .cyan,
        systemMessage: .yellow,
        toolResult: .white,
        success: .green,
        warning: .yellow,
        error: .red,
        info: .cyan,
        border: .white,
        highlight: .yellow,
        selection: .blue
    )

    private static let darkTheme = ChatColorScheme(
        primary: .cyan,
        secondary: .blue,
        accent: .magenta,
        textPrimary: .white,
        textSecondary: .white,
        textMuted: .white,
        userMessage: .green,
        assistantMessage: .cyan,
        systemMessage: .yellow,
        toolResult: .white,
        success: .green,
        warning: .yellow,
        error: .red,
        info: .cyan,
        border: .white,
        highlight: .yellow,
        selection: .blue
    )

    private static let lightTheme = ChatColorScheme(
        primary: .blue,
        secondary: .cyan,
        accent: .magenta,
        textPrimary: .black,
        textSecondary: .black,
        textMuted: .white,
        userMessage: .blue,
        assistantMessage: .black,
        systemMessage: .yellow,
        toolResult: .black,
        success: .green,
        warning: .yellow,
        error: .red,
        info: .blue,
        border: .black,
        highlight: .yellow,
        selection: .cyan
    )

    private static let monokaiTheme = ChatColorScheme(
        primary: .magenta,
        secondary: .cyan,
        accent: .yellow,
        textPrimary: .white,
        textSecondary: .white,
        textMuted: .white,
        userMessage: .green,
        assistantMessage: .magenta,
        systemMessage: .yellow,
        toolResult: .cyan,
        success: .green,
        warning: .yellow,
        error: .red,
        info: .cyan,
        border: .white,
        highlight: .yellow,
        selection: .magenta
    )

    private static let solarizedTheme = ChatColorScheme(
        primary: .cyan,
        secondary: .blue,
        accent: .yellow,
        textPrimary: .white,
        textSecondary: .white,
        textMuted: .white,
        userMessage: .green,
        assistantMessage: .cyan,
        systemMessage: .yellow,
        toolResult: .white,
        success: .green,
        warning: .yellow,
        error: .red,
        info: .cyan,
        border: .cyan,
        highlight: .yellow,
        selection: .blue
    )

    // MARK: - Theme Selection

    /// Set theme by name
    func setTheme(_ themeName: String) -> Bool {
        guard let theme = ChatTheme(rawValue: themeName.lowercased()) else {
            return false
        }
        currentTheme = theme
        return true
    }

    /// Get list of available themes
    var availableThemes: [ChatTheme] {
        ChatTheme.allCases
    }
}

// MARK: - Theme Helpers

extension ThemeManager {
    /// Get color for a message role
    func colorForRole(_ role: ChatMessage.Role) -> Color {
        switch role {
        case .user: return colors.userMessage
        case .assistant: return colors.assistantMessage
        case .system: return colors.systemMessage
        case .tool: return colors.toolResult
        }
    }

    /// Get color for a status
    func colorForStatus(_ success: Bool) -> Color {
        success ? colors.success : colors.error
    }
}
