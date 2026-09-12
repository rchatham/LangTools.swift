//
//  DiffView.swift
//  CLI
//
//  Simple diff display for showing text changes
//

import SwiftTUI
import Foundation

/// Represents a line in a diff
struct DiffLine {
    enum LineType {
        case unchanged
        case added
        case removed
        case context
    }

    let type: LineType
    let content: String
    let lineNumber: Int?
}

/// Simple diff generator
struct DiffGenerator {
    /// Generate a simple diff between old and new content
    static func diff(old: String, new: String, contextLines: Int = 3) -> [DiffLine] {
        let oldLines = old.components(separatedBy: .newlines)
        let newLines = new.components(separatedBy: .newlines)

        var result: [DiffLine] = []

        // Simple line-by-line comparison
        let maxLines = max(oldLines.count, newLines.count)

        for i in 0..<maxLines {
            let oldLine = i < oldLines.count ? oldLines[i] : nil
            let newLine = i < newLines.count ? newLines[i] : nil

            if oldLine == newLine {
                if let line = oldLine {
                    result.append(DiffLine(type: .unchanged, content: line, lineNumber: i + 1))
                }
            } else {
                if let old = oldLine {
                    result.append(DiffLine(type: .removed, content: old, lineNumber: i + 1))
                }
                if let new = newLine {
                    result.append(DiffLine(type: .added, content: new, lineNumber: i + 1))
                }
            }
        }

        return result
    }

    /// Generate a unified diff string
    static func unifiedDiff(old: String, new: String, oldName: String = "a", newName: String = "b") -> String {
        let lines = diff(old: old, new: new)

        var result = "--- \(oldName)\n+++ \(newName)\n"

        for line in lines {
            switch line.type {
            case .unchanged:
                result += " \(line.content)\n"
            case .added:
                result += "+\(line.content)\n"
            case .removed:
                result += "-\(line.content)\n"
            case .context:
                result += " \(line.content)\n"
            }
        }

        return result
    }

    /// Generate a side-by-side comparison
    static func sideBySide(old: String, new: String, width: Int = 40) -> String {
        let oldLines = old.components(separatedBy: .newlines)
        let newLines = new.components(separatedBy: .newlines)

        var result = ""
        let separator = " | "
        let maxLines = max(oldLines.count, newLines.count)

        // Header
        let oldHeader = "Old".padding(toLength: width, withPad: " ", startingAt: 0)
        let newHeader = "New".padding(toLength: width, withPad: " ", startingAt: 0)
        result += "\(oldHeader)\(separator)\(newHeader)\n"
        result += String(repeating: "-", count: width) + separator + String(repeating: "-", count: width) + "\n"

        for i in 0..<maxLines {
            let oldLine = i < oldLines.count ? oldLines[i] : ""
            let newLine = i < newLines.count ? newLines[i] : ""

            let oldPadded = truncateOrPad(oldLine, to: width)
            let newPadded = truncateOrPad(newLine, to: width)

            result += "\(oldPadded)\(separator)\(newPadded)\n"
        }

        return result
    }

    private static func truncateOrPad(_ string: String, to width: Int) -> String {
        if string.count > width {
            return String(string.prefix(width - 3)) + "..."
        } else {
            return string.padding(toLength: width, withPad: " ", startingAt: 0)
        }
    }
}

/// SwiftTUI view for displaying a diff
struct DiffDisplayView: View {
    let diff: [DiffLine]
    let maxLines: Int

    init(diff: [DiffLine], maxLines: Int = 20) {
        self.diff = diff
        self.maxLines = maxLines
    }

    var body: some View {
        VStack(alignment: .leading) {
            ForEach(diff.prefix(maxLines).indices, id: \.self) { index in
                diffLineView(diff[index])
            }

            if diff.count > maxLines {
                Text("  ... (\(diff.count - maxLines) more lines)")
                    .foregroundColor(.white)
            }
        }
    }

    private func diffLineView(_ line: DiffLine) -> some View {
        HStack {
            Text(linePrefix(line.type))
                .foregroundColor(lineColor(line.type))
            Text(line.content)
                .foregroundColor(lineColor(line.type))
        }
    }

    private func linePrefix(_ type: DiffLine.LineType) -> String {
        switch type {
        case .unchanged: return " "
        case .added: return "+"
        case .removed: return "-"
        case .context: return " "
        }
    }

    private func lineColor(_ type: DiffLine.LineType) -> Color {
        switch type {
        case .unchanged: return .white
        case .added: return .green
        case .removed: return .red
        case .context: return .white
        }
    }
}

/// Compact diff summary view
struct DiffSummaryView: View {
    let addedCount: Int
    let removedCount: Int
    let unchangedCount: Int

    init(diff: [DiffLine]) {
        self.addedCount = diff.filter { $0.type == .added }.count
        self.removedCount = diff.filter { $0.type == .removed }.count
        self.unchangedCount = diff.filter { $0.type == .unchanged }.count
    }

    var body: some View {
        HStack {
            Text("+\(addedCount)")
                .foregroundColor(.green)
            Text("-\(removedCount)")
                .foregroundColor(.red)
            Text("~\(unchangedCount)")
                .foregroundColor(.white)
        }
    }
}
