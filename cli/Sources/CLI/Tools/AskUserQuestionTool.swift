//
//  AskUserQuestionTool.swift
//  CLI
//
//  Tool for asking clarifying questions to the user
//

import Foundation
import OpenAI

/// A question option
struct QuestionOption: Codable {
    let label: String
    let description: String
}

/// A question to ask the user
struct UserQuestion: Codable {
    let question: String
    let header: String
    let options: [QuestionOption]
    let multiSelect: Bool
}

/// Manages pending user questions
@MainActor
final class UserQuestionManager: ObservableObject {
    /// Shared singleton instance
    static let shared = UserQuestionManager()

    /// Pending questions
    @Published private(set) var pendingQuestions: [UserQuestion] = []

    /// Currently displayed question
    @Published private(set) var currentQuestion: UserQuestion?

    /// Response continuation for async waiting
    private var responseContinuation: CheckedContinuation<String, Never>?

    private init() {}

    /// Set questions and wait for response
    func askQuestions(_ questions: [UserQuestion]) async -> String {
        pendingQuestions = questions
        currentQuestion = questions.first

        return await withCheckedContinuation { continuation in
            responseContinuation = continuation
        }
    }

    /// User selects an answer
    func selectAnswer(_ answer: String) {
        responseContinuation?.resume(returning: answer)
        responseContinuation = nil
        currentQuestion = nil
        pendingQuestions.removeAll()
    }

    /// User provides custom input
    func provideCustomAnswer(_ answer: String) {
        selectAnswer(answer)
    }

    /// Cancel current question
    func cancel() {
        responseContinuation?.resume(returning: "[Cancelled]")
        responseContinuation = nil
        currentQuestion = nil
        pendingQuestions.removeAll()
    }
}

/// Tool for asking the user questions
struct AskUserQuestionTool: ExecutableTool {
    static let name = "ask_user_question"

    static let description = """
        Ask the user questions to gather preferences, clarify ambiguous instructions,
        or get decisions on implementation choices.

        Use this tool when:
        - You need to gather user preferences
        - Instructions are ambiguous
        - Multiple valid approaches exist
        - User input would improve the solution

        The user will see the question and can select from options or provide custom input.
        """

    static let parametersSchema = OpenAI.Tool.FunctionSchema.Parameters(
        properties: [
            "questionsJson": .init(
                type: "string",
                description: """
                    JSON array of questions:
                    [{
                      "question": "Which library should we use?",
                      "header": "Library",
                      "multiSelect": false,
                      "options": [
                        {"label": "Option A (Recommended)", "description": "Description of A"},
                        {"label": "Option B", "description": "Description of B"}
                      ]
                    }]
                    - question: The full question to ask
                    - header: Short label (max 12 chars)
                    - multiSelect: Allow multiple selections
                    - options: 2-4 choices (user can always provide custom input)
                    """
            )
        ],
        required: ["questionsJson"]
    )

    static func execute(parameters: [String: Any]) async throws -> String {
        guard let jsonString = ToolRegistry.extractString(parameters, key: "questionsJson"),
              let data = jsonString.data(using: .utf8) else {
            throw ToolError.missingRequiredParameter(tool: name, parameter: "questionsJson")
        }

        do {
            let questions = try JSONDecoder().decode([UserQuestion].self, from: data)

            guard !questions.isEmpty else {
                throw ToolError.invalidParameters(tool: name, reason: "At least one question is required")
            }

            var responses: [String] = []

            for question in questions {
                print("\n\("Question: ".blue)\(question.question)")
                if !question.options.isEmpty {
                    for (i, option) in question.options.enumerated() {
                        print("  \(i + 1). \(option.label) — \(option.description)")
                    }
                    if question.multiSelect {
                        print("  (Enter numbers separated by commas, or type a custom answer)")
                    } else {
                        print("  (Enter a number, or type a custom answer)")
                    }
                }
                print("Your answer: ".green, terminator: "")
                fflush(stdout)

                let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if input.isEmpty {
                    responses.append("[No answer provided]")
                } else if !question.options.isEmpty {
                    // Resolve numeric selections to option labels
                    let parts = input.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    let resolved = parts.map { part -> String in
                        if let idx = Int(part), idx >= 1, idx <= question.options.count {
                            return question.options[idx - 1].label
                        }
                        return part
                    }
                    responses.append(resolved.joined(separator: ", "))
                } else {
                    responses.append(input)
                }
            }

            let combined = zip(questions, responses)
                .map { q, r in "\(q.header): \(r)" }
                .joined(separator: "\n")

            return "User answers:\n\(combined)"
        } catch let error as ToolError {
            throw error
        } catch {
            throw ToolError.invalidParameters(tool: name, reason: "Invalid JSON: \(error.localizedDescription)")
        }
    }
}
