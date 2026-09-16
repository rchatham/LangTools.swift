//
//  PlanMode.swift
//  CLI
//
//  Manages plan mode workflow for implementation planning and approval
//

import Foundation

/// Plan mode state management
@MainActor
final class PlanModeManager: ObservableObject {
    /// Shared singleton instance
    static let shared = PlanModeManager()

    /// Whether currently in plan mode
    @Published private(set) var isInPlanMode: Bool = false

    /// Current plan file path
    @Published private(set) var planFilePath: String?

    /// Current plan content
    @Published private(set) var planContent: String?

    /// Plan approval status
    @Published private(set) var approvalStatus: PlanApprovalStatus = .none

    /// Allowed prompts for plan execution
    @Published private(set) var allowedPrompts: [AllowedPrompt] = []

    /// Plans directory
    private let plansDirectory: URL

    private init() {
        // Create plans directory in ~/.claude/plans/
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        self.plansDirectory = homeDir
            .appendingPathComponent(".claude")
            .appendingPathComponent("plans")

        // Ensure directory exists
        try? FileManager.default.createDirectory(
            at: plansDirectory,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Plan Mode Control

    /// Enter plan mode
    func enterPlanMode() -> String {
        guard !isInPlanMode else {
            return "Already in plan mode. Use ExitPlanMode to exit."
        }

        // Generate unique plan file name
        let planName = generatePlanName()
        let planFile = plansDirectory.appendingPathComponent("\(planName).md")

        isInPlanMode = true
        planFilePath = planFile.path
        planContent = nil
        approvalStatus = .pending
        allowedPrompts = []

        // Create initial plan file
        let initialContent = """
        # Implementation Plan

        *Plan created: \(Date())*

        ## Overview

        <!-- Describe the implementation approach here -->

        ## Steps

        <!-- List implementation steps -->

        ## Files to Modify

        <!-- List files that will be changed -->

        """

        try? initialContent.write(toFile: planFile.path, atomically: true, encoding: .utf8)

        return """
        Entered plan mode.
        Plan file: \(planFile.path)

        In plan mode, you can:
        - Explore the codebase (read-only tools: Read, Glob, Grep)
        - Design your implementation approach
        - Write your plan to the plan file

        Use ExitPlanMode when ready for user approval.
        """
    }

    /// Exit plan mode with approval request
    func exitPlanMode(allowedPrompts: [AllowedPrompt] = []) -> ExitPlanResult {
        guard isInPlanMode else {
            return .failure("Not in plan mode.")
        }

        // Read current plan content
        if let path = planFilePath {
            planContent = try? String(contentsOfFile: path, encoding: .utf8)
        }

        self.allowedPrompts = allowedPrompts
        approvalStatus = .awaitingApproval

        return .success(PlanApprovalRequest(
            planFilePath: planFilePath ?? "",
            planContent: planContent ?? "",
            allowedPrompts: allowedPrompts
        ))
    }

    /// User approves the plan
    func approvePlan() {
        guard approvalStatus == .awaitingApproval else { return }

        isInPlanMode = false
        approvalStatus = .approved
    }

    /// User rejects the plan
    func rejectPlan(reason: String? = nil) {
        guard approvalStatus == .awaitingApproval else { return }

        approvalStatus = .rejected(reason: reason)
        // Stay in plan mode for revision
    }

    /// Reset plan mode state
    func reset() {
        isInPlanMode = false
        planFilePath = nil
        planContent = nil
        approvalStatus = .none
        allowedPrompts = []
    }

    // MARK: - Plan File Operations

    /// Update plan content
    func updatePlan(_ content: String) throws {
        guard let path = planFilePath else {
            throw PlanModeError.noPlanFile
        }

        try content.write(toFile: path, atomically: true, encoding: .utf8)
        planContent = content
    }

    /// Read current plan
    func readPlan() throws -> String {
        guard let path = planFilePath else {
            throw PlanModeError.noPlanFile
        }

        return try String(contentsOfFile: path, encoding: .utf8)
    }

    // MARK: - Helpers

    private func generatePlanName() -> String {
        // Generate a memorable name like "vast-humming-robin"
        let adjectives = ["vast", "calm", "bold", "swift", "keen", "warm", "cool", "bright"]
        let verbs = ["humming", "running", "flying", "dancing", "singing", "gliding"]
        let nouns = ["robin", "falcon", "river", "mountain", "forest", "meadow"]

        let adj = adjectives.randomElement() ?? "swift"
        let verb = verbs.randomElement() ?? "flying"
        let noun = nouns.randomElement() ?? "falcon"

        return "\(adj)-\(verb)-\(noun)"
    }
}

// MARK: - Supporting Types

/// Plan approval status
enum PlanApprovalStatus: Equatable {
    case none
    case pending
    case awaitingApproval
    case approved
    case rejected(reason: String?)

    static func == (lhs: PlanApprovalStatus, rhs: PlanApprovalStatus) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none), (.pending, .pending), (.awaitingApproval, .awaitingApproval), (.approved, .approved):
            return true
        case (.rejected(let l), .rejected(let r)):
            return l == r
        default:
            return false
        }
    }
}

/// Allowed prompt for bash execution
struct AllowedPrompt: Codable, Equatable {
    let tool: String
    let prompt: String
}

/// Plan approval request
struct PlanApprovalRequest {
    let planFilePath: String
    let planContent: String
    let allowedPrompts: [AllowedPrompt]
}

/// Result of exit plan mode
enum ExitPlanResult {
    case success(PlanApprovalRequest)
    case failure(String)
}

/// Plan mode errors
enum PlanModeError: LocalizedError {
    case noPlanFile
    case notInPlanMode
    case planNotApproved

    var errorDescription: String? {
        switch self {
        case .noPlanFile:
            return "No plan file is currently active"
        case .notInPlanMode:
            return "Not currently in plan mode"
        case .planNotApproved:
            return "Plan has not been approved"
        }
    }
}
