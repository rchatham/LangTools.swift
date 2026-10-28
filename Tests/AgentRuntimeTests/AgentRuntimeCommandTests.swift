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
}
