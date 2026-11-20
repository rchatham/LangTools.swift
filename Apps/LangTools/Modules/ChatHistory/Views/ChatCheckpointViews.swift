//
//  ChatCheckpointViews.swift
//  ChatHistory
//
//  Shows where a conversation's older messages were summarized to keep
//  requests inside the model's context window. The cues come from the
//  session's stored checkpoints, never from messages, so nothing here is
//  sent to the model, saved as content or exported.
//

import SwiftUI
import ChatContext

/// A divider in the transcript, placed after the last message a checkpoint
/// covers. Tapping it shows the summary.
public struct ChatCheckpointMarker: View {
    let checkpoint: ChatSessionCheckpoint
    @State private var showsSummary = false

    public init(checkpoint: ChatSessionCheckpoint) {
        self.checkpoint = checkpoint
    }

    public var body: some View {
        Button {
            showsSummary = true
        } label: {
            VStack(spacing: 2) {
                HStack(spacing: 8) {
                    rule
                    Label(ChatCheckpointText.title, systemImage: "rectangle.compress.vertical")
                        .font(.caption.weight(.medium))
                        .fixedSize()
                    rule
                }
                Text(ChatCheckpointText.detail(for: checkpoint))
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ChatCheckpointText.accessibilityLabel(for: checkpoint))
        .accessibilityHint("Shows the summary")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("chat.checkpointMarker")
        .sheet(isPresented: $showsSummary) {
            ChatCheckpointSummaryView(checkpoint: checkpoint)
        }
    }

    private var rule: some View {
        Rectangle()
            .fill(.separator)
            .frame(height: 1)
    }
}

/// The summary a checkpoint holds, with who wrote it and how large it is.
public struct ChatCheckpointSummaryView: View {
    let checkpoint: ChatSessionCheckpoint
    @Environment(\.dismiss) private var dismiss

    public init(checkpoint: ChatSessionCheckpoint) {
        self.checkpoint = checkpoint
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                        if let count = checkpoint.coveredMessageCount {
                            row("Covers", ChatCheckpointText.messages(count))
                        }
                        row("Written by", ChatCheckpointText.author(for: checkpoint))
                        row("Size", "About \(checkpoint.checkpoint.tokenEstimate.formatted()) tokens")
                        row("Created", checkpoint.checkpoint.createdAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    .font(.callout)
                    if !checkpoint.isSaved {
                        Text("This summary is in use until the next one is written. It is not saved, so it is gone after the app restarts.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                    Text(Self.formatted(checkpoint.checkpoint.summary))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("chat.checkpointSummary.text")
                }
                .padding()
            }
            .navigationTitle("Summary of earlier messages")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("chat.checkpointSummary.done")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 420)
        #endif
        .accessibilityIdentifier("chat.checkpointSummary")
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
        }
    }

    /// Summaries are usually Markdown; keep their line breaks and render
    /// inline styling. Falls back to plain text.
    static func formatted(_ summary: String) -> AttributedString {
        (try? AttributedString(
            markdown: summary,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(summary)
    }
}

/// Shown above a session's messages: progress while older messages are
/// being summarized, and, while earlier messages are not loaded, the
/// checkpoint the conversation opened from with its summary and a way to
/// load what came before.
public struct ChatSessionContextHeader: View {
    @ObservedObject var session: ChatSession
    @State private var failure: String?
    @State private var shownSummary: ChatSessionCheckpoint?

    public init(session: ChatSession) {
        self.session = session
    }

    public var body: some View {
        let leading = session.leadingCheckpoint
        if session.isCompacting || leading != nil || session.canLoadEarlierMessages {
            VStack(spacing: 6) {
                if session.isCompacting {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Summarizing earlier messages…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Summarizing earlier messages to fit the model's context")
                    .accessibilityIdentifier("chat.compactingStatus")
                }
                if let leading {
                    VStack(spacing: 2) {
                        Label(ChatCheckpointText.title, systemImage: "rectangle.compress.vertical")
                            .font(.caption.weight(.medium))
                        Text(ChatCheckpointText.detail(for: leading))
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(ChatCheckpointText.accessibilityLabel(for: leading))
                    .accessibilityIdentifier("chat.leadingCheckpoint")
                }
                if leading != nil || session.canLoadEarlierMessages {
                    HStack(spacing: 20) {
                        if let leading {
                            Button("Show summary") { shownSummary = leading }
                                .accessibilityIdentifier("chat.showSummary")
                        }
                        if session.canLoadEarlierMessages {
                            Button("Load earlier messages") { loadEarlierMessages() }
                                .accessibilityIdentifier("loadEarlierMessages")
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.callout)
                }
                if let failure {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(.bar)
            .animation(.default, value: session.isCompacting)
            .sheet(item: $shownSummary) { checkpoint in
                ChatCheckpointSummaryView(checkpoint: checkpoint)
            }
        }
    }

    private func loadEarlierMessages() {
        do {
            try session.loadEarlierMessages()
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// The marker for the checkpoint ending at one message, for a message
/// list's per-message supplementary content. It observes the session, so a
/// checkpoint written during a send appears without reloading the list. A
/// checkpoint shown in `ChatSessionContextHeader` is not repeated here.
public struct ChatSessionCheckpointMarker: View {
    @ObservedObject var session: ChatSession
    let messageID: UUID

    public init(session: ChatSession, messageID: UUID) {
        self.session = session
        self.messageID = messageID
    }

    public var body: some View {
        if let checkpoint = session.inlineCheckpoint(after: messageID) {
            ChatCheckpointMarker(checkpoint: checkpoint)
        }
    }
}

enum ChatCheckpointText {
    static let title = "Earlier messages summarized"

    static func messages(_ count: Int) -> String {
        count == 1 ? "1 message" : "\(count.formatted()) messages"
    }

    static func author(for checkpoint: ChatSessionCheckpoint) -> String {
        checkpoint.isExtractive ? "Summarized without the model" : checkpoint.checkpoint.model
    }

    static func detail(for checkpoint: ChatSessionCheckpoint) -> String {
        var parts: [String] = []
        if let count = checkpoint.coveredMessageCount { parts.append(messages(count)) }
        parts.append(checkpoint.checkpoint.createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
        if checkpoint.isExtractive { parts.append("without the model") }
        return parts.joined(separator: " · ")
    }

    static func accessibilityLabel(for checkpoint: ChatSessionCheckpoint) -> String {
        var label = title
        if let count = checkpoint.coveredMessageCount { label += ", \(messages(count))" }
        label += ", \(checkpoint.checkpoint.createdAt.formatted(date: .abbreviated, time: .shortened))"
        if checkpoint.isExtractive { label += ", summarized without the model" }
        return label
    }
}
