//
//  ProgressIndicator.swift
//  ChatCLI
//
//  Progress indicators for long-running operations
//

import Foundation

/// Progress indicator types
enum ProgressIndicatorStyle {
    case spinner
    case dots
    case bar
    case pulse
}

/// A simple text-based progress indicator
struct ProgressIndicator {
    let style: ProgressIndicatorStyle
    private var frame: Int = 0

    static let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    static let dotsFrames = [".", "..", "...", "....", "...."]
    static let pulseFrames = ["○", "◔", "◑", "◕", "●", "◕", "◑", "◔"]
    static let barFrames = ["▱▱▱▱▱", "▰▱▱▱▱", "▰▰▱▱▱", "▰▰▰▱▱", "▰▰▰▰▱", "▰▰▰▰▰"]

    init(style: ProgressIndicatorStyle = .spinner) {
        self.style = style
    }

    /// Get the current frame
    mutating func advance() -> String {
        let frames: [String]
        switch style {
        case .spinner:
            frames = Self.spinnerFrames
        case .dots:
            frames = Self.dotsFrames
        case .bar:
            frames = Self.barFrames
        case .pulse:
            frames = Self.pulseFrames
        }

        let result = frames[frame % frames.count]
        frame += 1
        return result
    }

    /// Reset to first frame
    mutating func reset() {
        frame = 0
    }
}

/// Progress bar with percentage
struct ProgressBar {
    let width: Int
    let filledChar: Character
    let emptyChar: Character

    init(width: Int = 20, filledChar: Character = "█", emptyChar: Character = "░") {
        self.width = width
        self.filledChar = filledChar
        self.emptyChar = emptyChar
    }

    /// Render progress bar for given percentage (0-100)
    func render(percentage: Double) -> String {
        let clamped = max(0, min(100, percentage))
        let filledCount = Int((clamped / 100.0) * Double(width))
        let emptyCount = width - filledCount

        let filled = String(repeating: filledChar, count: filledCount)
        let empty = String(repeating: emptyChar, count: emptyCount)

        return "[\(filled)\(empty)] \(String(format: "%.1f", clamped))%"
    }

    /// Render progress bar for fraction (e.g., 5/10)
    func render(current: Int, total: Int) -> String {
        guard total > 0 else { return render(percentage: 0) }
        let percentage = (Double(current) / Double(total)) * 100
        return "\(render(percentage: percentage)) (\(current)/\(total))"
    }
}

/// Status message with timestamp
struct StatusMessage {
    let message: String
    let timestamp: Date
    let level: StatusLevel

    enum StatusLevel {
        case info
        case success
        case warning
        case error

        var prefix: String {
            switch self {
            case .info: return "ℹ️"
            case .success: return "✓"
            case .warning: return "⚠️"
            case .error: return "✗"
            }
        }
    }

    init(_ message: String, level: StatusLevel = .info) {
        self.message = message
        self.timestamp = Date()
        self.level = level
    }

    var formatted: String {
        "\(level.prefix) \(message)"
    }

    var formattedWithTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return "[\(formatter.string(from: timestamp))] \(level.prefix) \(message)"
    }
}

/// Elapsed time display
struct ElapsedTimeFormatter {
    static func format(_ interval: TimeInterval) -> String {
        if interval < 1 {
            return String(format: "%.0fms", interval * 1000)
        } else if interval < 60 {
            return String(format: "%.1fs", interval)
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            let seconds = Int(interval.truncatingRemainder(dividingBy: 60))
            return "\(minutes)m \(seconds)s"
        } else {
            let hours = Int(interval / 3600)
            let minutes = Int((interval.truncatingRemainder(dividingBy: 3600)) / 60)
            return "\(hours)h \(minutes)m"
        }
    }
}
