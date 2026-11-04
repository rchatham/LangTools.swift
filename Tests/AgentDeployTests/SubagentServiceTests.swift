//
//  SubagentServiceTests.swift
//  AgentDeployTests
//

import XCTest
@testable import AgentDeploy
import AgentRuntime
import HelperLink

final class SubagentServiceTests: XCTestCase {
    private var runner: FakeRunner!
    private var temp: URL!
    private var service: SubagentService!

    private var catalogDirectory: URL { temp.appendingPathComponent("subagents", isDirectory: true) }

    override func setUpWithError() throws {
        runner = FakeRunner()
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("subagent-service-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: catalogDirectory, withIntermediateDirectories: true)
        let store = FleetStore(file: temp.appendingPathComponent("fleet.json"))
        try store.save(FleetRegistry(workers: [WorkerRecord(name: "helper", host: "local")]))
        service = SubagentService(catalog: SubagentCatalog(directory: catalogDirectory), fleet: AgentFleet(store: store, runner: runner))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: temp)
        super.tearDown()
    }

    private func define(_ file: String, _ json: String) throws {
        try Data(json.utf8).write(to: catalogDirectory.appendingPathComponent(file))
    }

    private let research = #"""
    {"toolName": "research", "worker": "helper", "timeoutSeconds": 120,
     "spec": {"name": "Researcher", "description": "Researches a question.", "instructions": "Cite sources.", "provider": "openai", "model": "gpt-4o"}}
    """#

    func testListsValidDefinitionsAndExplainsTheRest() throws {
        try define("b-research.json", research)
        try define("a-broken.json", "{not json")
        try define("c-missing.json", #"{"toolName": "x", "spec": {"name": "X", "instructions": "i", "provider": "openai", "model": "m"}}"#)
        try define("d-duplicate.json", research)
        try define("e-badname.json", research.replacingOccurrences(of: #""research""#, with: #""has space""#))
        try define("notes.txt", "ignored")
        try define(".hidden.json", research)

        let response = service.list()

        XCTAssertEqual(response.subagents, [HelperSubagent(toolName: "research", description: "Researches a question.", worker: "helper", timeoutSeconds: 120)])
        XCTAssertEqual(response.problems.count, 4, "\(response.problems)")
        XCTAssertTrue(response.problems[0].hasPrefix("a-broken.json: not valid JSON"), response.problems[0])
        XCTAssertEqual(response.problems[1], "c-missing.json: missing 'worker'.")
        XCTAssertEqual(response.problems[2], "d-duplicate.json: another file already defines 'research'.")
        XCTAssertTrue(response.problems[3].hasPrefix("e-badname.json:"), response.problems[3])
    }

    func testMissingDirectoryIsEmpty() {
        let empty = SubagentCatalog(directory: temp.appendingPathComponent("nowhere")).load()
        XCTAssertTrue(empty.subagents.isEmpty)
        XCTAssertTrue(empty.problems.isEmpty)
    }

    func testStartSubmitsTaskThenStatusReportsResult() async throws {
        try define("research.json", research)

        let started = try await service.start(HelperSubagentRunRequest(toolName: "research", task: "Who wrote Dune?", context: "For a quiz."))
        let enqueue = try XCTUnwrap(runner.calls.last { $0.command.contains("enqueue --job") })
        let job = try AgentJob.decode(from: XCTUnwrap(enqueue.stdin))
        XCTAssertEqual(job.runID, started.runID)
        XCTAssertEqual(job.spec.messages, [.init(role: .user, content: "Who wrote Dune?\n\nContext:\nFor a quiz.")])

        runner.on("langtools-agent status", stdout: #"{"runID":"\#(started.runID)","state":"running"}"#)
        let running = try await service.status(HelperSubagentStatusRequest(toolName: "research", runID: started.runID))
        XCTAssertEqual(running, HelperSubagentStatusResponse(runID: started.runID, state: .running))

        runner.on("langtools-agent status", stdout: #"""
        {"runID":"\#(started.runID)","state":"done","result":{"runID":"\#(started.runID)","agent":"Researcher","provider":"openai","model":"gpt-4o","status":"completed","output":"Frank Herbert.","events":[],"startedAt":"2026-11-04T00:00:00Z","finishedAt":"2026-11-04T00:00:03Z"}}
        """#)
        let done = try await service.status(HelperSubagentStatusRequest(toolName: "research", runID: started.runID))
        XCTAssertEqual(done, HelperSubagentStatusResponse(runID: started.runID, state: .done, output: "Frank Herbert."))
    }

    func testFailedRunIsReportedAsText() async throws {
        try define("research.json", research)
        runner.on("langtools-agent status", stdout: #"""
        {"runID":"r1","state":"done","result":{"runID":"r1","agent":"Researcher","provider":"openai","model":"gpt-4o","status":"failed","error":"OPENAI_API_KEY is not set.","events":[],"startedAt":"2026-11-04T00:00:00Z","finishedAt":"2026-11-04T00:00:01Z"}}
        """#)
        let status = try await service.status(HelperSubagentStatusRequest(toolName: "research", runID: "r1"))
        XCTAssertEqual(status.output, "The Researcher agent failed: OPENAI_API_KEY is not set.")
    }

    func testRejectsUnknownSubagentEmptyTaskAndUnknownRun() async throws {
        try define("research.json", research)
        do {
            _ = try await service.start(HelperSubagentRunRequest(toolName: "nope", task: "x"))
            XCTFail("Unknown subagent should be rejected")
        } catch let error as DeployError {
            XCTAssertTrue(error.localizedDescription.contains("No subagent named 'nope'"), error.localizedDescription)
        }
        do {
            _ = try await service.start(HelperSubagentRunRequest(toolName: "research", task: "  "))
            XCTFail("Empty task should be rejected")
        } catch let error as DeployError {
            XCTAssertEqual(error.localizedDescription, DeployError.invalidArgument("A task is required.").localizedDescription)
        }
        XCTAssertFalse(runner.shellCommands.contains { $0.contains("enqueue") })

        runner.on("langtools-agent status", status: 1, stdout: #"{"runID":"gone","state":"unknown"}"#)
        do {
            _ = try await service.status(HelperSubagentStatusRequest(toolName: "research", runID: "gone"))
            XCTFail("Unknown run should be rejected")
        } catch let error as DeployError {
            XCTAssertTrue(error.localizedDescription.contains("has no run 'gone'"), error.localizedDescription)
        }
    }

    func testDefinitionEditsTakeEffectWithoutRestart() throws {
        XCTAssertEqual(service.list().subagents, [])
        try define("research.json", research)
        XCTAssertEqual(service.list().subagents.map(\.toolName), ["research"])
    }

    func testShippedExampleIsValid() throws {
        let examples = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Examples/Subagents").standardized
        let loaded = SubagentCatalog(directory: examples).load()
        XCTAssertEqual(loaded.problems, [])
        XCTAssertEqual(loaded.subagents.map(\.toolName), ["worker_clock"])
    }

    func testSearchPathAddsMissingDirectoriesOnly() {
        XCTAssertEqual(ProcessCommandRunner.searchPath("/usr/bin:/bin", adding: ["/opt/homebrew/bin", "/usr/bin"]), "/usr/bin:/bin:/opt/homebrew/bin")
        XCTAssertEqual(ProcessCommandRunner.searchPath(nil, adding: ["/usr/local/bin"]), "/usr/local/bin")
        XCTAssertEqual(ProcessCommandRunner.commonToolDirectories(home: "/Users/r")[2], "/Users/r/.docker/bin")
    }

    func testRunnerUsesExtraSearchPaths() async throws {
        let directory = temp.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tool = directory.appendingPathComponent("only-here")
        try Data("#!/bin/sh\necho found\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        let missing = try await ProcessCommandRunner().run("only-here", [], stdin: nil)
        XCTAssertEqual(missing.status, 127)
        let found = try await ProcessCommandRunner(extraSearchPaths: [directory.path]).run("only-here", [], stdin: nil)
        XCTAssertEqual(found.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines), "found")
    }
}
