//
//  AskUserQuestionTool.swift
//  CLI
//
//  Tool for asking clarifying questions to the user
//

import Foundation
import OpenAI
#if os(macOS)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A question option
struct QuestionOption: Codable, Sendable {
    let label: String
    let description: String
}

/// A question to ask the user
struct UserQuestion: Codable, Sendable {
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

    private struct QueuedQuestion {
        let question: UserQuestion
        let continuation: CheckedContinuation<String, Never>
    }

    private var queuedQuestions: [QueuedQuestion] = []

    private init() {}

    /// Set questions and wait for response.
    func askQuestions(_ questions: [UserQuestion]) async -> String {
        guard let firstQuestion = questions.first else {
            return "[No answer provided]"
        }

        return await withCheckedContinuation { continuation in
            if currentQuestion == nil {
                currentQuestion = firstQuestion
                responseContinuation = continuation
            } else {
                queuedQuestions.append(QueuedQuestion(
                    question: firstQuestion,
                    continuation: continuation
                ))
            }
            pendingQuestions = [currentQuestion].compactMap { $0 }
                + queuedQuestions.map(\.question)
        }
    }

    /// User selects an answer.
    func selectAnswer(_ answer: String) {
        resolveCurrentQuestion(with: answer)
    }

    /// User provides custom input
    func provideCustomAnswer(_ answer: String) {
        selectAnswer(answer)
    }

    /// Cancel all pending questions.
    func cancel() {
        responseContinuation?.resume(returning: "[Cancelled]")
        queuedQuestions.forEach { $0.continuation.resume(returning: "[Cancelled]") }
        responseContinuation = nil
        queuedQuestions.removeAll()
        currentQuestion = nil
        pendingQuestions.removeAll()
    }

    private func resolveCurrentQuestion(with answer: String) {
        responseContinuation?.resume(returning: answer)

        if queuedQuestions.isEmpty {
            responseContinuation = nil
            currentQuestion = nil
            pendingQuestions.removeAll()
            return
        }

        let next = queuedQuestions.removeFirst()
        currentQuestion = next.question
        responseContinuation = next.continuation
        pendingQuestions = [next.question] + queuedQuestions.map(\.question)
    }
}

/// Routes questions to SwiftTUI when its handler is installed. Without that
/// handler, the tool retains its standard terminal-input fallback.
actor UserQuestionRouter {
    typealias TUIHandler = @Sendable (UserQuestion) async -> String

    static let shared = UserQuestionRouter()

    private var tuiHandler: TUIHandler?

    func installTUIHandler(_ handler: @escaping TUIHandler) {
        tuiHandler = handler
    }

    func removeTUIHandler() {
        tuiHandler = nil
    }

    func request(_ question: UserQuestion) async -> String? {
        guard let tuiHandler else { return nil }
        return await tuiHandler(question)
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
            return try await collectAnswers(for: questions)
        } catch let error as ToolError {
            throw error
        } catch {
            throw ToolError.invalidParameters(tool: name, reason: "Invalid JSON: \(error.localizedDescription)")
        }
    }

    static func collectAnswers(
        for questions: [UserQuestion],
        isInteractive: Bool = isInteractiveSession(),
        lineReader: @escaping () -> String? = { readLine() }
    ) async throws -> String {
        guard !questions.isEmpty else {
            throw ToolError.invalidParameters(tool: name, reason: "At least one question is required")
        }

        var responses: [String] = []
        for question in questions {
            let input: String
            if let tuiInput = await UserQuestionRouter.shared.request(question) {
                // SwiftTUI owns stdin while this handler is installed. Waiting
                // on its manager is the only input path in TUI mode.
                input = tuiInput
            } else {
                try validateInteractiveInput(isInteractive: isInteractive)
                printTerminalQuestion(question)
                input = lineReader() ?? ""
            }
            responses.append(resolvedAnswer(input, for: question))
        }

        let combined = zip(questions, responses)
            .map { question, response in "\(question.header): \(response)" }
            .joined(separator: "\n")
        return "User answers:\n\(combined)"
    }

    static func resolvedAnswer(_ input: String, for question: UserQuestion) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "[No answer provided]" }
        guard !question.options.isEmpty else { return trimmed }

        let parts = trimmed.components(separatedBy: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        return parts.map { part in
            guard let index = Int(part), index >= 1,
                  question.options.indices.contains(index - 1) else { return part }
            return question.options[index - 1].label
        }.joined(separator: ", ")
    }

    private static func printTerminalQuestion(_ question: UserQuestion) {
        print("\n\("Question: ".blue)\(question.question)")
        if !question.options.isEmpty {
            for (index, option) in question.options.enumerated() {
                print("  \(index + 1). \(option.label) — \(option.description)")
            }
            if question.multiSelect {
                print("  (Enter numbers separated by commas, or type a custom answer)")
            } else {
                print("  (Enter a number, or type a custom answer)")
            }
        }
        print("Your answer: ".green, terminator: "")
        fflush(stdout)
    }

    static func validateInteractiveInput(isInteractive: Bool) throws {
        guard isInteractive else {
            throw ToolError.executionFailed(
                tool: name,
                reason: "This tool requires an interactive terminal. Ask a direct question instead when running non-interactively."
            )
        }
    }

    static func isInteractiveSession() -> Bool {
        isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0
    }
}
