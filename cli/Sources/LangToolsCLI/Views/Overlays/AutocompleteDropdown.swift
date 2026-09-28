//
//  AutocompleteDropdown.swift
//  CLI
//
//  Dropdown showing command suggestions above the input field
//

import SwiftTUI
import Foundation

/// Dropdown view showing command autocomplete suggestions
struct AutocompleteDropdown: View {
    /// Available suggestions to display
    let suggestions: [CommandType]

    /// Currently selected suggestion index
    let selectedIndex: Int

    /// Callback when a suggestion is selected
    let onSelect: (CommandType) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Text("─ Commands ─")
                .foregroundColor(.blue)

            // Suggestion list
            ForEach(suggestions.indices, id: \.self) { index in
                suggestionRow(for: suggestions[index], isSelected: index == selectedIndex)
            }

            // Footer hint
            Text("↑↓ navigate  Enter select  Esc cancel")
                .foregroundColor(.white)
        }
        .border()
        .padding(.bottom, 1)
    }

    /// Individual suggestion row
    private func suggestionRow(for command: CommandType, isSelected: Bool) -> some View {
        HStack {
            // Selection indicator
            Text(isSelected ? "▸" : " ")
                .foregroundColor(.cyan)

            // Command name
            Text("/\(command.rawValue)")
                .foregroundColor(isSelected ? .cyan : .white)
                .bold()

            // Separator
            Text(" - ")
                .foregroundColor(.white)

            // Description
            Text(command.description)
                .foregroundColor(.white)
        }
        .background(isSelected ? Color.blue : Color.black)
    }
}

// MARK: - Preview

#if DEBUG
extension AutocompleteDropdown {
    static var preview: AutocompleteDropdown {
        AutocompleteDropdown(
            suggestions: [.help, .settings, .status, .clear],
            selectedIndex: 1,
            onSelect: { _ in }
        )
    }
}
#endif
