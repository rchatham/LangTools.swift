//
//  ChatHistoryListView.swift
//  ChatHistory
//
//  Ported from Botsworth's ConversationListView and driven by a
//  ConversationListModel instead of a SwiftData store.
//

import SwiftUI
import Chat
#if os(macOS)
import AppKit
#endif

public enum ChatHistoryListStyle {
    /// A selectable sidebar list (macOS, iPad split view).
    case sidebar
    /// Tappable rows that call `onSelect` (iPhone sheet or stack).
    case stack
}

/// A searchable list of conversations with rename, pin, archive, export and
/// delete actions. `header` renders above the conversations, for example a
/// host's pinned main thread.
public struct ChatHistoryListView<Header: View>: View {
    @ObservedObject private var model: ConversationListModel
    @Binding private var selection: UUID?
    private let style: ChatHistoryListStyle
    private let title: String
    private let onSelect: ((UUID) -> Void)?
    private let onNewConversation: ((String?) -> Void)?
    private let header: Header

    @State private var conversationToDelete: ConversationRecord?
    @State private var conversationToRename: ConversationRecord?
    @State private var conversationToExport: ConversationRecord?
    @State private var showingNewConversation = false

    public init(
        model: ConversationListModel,
        selection: Binding<UUID?>,
        style: ChatHistoryListStyle,
        title: String = "Conversations",
        onSelect: ((UUID) -> Void)? = nil,
        onNewConversation: ((String?) -> Void)? = nil,
        @ViewBuilder header: () -> Header
    ) {
        self.model = model
        self._selection = selection
        self.style = style
        self.title = title
        self.onSelect = onSelect
        self.onNewConversation = onNewConversation
        self.header = header()
    }

