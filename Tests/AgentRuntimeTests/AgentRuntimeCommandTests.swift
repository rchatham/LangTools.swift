//
//  AgentRuntimeCommandTests.swift
//  AgentRuntimeTests
//

import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import AgentRuntime
import AgentRuntimeProviders
@testable import OpenAI
@testable import TestUtils

final class AgentRuntimeCommandTests: XCTestCase {
    private var session: URLSession!
    private var files: [String: Data] = [:]
    private var output: [String] = []
    private var errors: [String] = []
    private var stdin = Data()

    private let specJSON = """
    {"name": "Helper", "instructions": "Answer.", "provider": "openai", "model": "gpt-4o",
     "messages": [{"role": "user", "content": "Ping"}]}
    """

    override func setUp() {
        super.setUp()
        _ = URLProtocol.registerClass(MockURLProtocol.self)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
        files = ["spec.json": Data(specJSON.utf8)]
        output = []
        errors = []
        stdin = Data()
    }

    override func tearDown() {
        MockURLProtocol.resetHandlers()
        URLProtocol.unregisterClass(MockURLProtocol.self)
        super.tearDown()
    }

    private func command(environment: [String: String] = ["OPENAI_API_KEY": "sk-test"]) -> AgentRuntimeCommand {
        AgentRuntimeCommand(
            providers: .builtIn,
            tools: .builtIn,
            environment: environment,
            session: session,
            readFile: { path in
                guard let data = self.files[path] else { throw CocoaError(.fileNoSuchFile) }
                return data
            },
            writeFile: { data, path in self.files[path] = data },
            standardInput: { self.stdin },
            standardOutput: { self.output.append($0) },
            standardError: { self.errors.append($0) }
        )
    }

    private func mockAnswer(_ content: String) {
        MockURLProtocol.setHandler(for: OpenAI.ChatCompletionRequest.endpoint) { _ in
            let body = """
            {"id":"x","object":"chat.completion","created":0,"model":"gpt-4o","choices":[{"index":0,"message":{"role":"assistant","content":"\(content)"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}
            """
            return (.success(Data(body.utf8)), 200)
        }
    }

