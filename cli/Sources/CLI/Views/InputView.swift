//
//  InputView.swift
//  CLI
//
//  User input view with prompt
//

import SwiftTUI
import Foundation

/// Input view for user text entry
struct InputView: View {
    let onSubmit: (String) -> Void
    let placeholder: String

    /// Optional hint text to display (e.g., autocomplete preview)
    var hint: String?

    /// Whether to show the input as disabled/readonly
    var isDisabled: Bool

    init(
        placeholder: String = "Enter message...",
        hint: String? = nil,
        isDisabled: Bool = false,
        onSubmit: @escaping (String) -> Void
    ) {
        self.placeholder = placeholder
        self.hint = hint
        self.isDisabled = isDisabled
        self.onSubmit = onSubmit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Hint text if provided
            if let hint = hint {
                Text("  \(hint)")
                    .foregroundColor(.white)
                    .italic()
            }

            // Input row
            HStack {
                Text(isDisabled ? "·" : ">")
                    .foregroundColor(isDisabled ? .white : .green)
                    .bold()

                Text(" ")

                TextField(placeholder: placeholder) { text in
                    if !isDisabled {
                        onSubmit(text)
                    }
                }
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
extension InputView {
    static var preview: InputView {
        InputView { text in
            print("Submitted: \(text)")
        }
    }

    static var previewWithHint: InputView {
        InputView(
            hint: "Type /help for commands",
            onSubmit: { _ in }
        )
    }

    static var previewDisabled: InputView {
        InputView(
            isDisabled: true,
            onSubmit: { _ in }
        )
    }
}
#endif
