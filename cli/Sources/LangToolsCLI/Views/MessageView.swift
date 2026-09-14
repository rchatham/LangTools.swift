//
//  MessageView.swift
//  CLI
//
//  Individual message display with role-based styling
//

import SwiftTUI
import Foundation

/// View for displaying a single chat message.
struct MessageView: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: .leading) {
            switch message.role {
            case .user:
                UserMessageView(content: message.content)
            case .assistant:
                AssistantMessageView(content: message.content)
            case .system:
                SystemMessageView(content: message.content)
            case .toolCall:
                CompactToolMessageView(
                    kind: .call,
                    toolName: message.toolName ?? "Tool",
                    content: message.content
                )
            case .toolResult:
                CompactToolMessageView(
                    kind: .result(isError: message.toolFailed),
                    toolName: message.toolName ?? "Tool",
                    content: message.content
                )
            }
        }
    }
}

struct UserMessageView: View {
    let content: String

    var body: some View {
        // Rely on HStack's default spacing for the single separator between the
        // label and the content; a leading space in the Text itself would stack
        // on top of that spacing and produce stray double indentation.
        HStack(alignment: .top) {
            Text("You:")
                .foregroundColor(.green)
                .bold()
            Text(content)
                .foregroundColor(.white)
        }
    }
}

struct AssistantMessageView: View {
    let content: String

    var body: some View {
        VStack(alignment: .leading) {
            Text("Assistant:")
                .foregroundColor(.yellow)
                .bold()
            ForEach(bodyLines.indices, id: \.self) { index in
                Text(bodyLines[index])
                    .foregroundColor(.white)
            }
        }
    }

    /// Dedented body lines so continuation lines align consistently under the
    /// "Assistant:" header without stray leading indentation.
    private var bodyLines: [String] {
        MessageLineBuilder.assistantBodyLines(for: content)
    }
}

struct SystemMessageView: View {
    let content: String

    var body: some View {
        VStack(alignment: .leading) {
            ForEach(bodyLines.indices, id: \.self) { index in
                Text(bodyLines[index])
                    .foregroundColor(.cyan)
            }
        }
    }

    private var bodyLines: [String] {
        MessageLineBuilder.systemLines(for: content)
    }
}

/// Tool events are intentionally non-selectable so the message field retains keyboard focus.
/// SwiftTUI has no independent pointer or disclosure input, so a bounded detail preview is safer
/// than an expandable control that would intercept chat input.
struct CompactToolMessageView: View {
    enum Kind {
        case call
        case result(isError: Bool)
    }

    let kind: Kind
    let toolName: String
    let content: String

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(prefix)
                    .foregroundColor(headerColor)
                    .bold()
                Text(toolName)
                    .foregroundColor(headerColor)
            }

            // Body lines align directly under their own header: the call body
            // sits at the same column as `↳ Call`, and the result body sits under
            // the nested `  ✓ Result` header — preserving the call→result
            // hierarchy without redundant extra leading spaces.
            ForEach(previewLines.indices, id: \.self) { index in
                Text("\(bodyIndent)\(previewLines[index])")
                    .foregroundColor(.white)
            }
        }
    }

    /// Indentation matching the header prefix so the body aligns under it.
    private var bodyIndent: String {
        MessageLineBuilder.bodyIndent(forPrefix: prefix)
    }

    private var isResult: Bool {
        if case .result = kind { return true }
        return false
    }

    private var prefix: String {
        switch kind {
        case .call:
            return "↳ Call"
        case .result(let isError):
            return isError ? "  ✗ Result" : "  ✓ Result"
        }
    }

    private var headerColor: Color {
        switch kind {
        case .result(let isError) where isError:
            return .red
        default:
            return .magenta
        }
    }

    private var previewLines: [String] {
        MessageLineBuilder.toolPreviewLines(content: content, isResult: isResult)
    }
}

struct ToolMessagePreview {
    static func lines(for content: String, limit: Int, characterLimit: Int) -> [String] {
        let normalized = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return ["(no details)"] }

        let clipped = normalized.count > characterLimit
            ? String(normalized.prefix(characterLimit)) + "…"
            : normalized
        let lines = clipped.components(separatedBy: .newlines)
        let visible = Array(lines.prefix(limit))
        if lines.count > limit, let last = visible.last {
            return Array(visible.dropLast()) + [last + " …"]
        }
        return visible
    }
}

#if DEBUG
extension MessageView {
    static var userPreview: MessageView {
        MessageView(message: ChatMessage(role: .user, content: "Hello!"))
    }

    static var assistantPreview: MessageView {
        MessageView(message: ChatMessage(role: .assistant, content: "Hello! How can I help you today?"))
    }

    static var systemPreview: MessageView {
        MessageView(message: ChatMessage(role: .system, content: "System message"))
    }
}
#endif
