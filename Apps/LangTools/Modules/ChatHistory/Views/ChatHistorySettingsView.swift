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
        Form {
            Section {
                Picker("Keep conversations", selection: policyBinding) {
                    Text("Forever").tag(ChatRetentionPolicy.keepForever)
                    ForEach(ChatRetentionPolicy.presetDays, id: \.self) { days in
                        Text(Self.label(days: days)).tag(ChatRetentionPolicy.deleteInactive(afterDays: days))
                    }
                }
            } header: {
                Text("Retention")
            } footer: {
                Text("Conversations with no activity for this long are deleted automatically. Pinned conversations and long-running threads are always kept.")
            }

            if let report = library.lastRetentionReport, !report.deletedIDs.isEmpty {
                Section {
                    Text("Last cleanup deleted \(report.deletedIDs.count) of \(report.evaluatedCount) conversations.")
                        .foregroundColor(.secondary)
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundColor(.red)
                }
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
                let wouldDelete = (try? library.retentionPreview(for: policy).count) ?? 0
                if wouldDelete > 0 {
                    pendingDeletionCount = wouldDelete
                    pendingPolicy = policy
                } else {
                    apply(policy)
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
