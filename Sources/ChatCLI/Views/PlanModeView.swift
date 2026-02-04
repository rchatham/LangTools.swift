//
//  PlanModeView.swift
//  ChatCLI
//
//  Views for displaying plan mode status and approval workflow
//

import SwiftTUI
import Foundation

// Note: PlanApprovalRequest, PlanApprovalStatus, AllowedPrompt defined in Features/PlanMode.swift

/// Banner showing plan mode is active
struct PlanModeBannerView: View {
    let planFilePath: String?

    var body: some View {
        HStack {
            Text("📋")
                .foregroundColor(.yellow)

            Text("PLAN MODE")
                .foregroundColor(.yellow)
                .bold()

            Text(" - Read-only exploration")
                .foregroundColor(.white)

            Spacer()

            if let path = planFilePath {
                let filename = (path as NSString).lastPathComponent
                Text(filename)
                    .foregroundColor(.cyan)
            }
        }
    }
}

/// View for displaying plan approval request
struct PlanApprovalView: View {
    let request: PlanApprovalRequest
    let onApprove: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading) {
            // Header
            HStack {
                Text("📋")
                    .foregroundColor(.cyan)
                Text("Plan Ready for Review")
                    .foregroundColor(.cyan)
                    .bold()
            }

            // Plan file info
            HStack {
                Text("  Plan: ")
                    .foregroundColor(.white)
                Text((request.planFilePath as NSString).lastPathComponent)
                    .foregroundColor(.cyan)
            }

            // Plan preview (first few lines)
            planPreview

            // Allowed prompts if any
            if !request.allowedPrompts.isEmpty {
                allowedPromptsSection
            }

            // Approval prompt
            HStack {
                Text("  ")
                Text("[A]pprove")
                    .foregroundColor(.green)
                Text(" or ")
                    .foregroundColor(.white)
                Text("[R]eject")
                    .foregroundColor(.red)
                Text("?")
                    .foregroundColor(.white)
            }
        }
    }

    @ViewBuilder
    private var planPreview: some View {
        let lines = request.planContent.components(separatedBy: CharacterSet.newlines)
        let previewLines = Array(lines.prefix(10))

        VStack(alignment: .leading) {
            Text("  ─── Plan Preview ───")
                .foregroundColor(.white)

            ForEach(previewLines.indices, id: \.self) { index in
                Text("  \(previewLines[index])")
                    .foregroundColor(.white)
            }

            if lines.count > 10 {
                Text("  ... (\(lines.count - 10) more lines)")
                    .foregroundColor(.white)
            }

            Text("  ─────────────────────")
                .foregroundColor(.white)
        }
    }

    @ViewBuilder
    private var allowedPromptsSection: some View {
        VStack(alignment: .leading) {
            Text("  Requested Permissions:")
                .foregroundColor(.yellow)

            ForEach(request.allowedPrompts.indices, id: \.self) { index in
                let prompt = request.allowedPrompts[index]
                HStack {
                    Text("    • [\(prompt.tool)]")
                        .foregroundColor(.cyan)
                    Text(prompt.prompt)
                        .foregroundColor(.white)
                }
            }
        }
    }
}

/// View showing plan mode status indicator
struct PlanModeStatusView: View {
    let status: PlanApprovalStatus

    var body: some View {
        HStack {
            switch status {
            case .none:
                EmptyView()

            case .pending:
                Text("📋")
                    .foregroundColor(.yellow)
                Text("Planning...")
                    .foregroundColor(.yellow)

            case .awaitingApproval:
                Text("⏳")
                    .foregroundColor(.yellow)
                Text("Awaiting approval")
                    .foregroundColor(.yellow)

            case .approved:
                Text("✓")
                    .foregroundColor(.green)
                Text("Plan approved")
                    .foregroundColor(.green)

            case .rejected(let reason):
                Text("✗")
                    .foregroundColor(.red)
                Text("Plan rejected")
                    .foregroundColor(.red)
                if let reason = reason {
                    Text("(\(reason))")
                        .foregroundColor(.white)
                }
            }
        }
    }
}

/// Compact plan mode indicator for header
struct PlanModeIndicatorView: View {
    let isActive: Bool

    var body: some View {
        if isActive {
            Text("[PLAN MODE]")
                .foregroundColor(.yellow)
                .bold()
        }
    }
}

// MARK: - Preview Helpers

#if DEBUG
extension PlanApprovalView {
    static var preview: PlanApprovalView {
        PlanApprovalView(
            request: PlanApprovalRequest(
                planFilePath: "/Users/test/.claude/plans/vast-humming-robin.md",
                planContent: """
                # Implementation Plan

                ## Overview
                Add user authentication to the application.

                ## Steps
                1. Create User model
                2. Add login/logout routes
                3. Implement JWT tokens
                """,
                allowedPrompts: [
                    AllowedPrompt(tool: "Bash", prompt: "run tests"),
                    AllowedPrompt(tool: "Bash", prompt: "install dependencies")
                ]
            ),
            onApprove: {},
            onReject: {}
        )
    }
}
#endif