    public var body: some View {
        list
            #if os(iOS)
            .searchable(text: $model.searchText, prompt: "Search conversations")
            #endif
            .navigationTitle(title)
            #if os(iOS)
            .toolbar {
                if onNewConversation != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showingNewConversation = true
                        } label: {
                            Label("New Conversation", systemImage: "square.and.pencil")
                        }
                    }
                }
            }
            #endif
            .confirmationDialog(
                "Delete Conversation",
                isPresented: Binding(
                    get: { conversationToDelete != nil },
                    set: { if !$0 { conversationToDelete = nil } }
                ),
                presenting: conversationToDelete
            ) { conversation in
                Button("Delete", role: .destructive) {
                    withAnimation {
                        if selection == conversation.id { selection = nil }
                        try? model.library.deleteConversations([conversation.id])
                    }
                    conversationToDelete = nil
                }
                Button("Cancel", role: .cancel) { conversationToDelete = nil }
            } message: { conversation in
                Text("Are you sure you want to delete \"\(conversation.title)\"? This action cannot be undone.")
            }
            .sheet(isPresented: $showingNewConversation) {
                NewConversationSheet { title in onNewConversation?(title) }
            }
            .sheet(item: $conversationToRename) { conversation in
                RenameConversationSheet(initialTitle: conversation.title) { title in
                    try? model.library.rename(conversation.id, to: title)
                }
            }
            .sheet(item: $conversationToExport) { conversation in
                ExportConversationSheet(conversation: conversation, library: model.library)
            }
    }

    @ViewBuilder
    private var list: some View {
        switch style {
        case .sidebar:
            List(selection: $selection) {
                #if os(macOS)
                Section { searchBarRow }
                #endif
                header
                sections
            }
            .listStyle(.sidebar)
        case .stack:
            List {
                header
                sections
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.sidebar)
            #endif
        }
    }

    @ViewBuilder
    private var sections: some View {
        if !model.pinned.isEmpty {
            Section("Pinned") { rows(model.pinned) }
        }
        Section { rows(model.unpinned) }
    }

    private func rows(_ conversations: [ConversationRecord]) -> some View {
        ForEach(conversations) { conversation in
            row(for: conversation)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        conversationToDelete = conversation
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .contextMenu { contextMenu(for: conversation) }
        }
    }

    @ViewBuilder
    private func row(for conversation: ConversationRecord) -> some View {
        switch style {
        case .sidebar:
            ChatHistoryRow(conversation: conversation)
                .tag(Optional(conversation.id))
        case .stack:
            Button {
                selection = conversation.id
                onSelect?(conversation.id)
            } label: {
                ChatHistoryRow(conversation: conversation)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func contextMenu(for conversation: ConversationRecord) -> some View {
        Button {
            selection = conversation.id
            onSelect?(conversation.id)
        } label: {
            Label("Open", systemImage: "arrow.right.circle")
        }
        Button {
            conversationToRename = conversation
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        Button {
            try? model.library.setPinned(conversation.id, !conversation.isPinned)
        } label: {
            Label(conversation.isPinned ? "Unpin" : "Pin", systemImage: conversation.isPinned ? "pin.slash" : "pin")
        }
        Button {
            conversationToExport = conversation
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        Divider()
        Button(role: .destructive) {
            conversationToDelete = conversation
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    #if os(macOS)
    private var searchBarRow: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("Search conversations", text: $model.searchText)
                .textFieldStyle(.plain)
            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .listRowSeparator(.hidden)
    }
    #endif
}

public extension ChatHistoryListView where Header == EmptyView {
    init(
        model: ConversationListModel,
        selection: Binding<UUID?>,
        style: ChatHistoryListStyle,
        title: String = "Conversations",
        onSelect: ((UUID) -> Void)? = nil,
        onNewConversation: ((String?) -> Void)? = nil
    ) {
        self.init(
            model: model,
            selection: selection,
            style: style,
            title: title,
            onSelect: onSelect,
            onNewConversation: onNewConversation,
            header: { EmptyView() }
        )
    }
}

public struct ChatHistoryRow: View {
    public let conversation: ConversationRecord

    public init(conversation: ConversationRecord) {
        self.conversation = conversation
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(conversation.title)
                .font(.headline)
                .lineLimit(1)
            if let preview = conversation.lastMessagePreview {
                Text(preview)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            HStack {
                Text(Self.relativeTime(conversation.updatedAt))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                if let model = conversation.settings.modelIdentifier {
                    Text(model)
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2))
                        .cornerRadius(4)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private static func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Sheets

public struct NewConversationSheet: View {
    private let onCreate: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""

    public init(onCreate: @escaping (String?) -> Void) {
        self.onCreate = onCreate
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Conversation Title (Optional)", text: $title)
                } header: {
                    Text("New Conversation")
                } footer: {
                    Text("Leave empty to auto-generate from first message")
                }
            }
            .navigationTitle("New Conversation")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        onCreate(trimmed.isEmpty ? nil : trimmed)
                        dismiss()
                    }
                }
            }
        }
    }
}

public struct RenameConversationSheet: View {
    private let onRename: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String

    public init(initialTitle: String, onRename: @escaping (String) -> Void) {
        self.onRename = onRename
        _title = State(initialValue: initialTitle)
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Conversation Title", text: $title)
                        #if os(iOS)
                        .textInputAutocapitalization(.words)
                        #endif
                } header: {
                    Text("Rename Conversation")
                } footer: {
                    Text("Enter a new name for this conversation")
                }
            }
            .navigationTitle("Rename")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Rename") {
                        onRename(title)
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

public struct ExportConversationSheet: View {
    private let conversation: ConversationRecord
    private let library: ChatHistoryLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var format: ChatExportFormat = .markdown
    @State private var content = ""

    public init(conversation: ConversationRecord, library: ChatHistoryLibrary) {
        self.conversation = conversation
        self.library = library
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Format", selection: $format) {
                        ForEach(ChatExportFormat.allCases) { format in
                            Text(format.rawValue).tag(format)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Export Format")
                }
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(conversation.title).font(.headline)
                        Text("\(conversation.messageCount) messages")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Conversation")
                }
                Section {
                    ScrollView {
                        Text(content)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 200)
                } header: {
                    Text("Preview")
                }
            }
            .navigationTitle("Export Conversation")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    #if os(iOS)
                    ShareLink(item: content, subject: Text(conversation.title), message: Text("Exported conversation")) {
                        Text("Share")
                    }
                    #else
                    Button("Copy") {
                        #if os(macOS)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(content, forType: .string)
                        #endif
                        dismiss()
                    }
                    #endif
                }
            }
            .onAppear(perform: refresh)
            .onChange(of: format) { _, _ in refresh() }
        }
    }

    private func refresh() {
        content = (try? library.export(conversation.id, format: format)) ?? ""
    }
}
