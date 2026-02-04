//
//  EnterPlanModeTool.swift
//  ChatCLI
//
//  Tool for entering plan mode for implementation planning
//

import Foundation
import OpenAI

/// Tool for entering plan mode
struct EnterPlanModeTool: ExecutableTool {
    static let name = "enter_plan_mode"

    static let description = """
        Enter plan mode for designing implementation approaches before writing code.

        Use this tool when:
        - Starting a non-trivial implementation task
        - Multiple valid approaches exist
        - The task affects multiple files
        - User preferences matter for the approach

        In plan mode, you can explore the codebase with read-only tools (Read, Glob, Grep)
        and design an implementation plan for user approval.
        """

    static let parametersSchema = OpenAI.Tool.FunctionSchema.Parameters(
        properties: [:],
        required: []
    )

    static func execute(parameters: [String: Any]) async throws -> String {
        return await MainActor.run {
            let manager = PlanModeManager.shared
            return manager.enterPlanMode()
        }
    }
}

/// Tool for exiting plan mode with approval request
struct ExitPlanModeTool: ExecutableTool {
    static let name = "exit_plan_mode"

    static let description = """
        Exit plan mode and request user approval for the implementation plan.

        Use this tool when:
        - You have finished writing your plan to the plan file
        - You are ready for user review and approval

        Before using this tool:
        - Ensure your plan is complete and unambiguous
        - If you have unresolved questions, use AskUserQuestion first

        The user will see the plan contents and can approve or reject it.
        """

    // Note: allowedPrompts would ideally be an array of objects, but the schema
    // doesn't support nested items. Accept as JSON string for now.
    static let parametersSchema = OpenAI.Tool.FunctionSchema.Parameters(
        properties: [
            "allowedPromptsJson": .init(
                type: "string",
                description: "JSON array of allowed prompts: [{\"tool\":\"Bash\",\"prompt\":\"run tests\"}]"
            ),
            "pushToRemote": .init(
                type: "boolean",
                description: "Whether to push the plan to a remote session"
            )
        ],
        required: []
    )

    static func execute(parameters: [String: Any]) async throws -> String {
        return await MainActor.run {
            let manager = PlanModeManager.shared

            // Parse allowed prompts from JSON if provided
            var allowedPrompts: [AllowedPrompt] = []
            if let jsonString = parameters["allowedPromptsJson"] as? String,
               let data = jsonString.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([AllowedPrompt].self, from: data) {
                allowedPrompts = decoded
            }

            let result = manager.exitPlanMode(allowedPrompts: allowedPrompts)

            switch result {
            case .success(let request):
                return """
                Plan submitted for approval.

                Plan file: \(request.planFilePath)

                Waiting for user to review and approve the plan.
                The user will see the plan contents and can:
                - Approve: Implementation can proceed
                - Reject: Revision cycle begins
                """

            case .failure(let message):
                return "Error: \(message)"
            }
        }
    }
}
