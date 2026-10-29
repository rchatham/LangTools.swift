import Foundation
import LangTools

/// Thread-safe per-send budget limiting how many tool callbacks may execute.
/// Claims happen before invocation so over-limit calls never run.
final class ToolIterationBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = 0

    /// Nil means unlimited.
    let maxIterations: Int?

    init(maxIterations: Int?) {
        self.maxIterations = maxIterations
    }

    /// Claims one iteration. Returns `false` when the budget is exhausted,
    /// in which case the caller must not execute the underlying callback.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let maxIterations else { return true }
        guard claimed < maxIterations else { return false }
        claimed += 1
        return true
    }
}

/// Wraps tool callbacks so they only execute within `budget`. Over-limit calls
/// throw `LangToolsRequestError.toolIterationLimitReached`; the tool-calling
/// loop converts that into an error result the model can see and respond to.
/// Tools without callbacks are passed through unchanged.
///
/// This covers every tool handed to the chat request, including agent-trigger
/// tools (an agent run counts as one iteration). Tool calls made inside a
/// nested agent's own request are not budgeted here.
func budgetedTools(_ tools: [Tool]?, budget: ToolIterationBudget) -> [Tool]? {
    guard let tools else { return nil }
    guard budget.maxIterations != nil else { return tools }
    return tools.map { tool in
        guard let callback = tool.callback else { return tool }
        return Tool(name: tool.name, description: tool.description, tool_schema: tool.tool_schema) { info, args in
            guard budget.claim() else {
                throw LangToolsRequestError.toolIterationLimitReached
            }
            return try await callback(info, args)
        }
    }
}