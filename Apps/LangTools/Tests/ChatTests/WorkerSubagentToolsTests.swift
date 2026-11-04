import XCTest
@testable import Chat
import HelperLink
import ToolKit

@MainActor
final class WorkerSubagentToolsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var toolManager: ToolManager!

    override func setUp() async throws {
        suiteName = "WorkerSubagentToolsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        toolManager = ToolManager(defaults: defaults)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private let research = HelperSubagent(toolName: "research", description: "Researches a question.", worker: "helper", timeoutSeconds: 60)

    func testRefreshRegistersSubagentsAsEnabledTools() async throws {
        let client = MockSubagentClient(list: HelperSubagentsResponse(subagents: [research], problems: ["broken.json: not valid JSON."]))
        let tools = WorkerSubagentTools(client: client, toolManager: toolManager, sleep: { _ in })

        await tools.refresh()

        let config = try XCTUnwrap(toolManager.configuration(for: "research"))
        XCTAssertEqual(config.description, "Researches a question.")
        XCTAssertFalse(config.isAgent, "Runs through the tool path, not the in-app agent path")
        XCTAssertTrue(toolManager.isToolEnabled(id: "research"))
        XCTAssertEqual(config.toTool().tool_schema.required, ["task"])
        XCTAssertEqual(tools.subagents, [research])
        XCTAssertEqual(tools.problems, ["broken.json: not valid JSON."])

        // Refreshing again keeps the same tool rather than reporting a name clash.
        await tools.refresh()
        XCTAssertEqual(tools.subagents, [research])
    }

    func testRemovedSubagentIsUnregistered() async {
        let client = MockSubagentClient(list: HelperSubagentsResponse(subagents: [research]))
        let tools = WorkerSubagentTools(client: client, toolManager: toolManager, sleep: { _ in })
        await tools.refresh()
        XCTAssertNotNil(toolManager.configuration(for: "research"))

        client.list = HelperSubagentsResponse(subagents: [])
        await tools.refresh()
        XCTAssertNil(toolManager.configuration(for: "research"))
        XCTAssertEqual(tools.subagents, [])

        // The name is free again for another tool.
        toolManager.register(ToolConfiguration(id: "research", displayName: "Research", description: "In-app agent", iconName: "magnifyingglass", isAgent: true))
        client.list = HelperSubagentsResponse(subagents: [research])
        await tools.refresh()
        XCTAssertEqual(toolManager.configuration(for: "research")?.description, "In-app agent")
    }

    func testToolThatTakesASubagentsNameKeepsIt() async {
        let client = MockSubagentClient(list: HelperSubagentsResponse(subagents: [research]))
        let tools = WorkerSubagentTools(client: client, toolManager: toolManager, sleep: { _ in })
        await tools.refresh()

        // Another tool registers under the same name after the subagent did.
        toolManager.register(ToolConfiguration(id: "research", displayName: "Research", description: "In-app agent", iconName: "magnifyingglass", isAgent: true))
        await tools.refresh()

        XCTAssertEqual(toolManager.configuration(for: "research")?.description, "In-app agent", "The subagent must not take the name back")
        XCTAssertTrue(tools.problems.contains { $0.contains("already the name of another tool") }, "\(tools.problems)")

        // And dropping the subagent later doesn't remove the other tool.
        client.list = HelperSubagentsResponse(subagents: [])
        await tools.refresh()
        XCTAssertEqual(toolManager.configuration(for: "research")?.description, "In-app agent")
    }

    func testDuplicateNamesFromHelperUseTheFirst() async {
        let other = HelperSubagent(toolName: "research", description: "Second", worker: "other", timeoutSeconds: 60)
        let tools = WorkerSubagentTools(client: MockSubagentClient(list: HelperSubagentsResponse(subagents: [research, other])), toolManager: toolManager, sleep: { _ in })
        await tools.refresh()
        XCTAssertEqual(tools.subagents, [research])
        XCTAssertEqual(toolManager.configuration(for: "research")?.description, "Researches a question.")
        XCTAssertTrue(tools.problems.contains { $0.contains("more than once") }, "\(tools.problems)")
    }

    func testSubagentCantTakeAnExistingToolsName() async {
        toolManager.register(ToolConfiguration(id: "research", displayName: "Research", description: "In-app agent", iconName: "magnifyingglass", isAgent: true))
        let tools = WorkerSubagentTools(client: MockSubagentClient(list: HelperSubagentsResponse(subagents: [research])), toolManager: toolManager, sleep: { _ in })

        await tools.refresh()

        XCTAssertEqual(toolManager.configuration(for: "research")?.description, "In-app agent")
        XCTAssertEqual(tools.subagents, [])
        XCTAssertTrue(tools.problems.first?.contains("already the name of another tool") ?? false, "\(tools.problems)")
    }

    func testRefreshWithoutHelperReportsWhy() async {
        let client = MockSubagentClient(listError: HelperSubagentClientError.notPaired)
        let tools = WorkerSubagentTools(client: client, toolManager: toolManager, sleep: { _ in })
        await tools.refresh()
        XCTAssertEqual(tools.problems, [HelperSubagentClientError.notPaired.localizedDescription])
        XCTAssertNil(toolManager.configuration(for: "research"))
    }

    func testRunStartsThenPollsUntilDone() async throws {
        let client = MockSubagentClient(statuses: [.init(runID: "r1", state: .queued), .init(runID: "r1", state: .running), .init(runID: "r1", state: .done, output: "Frank Herbert.")])
        let output = try await WorkerSubagentTools.run(research, task: "Who wrote Dune?", context: "Quiz", client: client, pollInterval: 0, sleep: { _ in })
        XCTAssertEqual(output, "Frank Herbert.")
        XCTAssertEqual(client.started, [HelperSubagentRunRequest(toolName: "research", task: "Who wrote Dune?", context: "Quiz")])
        XCTAssertEqual(client.polls, 3)
    }

    func testFailuresComeBackAsText() async throws {
        let notStarted = try await WorkerSubagentTools.run(research, task: "x", context: nil, client: MockSubagentClient(startError: HelperSubagentClientError.helper(status: 400, message: "No subagent named 'research'.")), pollInterval: 0, sleep: { _ in })
        XCTAssertTrue(notStarted.hasPrefix("The research subagent could not be started:"), notStarted)

        let quick = HelperSubagent(toolName: "research", description: "", worker: "helper", timeoutSeconds: 0)
        let timedOut = try await WorkerSubagentTools.run(quick, task: "x", context: nil, client: MockSubagentClient(statuses: [.init(runID: "r1", state: .running)]), pollInterval: 0, sleep: { _ in })
        XCTAssertTrue(timedOut.contains("did not finish") && timedOut.contains("run r1"), timedOut)

        let tools = WorkerSubagentTools(client: MockSubagentClient(), toolManager: toolManager, sleep: { _ in })
        let missingTask = try await tools.configuration(for: research).callback?([:])
        XCTAssertEqual(missingTask, "A task is required.")
    }

    func testCancellationWhileStartingPropagates() async {
        do {
            _ = try await WorkerSubagentTools.run(research, task: "x", context: nil, client: MockSubagentClient(startError: CancellationError()), pollInterval: 0, sleep: { _ in })
            XCTFail("Should be cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testCancellationStopsWaiting() async {
        let client = MockSubagentClient(statuses: [.init(runID: "r1", state: .running)])
        do {
            _ = try await WorkerSubagentTools.run(research, task: "x", context: nil, client: client, pollInterval: 0, sleep: { _ in throw CancellationError() })
            XCTFail("Should be cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}

private final class MockSubagentClient: HelperSubagentClientProtocol, @unchecked Sendable {
    var list: HelperSubagentsResponse
    private let listError: Error?
    private let startError: Error?
    private var statuses: [HelperSubagentStatusResponse]
    private(set) var started: [HelperSubagentRunRequest] = []
    private(set) var polls = 0

    init(list: HelperSubagentsResponse = HelperSubagentsResponse(subagents: []), listError: Error? = nil, startError: Error? = nil, statuses: [HelperSubagentStatusResponse] = []) {
        self.list = list
        self.listError = listError
        self.startError = startError
        self.statuses = statuses
    }

    func listSubagents() async throws -> HelperSubagentsResponse {
        if let listError { throw listError }
        return list
    }

    func startSubagent(_ request: HelperSubagentRunRequest) async throws -> HelperSubagentRunResponse {
        if let startError { throw startError }
        started.append(request)
        return HelperSubagentRunResponse(runID: "r1")
    }

    func subagentStatus(_ request: HelperSubagentStatusRequest) async throws -> HelperSubagentStatusResponse {
        polls += 1
        // Repeats the last status once the script runs out.
        return statuses.count > 1 ? statuses.removeFirst() : statuses[0]
    }
}
