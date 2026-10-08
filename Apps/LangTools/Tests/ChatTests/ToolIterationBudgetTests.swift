import XCTest
import LangTools
import Ollama
@testable import Chat

final class ToolIterationBudgetTests: XCTestCase {

    private enum DummyModel: String, RawRepresentable {
        case test
    }

    private func makeInfo() -> LangToolsRequestInfo {
        LangToolsRequestInfo(
            langTool: Ollama(),
            model: DummyModel.test,
            messages: []
        )
    }

    // MARK: - Claim semantics

    func testUnlimitedBudgetAlwaysClaims() {
        let budget = ToolIterationBudget(maxIterations: nil)
        for _ in 0..<10 { XCTAssertTrue(budget.claim()) }
    }

    func testBudgetClaimsOnlyUpToMaxIterations() {
        let budget = ToolIterationBudget(maxIterations: 2)
        XCTAssertTrue(budget.claim())
        XCTAssertTrue(budget.claim())
        XCTAssertFalse(budget.claim())
        XCTAssertFalse(budget.claim())
    }

    // MARK: - Wrapped tools

    func testBudgetedToolsPassThroughWhenUnlimited() async throws {
        let budget = ToolIterationBudget(maxIterations: nil)
        let tool = Tool(name: "counter", description: nil, tool_schema: ToolSchema()) { _, _ in "ok" }
        let wrapped = try XCTUnwrap(budgetedTools([tool], budget: budget)?.first)

        let result = try await wrapped.callback?(makeInfo(), [:])
        XCTAssertEqual(result, "ok")
    }

    func testOverLimitToolDoesNotExecuteAndReportsLimitError() async throws {
        let budget = ToolIterationBudget(maxIterations: 1)
        let info = makeInfo()
        var executions = 0
        let tool = Tool(name: "counter", description: nil, tool_schema: ToolSchema()) { _, _ in
            executions += 1
            return "ok"
        }
        let wrapped = try XCTUnwrap(budgetedTools([tool], budget: budget)?.first)

        let first = try await wrapped.callback?(info, [:])
        XCTAssertEqual(first, "ok")
        XCTAssertEqual(executions, 1)

        do {
            _ = try await wrapped.callback?(info, [:])
            XCTFail("Second call should be rejected by the budget")
        } catch let error as LangToolsRequestError {
            XCTAssertEqual(error.localizedDescription, "Tool iteration limit reached.")
        }
        XCTAssertEqual(executions, 1, "Over-limit callbacks must not execute")
    }

    func testBudgetedToolsReturnNilForNilInput() {
        XCTAssertNil(budgetedTools(nil, budget: ToolIterationBudget(maxIterations: 1)))
    }
}