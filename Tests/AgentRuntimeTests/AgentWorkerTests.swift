//
//  AgentWorkerTests.swift
//  AgentRuntimeTests
//

import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import AgentRuntime
import AgentRuntimeProviders
@testable import LangTools
@testable import OpenAI
@testable import TestUtils

final class AgentWorkerTests: XCTestCase {
    private var session: URLSession!
    private var root: URL!
    private var spool: AgentSpool!
    private let openAI = LangToolsProviderID(rawValue: "openai")

    override func setUp() {
        super.setUp()
        _ = URLProtocol.registerClass(MockURLProtocol.self)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("spool-\(UUID().uuidString)", isDirectory: true)
        spool = AgentSpool(root: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        MockURLProtocol.resetHandlers()
        URLProtocol.unregisterClass(MockURLProtocol.self)
        super.tearDown()
    }

    private func job(_ runID: String, submittedAt: Date = Date(), webhook: String? = nil) -> AgentJob {
        AgentJob(runID: runID, spec: AgentSpec(name: "Helper", instructions: "Answer.", provider: openAI, model: "gpt-4o", messages: [.user("Ping")]),
                 webhookURL: webhook.flatMap(URL.init(string:)), submittedAt: submittedAt)
    }

    private func answer(_ content: String, times: Int = 1) {
        guard times > 0 else { return }
        MockURLProtocol.setHandler(for: OpenAI.ChatCompletionRequest.endpoint) { _ in
            self.answer(content, times: times - 1)
            let body = #"{"id":"x","object":"chat.completion","created":0,"model":"gpt-4o","choices":[{"index":0,"message":{"role":"assistant","content":"\#(content)"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}"#
            return (.success(Data(body.utf8)), 200)
        }
    }

    private func worker(maxAttempts: Int = 2, logs: CallLog = CallLog()) -> AgentWorker {
        let runner = AgentRunner(providers: .builtIn, credentials: .keys([openAI: "sk-test"]), session: session)
        let worker = AgentWorker(spool: spool, runner: runner, options: .init(concurrency: 1, pollInterval: 0.02, maxAttempts: maxAttempts, webhookSecret: "worker-secret"), session: session, log: logs.append)
        worker.makeWebhookDelivery = { WebhookDelivery(configuration: $0, session: self.session, sleep: { _ in }, now: Date.init) }
        return worker
    }

    /// Runs the worker until `condition` holds, then stops it.
    private func runWorker(_ worker: AgentWorker, until condition: @escaping () -> Bool) async throws {
        let task = Task { try await worker.run() }
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        worker.stop()
        try await task.value
        XCTAssertTrue(condition(), "Timed out waiting for the worker")
    }

    // MARK: - Spool

    func testEnqueueClaimsOldestFirstAndTracksState() throws {
        try spool.enqueue(job("second", submittedAt: Date(timeIntervalSince1970: 2)))
        try spool.enqueue(job("first", submittedAt: Date(timeIntervalSince1970: 1)))
        XCTAssertEqual(spool.state(of: "first"), .queued)

        let claimed = try XCTUnwrap(spool.claimNext())
        XCTAssertEqual(claimed.job.runID, "first")
        XCTAssertEqual(claimed.job.attempts, 1)
        XCTAssertEqual(spool.state(of: "first"), .running)

        let now = Date()
        try spool.complete(claimed.file, result: AgentRunResult(runID: "first", agent: "Helper", provider: "openai", model: "gpt-4o", status: .completed, output: "ok", startedAt: now, finishedAt: now))
        XCTAssertEqual(spool.state(of: "first"), .done)
        XCTAssertEqual(try spool.result(for: "first")?.output, "ok")
        XCTAssertEqual(try spool.claimNext()?.job.runID, "second")
        XCTAssertNil(try spool.claimNext())
        XCTAssertEqual(spool.state(of: "missing"), .unknown)
    }

    func testRunIDThatEndsAnotherIsSeparate() throws {
        try spool.enqueue(job("research-1"))
        XCTAssertEqual(spool.state(of: "1"), .unknown)
        XCTAssertEqual(spool.state(of: "-1"), .unknown)
        XCTAssertNoThrow(try spool.enqueue(job("1")), "Not a duplicate of research-1")
        XCTAssertEqual(spool.state(of: "1"), .queued)

        _ = try XCTUnwrap(spool.claimNext())
        XCTAssertEqual(Set(["research-1", "1"].map { spool.state(of: $0) }), [.running, .queued])
        XCTAssertEqual(spool.state(of: "search-1"), .unknown)
        XCTAssertEqual(AgentSpool.runID(fromFileName: "0000000000001-a-b.json"), "a-b")
        XCTAssertNil(AgentSpool.runID(fromFileName: "0000000000001-.json"))
    }

    func testJobFilesAreOwnerOnly() throws {
        var secretJob = job("secret")
        secretJob.webhookSecret = "whsec"
        try spool.enqueue(secretJob)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("queue"), includingPropertiesForKeys: nil).first)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testRejectsDuplicateAndUnsafeRunIDs() throws {
        try spool.enqueue(job("job-1"))
        XCTAssertThrowsError(try spool.enqueue(job("job-1")))
        for bad in ["", "../escape", ".hidden", "has space", "slash/inside", String(repeating: "a", count: 129), "ünïcode"] {
            XCTAssertThrowsError(try spool.enqueue(job(bad)), "'\(bad)' should be rejected")
        }
        XCTAssertEqual(spool.state(of: "../escape"), .unknown)
    }

