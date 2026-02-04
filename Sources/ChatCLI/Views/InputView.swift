//
//  InputView.swift
//  ChatCLI
//
//  User input view with prompt
//

import SwiftTUI
import Foundation

/// Input view for user text entry
struct InputView: View {
    let onSubmit: (String) -> Void
    let placeholder: String

    init(placeholder: String = "Enter message...", onSubmit: @escaping (String) -> Void) {
        self.placeholder = placeholder
        self.onSubmit = onSubmit
    }

    var body: some View {
        HStack {
            Text(">")
                .foregroundColor(.green)
                .bold()

            Text(" ")

            TextField(placeholder: placeholder) { text in
                onSubmit(text)
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
}
#endif
