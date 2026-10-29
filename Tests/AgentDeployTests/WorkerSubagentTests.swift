//
//  WorkerSubagentTests.swift
//  AgentDeployTests
//

import XCTest
@testable import AgentDeploy
import AgentRuntime
import LangTools
import OpenAI
import JSON

final class WorkerSubagentTests: XCTestCase {
    private var runner: FakeRunner!
    private var temp: URL!
    private var fleet: AgentFleet!

    private let spec = AgentSpec(
        name: "Researcher", description: "Researches a question and answers with sources.",
        instructions: "Answer with sources.", provider: LangToolsProviderID(rawValue: "openai"), model: "gpt-4o",
        messages: [.init(role: .system, content: "Be brief.")]
    )

    override func setUpWithError() throws {
        runner = FakeRunner()
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("subagent-\(UUID().uuidString)", isDirectory: true)
        let store = FleetStore(file: temp.appendingPathComponent("fleet.json"))
        try store.save(FleetRegistry(workers: [WorkerRecord(name: "helper", host: "local"), WorkerRecord(name: "alice", host: "local", owner: "alice")]))
        fleet = AgentFleet(store: store, runner: runner)
        fleet.sleep = { _ in }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: temp)
        super.tearDown()
    }

    /// Answers `status` for whatever job was last enqueued, as the worker would once it's done.
    private func respond(status: String, output: String? = nil, error: String? = nil, pollsBeforeDone: Int = 0) {
        var polls = 0
        runner.on({ $0.command.contains("langtools-agent status") }) { call in
            let runID = String(call.command.split(separator: "'").last ?? "")
            polls += 1
            guard polls > pollsBeforeDone else { return CommandOutput(status: 0, stdout: Data(#"{"runID":"\#(runID)","state":"running"}"#.utf8)) }
            var result: [String: Any] = ["runID": runID, "agent": "Researcher", "provider": "openai", "model": "gpt-4o", "status": status, "events": [],
                                         "startedAt": "2026-10-29T00:00:00Z", "finishedAt": "2026-10-29T00:00:05Z"]
            result["output"] = output
            result["error"] = error
            let body = try! JSONSerialization.data(withJSONObject: ["runID": runID, "state": "done", "result": result])
            return CommandOutput(status: 0, stdout: body)
        }
    }

    private var enqueuedJob: AgentJob? {
        runner.calls.last { $0.command.contains("enqueue --job") }.flatMap { $0.stdin }.flatMap { try? AgentJob.decode(from: $0) }
    }

    func testToolRunsTaskOnWorkerAndReturnsOutput() async throws {
        respond(status: "completed", output: "Paris has 2.1 million people [1].", pollsBeforeDone: 2)
        let subagent = try WorkerSubagent(toolName: "research", spec: spec, worker: "helper")
        let tool = subagent.tool(fleet: fleet)

        XCTAssertEqual(tool.name, "research")
        XCTAssertEqual(tool.description, "Researches a question and answers with sources.")
        XCTAssertEqual(tool.tool_schema.required, ["task"])
        XCTAssertEqual(Set(tool.tool_schema.properties.keys), ["task", "context"])

        let info = LangToolsRequestInfo(langTool: OpenAI(apiKey: "k"), model: OpenAI.Model.gpt4o, messages: [])
        let output = try await tool.callback?(info, ["task": JSON.string("Population of Paris?"), "context": JSON.string("For a travel guide.")])
        XCTAssertEqual(output, "Paris has 2.1 million people [1].")

        let job = try XCTUnwrap(enqueuedJob)
        XCTAssertEqual(job.spec.messages, [
            .init(role: .system, content: "Be brief."),
            .init(role: .user, content: "Population of Paris?\n\nContext:\nFor a travel guide."),
        ])
        XCTAssertEqual(job.spec.model, "gpt-4o", "The calling model can't change the subagent")
        XCTAssertNil(job.owner)
        XCTAssertEqual(runner.calls.filter { $0.command.contains("langtools-agent status") }.count, 3)
    }

    func testFailuresComeBackAsTextForTheModel() async throws {
        let subagent = try WorkerSubagent(toolName: "research", spec: spec, worker: "helper")

        respond(status: "failed", error: "OPENAI_API_KEY is not set.")
        let failed = try await subagent.run(task: "x", on: fleet)
        XCTAssertEqual(failed, "The Researcher agent failed: OPENAI_API_KEY is not set.")

        runner.on("langtools-agent status", stdout: #"{"runID":"r","state":"queued"}"#)
        var slow = subagent
        slow.timeout = 0.000_001
        let timedOut = try await slow.run(task: "x", on: fleet)
        XCTAssertTrue(timedOut.hasPrefix("The Researcher agent did not finish in time (run "), timedOut)
        XCTAssertTrue(timedOut.contains("on worker 'helper'"))

        let missing = try await WorkerSubagent(toolName: "research", spec: spec, worker: "nowhere").run(task: "x", on: fleet)
        XCTAssertTrue(missing.hasPrefix("The Researcher agent could not be started:"), missing)

        let info = LangToolsRequestInfo(langTool: OpenAI(apiKey: "k"), model: OpenAI.Model.gpt4o, messages: [])
        let empty = try await subagent.tool(fleet: fleet).callback?(info, ["task": JSON.string("  ")])
        XCTAssertEqual(empty, "A task is required.")
    }

    func testIsolatedWorkerGetsItsOwner() async throws {
        respond(status: "completed", output: "done")
        let refused = try await WorkerSubagent(toolName: "a", spec: spec, worker: "alice").run(task: "x", on: fleet)
        XCTAssertTrue(refused.contains("isolated for owner 'alice'"), refused)

        let output = try await WorkerSubagent(toolName: "a", spec: spec, worker: "alice", owner: "alice").run(task: "x", on: fleet)
        XCTAssertEqual(output, "done")
        XCTAssertEqual(enqueuedJob?.owner, "alice")
    }

    func testCancellationPropagates() async throws {
        runner.on("langtools-agent status", stdout: #"{"runID":"r","state":"running"}"#)
        fleet.sleep = { _ in throw CancellationError() }
        let subagent = try WorkerSubagent(toolName: "research", spec: spec, worker: "helper")
        do {
            _ = try await subagent.run(task: "x", on: fleet)
            XCTFail("Should be cancelled")
        } catch is CancellationError {}
    }

    func testRejectsBadConfiguration() {
        XCTAssertThrowsError(try WorkerSubagent(toolName: "has space", spec: spec, worker: "helper"))
        XCTAssertThrowsError(try WorkerSubagent(toolName: String(repeating: "a", count: 65), spec: spec, worker: "helper"))
        XCTAssertThrowsError(try WorkerSubagent(toolName: "ok", spec: spec, worker: "Bad_Worker"))
        XCTAssertThrowsError(try WorkerSubagent(toolName: "ok", spec: spec, worker: "helper", owner: "a:b"))
        XCTAssertThrowsError(try WorkerSubagent(toolName: "ok", spec: spec, worker: "helper", timeout: 0))
    }
}