    func testRejectsInsecureWebhookAtEnqueue() {
        XCTAssertThrowsError(try spool.enqueue(job("j", webhook: "http://example.com/hook")))
    }

    func testTwoSpoolsOnOneDirectoryNeverClaimTheSameJob() throws {
        try spool.enqueue(job("a", submittedAt: Date(timeIntervalSince1970: 1)))
        try spool.enqueue(job("b", submittedAt: Date(timeIntervalSince1970: 2)))
        let other = AgentSpool(root: root)
        let first = try XCTUnwrap(spool.claimNext())
        let second = try XCTUnwrap(other.claimNext())
        XCTAssertEqual([first.job.runID, second.job.runID], ["a", "b"])
        XCTAssertNil(try spool.claimNext())
    }

    func testUnreadableJobIsSetAside() throws {
        try spool.prepare()
        try Data("not json".utf8).write(to: root.appendingPathComponent("queue/0000000000001-broken.json"))
        try spool.enqueue(job("good"))
        XCTAssertEqual(try spool.claimNext()?.job.runID, "good")
        XCTAssertNil(try spool.claimNext())
    }

    func testPruneDeletesOldResults() throws {
        try spool.prepare()
        let now = Date()
        try spool.write(AgentRunResult(runID: "old", agent: "a", provider: "openai", model: "m", status: .completed, startedAt: now, finishedAt: now))
        try spool.pruneResults(olderThan: 60, now: now.addingTimeInterval(30))
        XCTAssertEqual(spool.state(of: "old"), .done)
        try spool.pruneResults(olderThan: 60, now: now.addingTimeInterval(120))
        XCTAssertEqual(spool.state(of: "old"), .unknown)
    }

    // MARK: - Worker

    func testWorkerRunsJobsAndDeliversSignedResults() async throws {
        answer("Pong", times: 2)
        let deliveries = RequestLog()
        func hook(_ remaining: Int) {
            MockURLProtocol.setHandler(for: "/hooks/w") { request in
                deliveries.append(request)
                if remaining > 1 { hook(remaining - 1) }
                return (.success(Data()), 200)
            }
        }
        hook(2)
        try spool.enqueue(job("w-1", submittedAt: Date(timeIntervalSince1970: 1), webhook: "https://example.com/hooks/w"))
        var own = job("w-2", submittedAt: Date(timeIntervalSince1970: 2), webhook: "https://example.com/hooks/w")
        own.webhookSecret = "job-secret"
        try spool.enqueue(own)

        try await runWorker(worker()) { deliveries.requests.count == 2 }

        XCTAssertEqual(try spool.result(for: "w-1")?.output, "Pong")
        XCTAssertEqual(try spool.result(for: "w-2")?.runID, "w-2")
        for (request, secret) in zip(deliveries.requests, ["worker-secret", "job-secret"]) {
            let body = try XCTUnwrap(request.bodyData ?? request.httpBody)
            XCTAssertTrue(WebhookSignature.verify(body: body, header: try XCTUnwrap(request.value(forHTTPHeaderField: WebhookSignature.header)), secret: secret))
        }
    }

    func testInterruptedJobIsRequeuedOnce() async throws {
        try spool.enqueue(job("crash"))
        _ = try spool.claimNext()  // A worker claimed it, then died.
        answer("Recovered")

        try await runWorker(worker()) { self.spool.state(of: "crash") == .done }
        XCTAssertEqual(try spool.result(for: "crash")?.status, .completed)
        XCTAssertEqual(try spool.result(for: "crash")?.output, "Recovered")
    }

    func testJobInterruptedTooOftenIsReportedFailed() async throws {
        let delivered = RequestLog()
        MockURLProtocol.setHandler(for: "/hooks/fail") { request in delivered.append(request); return (.success(Data()), 200) }
        try spool.enqueue(job("crash", webhook: "https://example.com/hooks/fail"))
        _ = try spool.claimNext()  // attempt 1, interrupted
        let logs = CallLog()

        try await runWorker(worker(maxAttempts: 1, logs: logs)) { delivered.requests.count == 1 }

        let result = try XCTUnwrap(spool.result(for: "crash"))
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.error?.contains("stopped during the run") ?? false)
        XCTAssertEqual(spool.state(of: "crash"), .done)
        XCTAssertTrue(logs.values.contains { $0.contains("run=crash failed: interrupted") }, "\(logs.values)")
    }

    func testFailedRunStillProducesResult() async throws {
        MockURLProtocol.setHandler(for: OpenAI.ChatCompletionRequest.endpoint) { _ in (.failure(URLError(.notConnectedToInternet)), nil) }
        try spool.enqueue(job("net"))
        try await runWorker(worker()) { self.spool.state(of: "net") == .done }
        XCTAssertEqual(try spool.result(for: "net")?.status, .failed)
    }
}
