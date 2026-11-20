//
//  ChatHistorySettingsView.swift
//  ChatHistory
//

import SwiftUI
import Chat

/// Retention settings. Turning on a policy that would delete conversations
/// right away asks for confirmation and says how many.
public struct ChatHistorySettingsView: View {
    @ObservedObject private var library: ChatHistoryLibrary
    @State private var pendingPolicy: ChatRetentionPolicy?
    @State private var pendingDeletionCount = 0
    @State private var errorMessage: String?

    public init(library: ChatHistoryLibrary) {
        self.library = library
    }

    public var body: some View {
        content
    }

    /// Settings hosts already provide the container: iOS wraps a custom tab
    /// in a `Form`, macOS in a `ScrollView`. A second `Form` collapses to
    /// a sliver, so this view emits sections on iOS and a stack on macOS,
    /// like the other app-owned tabs.
    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 12) {
            Text("Retention")
                .font(.title2)
                .fontWeight(.semibold)
            retentionPicker
                .frame(maxWidth: 320, alignment: .leading)
            Text(Self.retentionFooter)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let reportText {
                Text(reportText).foregroundColor(.secondary)
            }
            if let errorMessage {
                Text(errorMessage).foregroundColor(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        #else
        Section {
            retentionPicker
        } header: {
            Text("Retention")
        } footer: {
            Text(Self.retentionFooter)
        }
        if let reportText {
            Section {
                Text(reportText).foregroundColor(.secondary)
            }
        }
        if let errorMessage {
            Section {
                Text(errorMessage).foregroundColor(.red)
            }
        }
        #endif
    }

    private static let retentionFooter = "Conversations with no activity for this long are deleted automatically. Pinned conversations and long-running threads are always kept."

    private var reportText: String? {
        guard let report = library.lastRetentionReport, !report.deletedIDs.isEmpty else { return nil }
        return "Last cleanup deleted \(report.deletedIDs.count) of \(report.evaluatedCount) conversations."
    }

    /// The picker carries the confirmation, so it is attached once however
    /// the content is laid out.
    private var retentionPicker: some View {
        Picker("Keep conversations", selection: policyBinding) {
            Text("Forever").tag(ChatRetentionPolicy.keepForever)
            ForEach(ChatRetentionPolicy.presetDays, id: \.self) { days in
                Text(Self.label(days: days)).tag(ChatRetentionPolicy.deleteInactive(afterDays: days))
            }
        }
        .confirmationDialog(
            "Delete \(pendingDeletionCount) conversations?",
            isPresented: Binding(
                get: { pendingPolicy != nil },
                set: { if !$0 { pendingPolicy = nil } }
            ),
            presenting: pendingPolicy
        ) { policy in
            Button("Delete and Apply", role: .destructive) {
                apply(policy)
                pendingPolicy = nil
            }
            Button("Cancel", role: .cancel) { pendingPolicy = nil }
        } message: { _ in
            Text("\(pendingDeletionCount) conversations are already older than this and will be deleted now. This cannot be undone.")
        }
    }

    private var policyBinding: Binding<ChatRetentionPolicy> {
        Binding(
            get: { library.retentionPolicy },
            set: { policy in
                do {
                    let wouldDelete = try library.retentionPreview(for: policy).count
                    errorMessage = nil
                    if wouldDelete > 0 {
                        pendingDeletionCount = wouldDelete
                        pendingPolicy = policy
                    } else {
                        apply(policy)
                    }
                } catch {
                    // A failed preview is not consent to delete an unknown
                    // number of conversations or enable future deletion.
                    errorMessage = error.localizedDescription
                }
            }
        )
    }

    private func apply(_ policy: ChatRetentionPolicy) {
        do {
            try library.setRetentionPolicy(policy)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func label(days: Int) -> String {
        switch days {
        case 365: return "1 year"
        case let days where days % 30 == 0: return "\(days / 30) months"
        default: return "\(days) days"
        }
    }
}

public extension CustomSettingsTab {
    /// A "History" settings tab with retention controls.
    @MainActor
    static func chatHistory(library: ChatHistoryLibrary) -> CustomSettingsTab {
        CustomSettingsTab(id: "chat-history", name: "History", icon: "clock.arrow.circlepath") {
            AnyView(ChatHistorySettingsView(library: library))
        }
    }
}
