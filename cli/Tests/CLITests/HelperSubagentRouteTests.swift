import XCTest
@testable import HelperCore
import AgentDeploy
import AgentRuntime
import HelperLink

final class HelperSubagentRouteTests: XCTestCase {
    private var temp: URL!
    private var runner: ScriptedRunner!
    private var service: SubagentService!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("helper-subagents-\(UUID().uuidString)", isDirectory: true)
        let catalog = temp.appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: true)
        try Data(#"""
        {"toolName": "research", "description": "Researches a question.", "worker": "helper",
         "spec": {"name": "Researcher", "instructions": "Cite sources.", "provider": "openai", "model": "gpt-4o"}}
        """#.utf8).write(to: catalog.appendingPathComponent("research.json"))
        let store = FleetStore(file: temp.appendingPathComponent("fleet.json"))
        try store.save(FleetRegistry(workers: [WorkerRecord(name: "helper", host: "local")]))
        runner = ScriptedRunner()
        service = SubagentService(catalog: SubagentCatalog(directory: catalog), fleet: AgentFleet(store: store, runner: runner))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: temp)
        super.tearDown()
    }

    private func decode<T: Decodable>(_ type: T.Type, _ body: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(body.utf8))
    }

    func testRoutesAreRegisteredWithMethods() {
        XCTAssertNil(LocalHelperServer.routeErrorStatus(method: "GET", path: "/v1/subagents"))
        XCTAssertEqual(LocalHelperServer.routeErrorStatus(method: "POST", path: "/v1/subagents"), .methodNotAllowed)
        XCTAssertNil(LocalHelperServer.routeErrorStatus(method: "POST", path: "/v1/subagents/runs"))
        XCTAssertNil(LocalHelperServer.routeErrorStatus(method: "POST", path: "/v1/subagents/status"))
        XCTAssertEqual(LocalHelperServer.routeErrorStatus(method: "GET", path: "/v1/subagents/status"), .methodNotAllowed)
    }

    func testOtherPathsAreLeftToTheServer() async {
        let response = await HelperSubagentRoutes.respond(path: "/health", body: Data(), service: service)
        XCTAssertNil(response)
    }

    func testWithoutServiceSubagentsAreNotFound() async throws {
        let responseResult = await HelperSubagentRoutes.respond(path: HelperSubagentRoute.list, body: Data(), service: nil)
        let response = try XCTUnwrap(responseResult)
        XCTAssertEqual(response.status, .notFound)
    }

    func testListRunAndStatus() async throws {
        let listResult = await HelperSubagentRoutes.respond(path: HelperSubagentRoute.list, body: Data(), service: service)
        let list = try XCTUnwrap(listResult)
        XCTAssertEqual(list.status, .ok)
        XCTAssertEqual(try decode(HelperSubagentsResponse.self, list.body).subagents.map(\.toolName), ["research"])

        let runBody = try JSONEncoder().encode(HelperSubagentRunRequest(toolName: "research", task: "Who wrote Dune?"))
        let runResult = await HelperSubagentRoutes.respond(path: HelperSubagentRoute.run, body: runBody, service: service)
        let run = try XCTUnwrap(runResult)
        XCTAssertEqual(run.status, .ok, run.body)
        let runID = try decode(HelperSubagentRunResponse.self, run.body).runID
        XCTAssertTrue(runner.commands.contains { $0.contains("enqueue --job") })

        runner.statusOutput = #"""
        {"runID":"\#(runID)","state":"done","result":{"runID":"\#(runID)","agent":"Researcher","provider":"openai","model":"gpt-4o","status":"completed","output":"Frank Herbert.","events":[],"startedAt":"2026-11-04T00:00:00Z","finishedAt":"2026-11-04T00:00:03Z"}}
        """#
        let statusBody = try JSONEncoder().encode(HelperSubagentStatusRequest(toolName: "research", runID: runID))
        let statusResult = await HelperSubagentRoutes.respond(path: HelperSubagentRoute.status, body: statusBody, service: service)
        let status = try XCTUnwrap(statusResult)
        XCTAssertEqual(status.status, .ok, status.body)
        XCTAssertEqual(try decode(HelperSubagentStatusResponse.self, status.body), HelperSubagentStatusResponse(runID: runID, state: .done, output: "Frank Herbert."))
    }

    func testBadRequestsGetClearErrors() async throws {
        let unknown = try JSONEncoder().encode(HelperSubagentRunRequest(toolName: "nope", task: "x"))
        let responseResult = await HelperSubagentRoutes.respond(path: HelperSubagentRoute.run, body: unknown, service: service)
        let response = try XCTUnwrap(responseResult)
        XCTAssertEqual(response.status, .badRequest)
        XCTAssertTrue(response.body.contains("No subagent named 'nope'"), response.body)

        let garbageResult = await HelperSubagentRoutes.respond(path: HelperSubagentRoute.run, body: Data("{".utf8), service: service)
        let garbage = try XCTUnwrap(garbageResult)
        XCTAssertEqual(garbage.status, .badRequest)
        XCTAssertTrue(garbage.body.contains("Invalid subagent request."), garbage.body)
    }
}

/// Answers the worker commands the fleet runs: Docker checks succeed, `status` prints `statusOutput`.
private final class ScriptedRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _commands: [String] = []
    private var _statusOutput = #"{"runID":"r","state":"queued"}"#

    var commands: [String] { lock.lock(); defer { lock.unlock() }; return _commands }
    var statusOutput: String {
        get { lock.lock(); defer { lock.unlock() }; return _statusOutput }
        set { lock.lock(); _statusOutput = newValue; lock.unlock() }
    }

    func run(_ executable: String, _ arguments: [String], stdin: Data?) async throws -> CommandOutput {
        let command = arguments.last ?? ""
        record(command)
        if command.contains("langtools-agent status") { return CommandOutput(status: 0, stdout: Data(statusOutput.utf8)) }
        return CommandOutput(status: 0)
    }

    private func record(_ command: String) {
        lock.lock(); _commands.append(command); lock.unlock()
    }
}