    func testRunPrintsResultJSON() async throws {
        mockAnswer("Pong")
        let status = await command().run(["run", "spec.json"])
        XCTAssertEqual(status, 0, errors.joined(separator: "\n"))
        let result = try AgentRunResult.decode(from: Data(output.joined().utf8))
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.output, "Pong")
        XCTAssertTrue(errors.contains { $0.contains("[Helper] started") }, "Progress goes to stderr: \(errors)")
    }

    func testRunReadsSpecFromStandardInputAndWritesOutputFile() async throws {
        mockAnswer("Pong")
        stdin = Data(specJSON.utf8)
        let status = await command().run(["run", "-", "--output", "result.json", "--quiet"])
        XCTAssertEqual(status, 0, errors.joined(separator: "\n"))
        XCTAssertEqual(output, [])
        XCTAssertEqual(errors, [])
        XCTAssertEqual(try AgentRunResult.decode(from: XCTUnwrap(files["result.json"])).output, "Pong")
    }

    func testRunWithoutKeyIsUsageErrorAndStillPrintsResult() async throws {
        let status = await command(environment: [:]).run(["run", "spec.json"])
        XCTAssertEqual(status, 2)
        XCTAssertEqual(try AgentRunResult.decode(from: Data(output.joined().utf8)).status, .invalid)
        XCTAssertTrue(errors.contains { $0.contains("OPENAI_API_KEY") }, "\(errors)")
    }

    func testRunFailureExitsOne() async {
        MockURLProtocol.setHandler(for: OpenAI.ChatCompletionRequest.endpoint) { _ in (.failure(URLError(.notConnectedToInternet)), nil) }
        let status = await command().run(["run", "spec.json", "--quiet"])
        XCTAssertEqual(status, 1)
    }

    func testValidate() async {
        let ok = await command().run(["validate", "spec.json"])
        XCTAssertEqual(ok, 0)
        XCTAssertEqual(output, ["Helper: ok"])

        files["bad.json"] = Data(#"{"name": "x"}"#.utf8)
        let bad = await command().run(["validate", "bad.json"])
        XCTAssertEqual(bad, 2)
        let missing = await command().run(["validate", "missing.json"])
        XCTAssertEqual(missing, 2)
    }

    func testUsageErrors() async {
        let noCommand = await command().run([])
        XCTAssertEqual(noCommand, 2)
        let noOutputPath = await command().run(["run", "spec.json", "--output"])
        XCTAssertEqual(noOutputPath, 2)
        let twoSpecs = await command().run(["run", "a.json", "b.json"])
        XCTAssertEqual(twoSpecs, 2)
        let unknown = await command().run(["deploy"])
        XCTAssertEqual(unknown, 2)
    }

    func testListsProvidersAndTools() async {
        _ = await command().run(["providers"])
        XCTAssertTrue(output.contains("openai\tOpenAI\tOPENAI_API_KEY"), "\(output)")
        XCTAssertTrue(output.contains("ollama\tOllama\tOLLAMA_API_KEY (optional)"), "\(output)")
        output = []
        _ = await command().run(["tools"])
        XCTAssertEqual(output.map { $0.components(separatedBy: "\t")[0] }, ["current_time"])
    }

    // MARK: - Webhook

    private func webhookCommand(_ environment: [String: String]) -> AgentRuntimeCommand {
        var command = command(environment: environment)
        command.makeWebhookDelivery = { WebhookDelivery(configuration: $0, session: $1, sleep: { _ in }, now: Date.init) }
        return command
    }

    func testRunDeliversSignedResultToWebhook() async throws {
        mockAnswer("Pong")
        let log = RequestLog()
        MockURLProtocol.setHandler(for: "/hooks/agent") { request in log.append(request); return (.success(Data()), 200) }

        let status = await webhookCommand(["OPENAI_API_KEY": "sk-test", "LANGTOOLS_WEBHOOK_SECRET": "whsec"])
            .run(["run", "spec.json", "--webhook", "https://example.com/hooks/agent", "--run-id", "job-7", "--quiet"])

        XCTAssertEqual(status, 0, errors.joined(separator: "\n"))
        let request = try XCTUnwrap(log.requests.first)
        let body = try XCTUnwrap(request.bodyData ?? request.httpBody)
        let delivered = try AgentRunResult.decode(from: body)
        XCTAssertEqual(delivered.runID, "job-7")
        XCTAssertEqual(delivered.output, "Pong")
        XCTAssertTrue(WebhookSignature.verify(body: body, header: try XCTUnwrap(request.value(forHTTPHeaderField: WebhookSignature.header)), secret: "whsec"))
        XCTAssertEqual(try AgentRunResult.decode(from: Data(output.joined().utf8)).runID, "job-7", "stdout result carries the same run ID")
    }

    func testWebhookURLAndRunIDFromEnvironmentAndUnsignedWarning() async throws {
        mockAnswer("Pong")
        let log = RequestLog()
        MockURLProtocol.setHandler(for: "/hooks/env") { request in log.append(request); return (.success(Data()), 202) }

        let status = await webhookCommand(["OPENAI_API_KEY": "sk-test", "LANGTOOLS_WEBHOOK_URL": "https://example.com/hooks/env", "LANGTOOLS_RUN_ID": "env-run"])
            .run(["run", "spec.json"])

        XCTAssertEqual(status, 0)
        XCTAssertEqual(log.requests.first?.value(forHTTPHeaderField: WebhookDelivery.runIDHeader), "env-run")
        XCTAssertNil(log.requests.first?.value(forHTTPHeaderField: WebhookSignature.header))
        XCTAssertTrue(errors.contains { $0.contains("LANGTOOLS_WEBHOOK_SECRET is not set") }, "\(errors)")
    }

    func testRunGetsGeneratedRunIDWithoutWebhook() async throws {
        mockAnswer("Pong")
        _ = await command().run(["run", "spec.json", "--quiet"])
        XCTAssertNotNil(try AgentRunResult.decode(from: Data(output.joined().utf8)).runID)
    }

    func testFailedDeliveryExitsThree() async {
        mockAnswer("Pong")
        MockURLProtocol.setHandler(for: "/hooks/agent") { _ in (.success(Data()), 404) }
        let status = await webhookCommand(["OPENAI_API_KEY": "sk-test", "LANGTOOLS_WEBHOOK_SECRET": "s"])
            .run(["run", "spec.json", "--webhook", "https://example.com/hooks/agent", "--quiet"])
        XCTAssertEqual(status, 3)
        XCTAssertTrue(errors.contains { $0.contains("HTTP 404") }, "\(errors)")
        XCTAssertFalse(output.isEmpty, "The result is still printed")
    }

    func testInsecureWebhookFailsBeforeCallingProvider() async {
        var providerCalled = false
        MockURLProtocol.setHandler(for: OpenAI.ChatCompletionRequest.endpoint) { _ in providerCalled = true; return (.success(Data()), 500) }
        let status = await command().run(["run", "spec.json", "--webhook", "http://example.com/hook"])
        XCTAssertEqual(status, 2)
        XCTAssertFalse(providerCalled)
        let validate = await command().run(["validate", "spec.json", "--webhook", "http://example.com/hook"])
        XCTAssertEqual(validate, 2)
    }

    // MARK: - Spool commands

    private func temporarySpool() -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("cmd-spool-\(UUID().uuidString)").path
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    func testEnqueueThenStatus() async throws {
        let spoolPath = temporarySpool()
        let env = ["OPENAI_API_KEY": "sk-test", "LANGTOOLS_SPOOL_DIR": spoolPath]
        let queued = await command(environment: env).run(["enqueue", "spec.json", "--run-id", "cmd-1", "--webhook", "https://example.com/h", "--owner", "alice"])
        XCTAssertEqual(queued, 0, errors.joined(separator: "\n"))
        XCTAssertTrue(output.joined().contains("\"cmd-1\""))

        output = []
        let status = await command(environment: env).run(["status", "cmd-1"])
        XCTAssertEqual(status, 0)
        XCTAssertTrue(output.joined().contains("\"queued\""), output.joined())
        let queuedJob = try XCTUnwrap(AgentSpool(root: URL(fileURLWithPath: spoolPath)).claimNext()?.job)
        XCTAssertEqual(queuedJob.owner, "alice")
        XCTAssertEqual(queuedJob.webhookURL?.absoluteString, "https://example.com/h")

        let unknown = await command(environment: env).run(["status", "nope"])
        XCTAssertEqual(unknown, 1)
    }

    func testEnqueueValidatesAgainstWorkerEnvironment() async {
        let spoolPath = temporarySpool()
        let missingKey = await command(environment: [:]).run(["enqueue", "spec.json", "--spool", spoolPath])
        XCTAssertEqual(missingKey, 2)
        XCTAssertTrue(errors.contains { $0.contains("OPENAI_API_KEY") }, "\(errors)")
        let noSpool = await command().run(["enqueue", "spec.json"])
        XCTAssertEqual(noSpool, 2)
    }

    func testEnqueueWholeJobFromStandardInput() async throws {
        let spoolPath = temporarySpool()
        stdin = Data(#"{"runID": "from-stdin", "webhookURL": "https://example.com/h", "webhookSecret": "s", "spec": \#(specJSON)}"#.utf8)
        let status = await command().run(["enqueue", "--job", "--spool", spoolPath])
        XCTAssertEqual(status, 0, errors.joined(separator: "\n"))
        let job = try XCTUnwrap(AgentSpool(root: URL(fileURLWithPath: spoolPath)).claimNext()?.job)
        XCTAssertEqual(job.runID, "from-stdin")
        XCTAssertEqual(job.webhookSecret, "s")

        let mixed = await command().run(["enqueue", "--job", "--spool", spoolPath, "--run-id", "x"])
        XCTAssertEqual(mixed, 2)
    }
}
