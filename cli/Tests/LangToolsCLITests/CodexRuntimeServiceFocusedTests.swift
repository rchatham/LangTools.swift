import Foundation
import XCTest
@testable import LangToolsCLI

final class CodexRuntimeServiceFocusedTests: XCTestCase {
    func testLoginFiltersCompletionByExactIDAndRejectsConcurrentLogin() async throws {
        let scriptURL = try makePythonScript(Self.loginFilteringServer)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let opened = expectation(description: "browser opened")
        let client = makeClient(scriptURL: scriptURL)
        let runtime = CodexRuntimeService(
            client: client,
            browserOpener: { url in
                XCTAssertEqual(url.absoluteString, "https://auth.example.test/login")
                opened.fulfill()
            },
            loginCompletionTimeout: .seconds(1)
        )

        let firstLogin = Task { try await runtime.login() }
        await fulfillment(of: [opened], timeout: 1)

        do {
            _ = try await runtime.login()
            XCTFail("Expected concurrent login to be rejected")
        } catch let error as CodexRuntimeError {
            guard case .accountConflict(let message) = error else {
                return XCTFail("Expected account conflict, got \(error)")
            }
            XCTAssertEqual(message, "A ChatGPT login is already in progress.")
        }

        let session = try await firstLogin.value
        XCTAssertEqual(session.accountIdentifier, "person@example.com")
        XCTAssertEqual(session.accessibleModelIDs, [])
        await runtime.shutdown()
    }

    func testFailedLoginNotificationCancelsExactLogin() async throws {
        let markerURL = temporaryURL(suffix: ".marker")
        let scriptURL = try makePythonScript(Self.failedLoginServer)
        defer {
            try? FileManager.default.removeItem(at: markerURL)
            try? FileManager.default.removeItem(at: scriptURL)
        }

        let client = makeClient(scriptURL: scriptURL, environment: ["MARKER": markerURL.path])
        let runtime = CodexRuntimeService(
            client: client,
            browserOpener: { _ in },
            loginCompletionTimeout: .seconds(1)
        )

        do {
            _ = try await runtime.login()
            XCTFail("Expected authentication failure")
        } catch let error as CodexRuntimeError {
            guard case .authentication(let message) = error else {
                return XCTFail("Expected authentication error, got \(error)")
            }
            XCTAssertEqual(message, "denied by user")
        }
        XCTAssertEqual(try String(contentsOf: markerURL, encoding: .utf8), "failed-login")
        await runtime.shutdown()
    }

    func testLoginTimeoutCancelsExactLogin() async throws {
        let markerURL = temporaryURL(suffix: ".marker")
        let scriptURL = try makePythonScript(Self.loginTimeoutServer)
        defer {
            try? FileManager.default.removeItem(at: markerURL)
            try? FileManager.default.removeItem(at: scriptURL)
        }

        let client = makeClient(scriptURL: scriptURL, environment: ["MARKER": markerURL.path])
        let runtime = CodexRuntimeService(
            client: client,
            browserOpener: { _ in },
            loginCompletionTimeout: .milliseconds(50)
        )

        do {
            _ = try await runtime.login()
            XCTFail("Expected login completion timeout")
        } catch let error as CodexAppServerError {
            guard case .timeout(let method) = error else {
                return XCTFail("Expected timeout, got \(error)")
            }
            XCTAssertEqual(method, "account/login/completed")
        }
        XCTAssertEqual(try String(contentsOf: markerURL, encoding: .utf8), "timed-out-login")
        await runtime.shutdown()
    }

    func testModelPaginationRejectsCursorCycle() async throws {
        let scriptURL = try makePythonScript(Self.cursorCycleServer)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let client = makeClient(scriptURL: scriptURL)
        let runtime = CodexRuntimeService(client: client, browserOpener: { _ in })

        do {
            _ = try await runtime.modelSlugs()
            XCTFail("Expected repeated cursor rejection")
        } catch let error as CodexRuntimeError {
            guard case .invalidResponse(let message) = error else {
                return XCTFail("Expected invalid response, got \(error)")
            }
            XCTAssertEqual(message, "Codex model pagination repeated a cursor.")
        }
        await runtime.shutdown()
    }

    func testFailedTurnMapsCodexErrorInfoAndInterruptsExactTurn() async throws {
        struct Scenario {
            let name: String
            let info: String
            let expected: (CodexRuntimeError) -> Bool
        }
        let scenarios = [
            Scenario(name: "bad-request", info: #""badRequest""#, expected: {
                if case .badRequest("turn failed") = $0 { return true }
                return false
            }),
            Scenario(name: "unauthorized", info: #"{"httpConnectionFailed":{"httpStatusCode":401}}"#, expected: {
                if case .authentication("turn failed") = $0 { return true }
                return false
            }),
            Scenario(name: "timeout", info: #"{"responseStreamConnectionFailed":{"httpStatusCode":504}}"#, expected: {
                if case .timeout("turn failed") = $0 { return true }
                return false
            }),
            Scenario(name: "runtime", info: #""unknownFailure""#, expected: {
                if case .runtime("turn failed") = $0 { return true }
                return false
            })
        ]

        for scenario in scenarios {
            let markerURL = temporaryURL(suffix: ".marker")
            let script = Self.failedTurnServer.replacingOccurrences(of: "__CODEX_ERROR_INFO__", with: scenario.info)
            let scriptURL = try makePythonScript(script)
            defer {
                try? FileManager.default.removeItem(at: markerURL)
                try? FileManager.default.removeItem(at: scriptURL)
            }
            let client = makeClient(scriptURL: scriptURL, environment: ["MARKER": markerURL.path])
            let runtime = CodexRuntimeService(
                client: client,
                browserOpener: { _ in },
                turnCompletionTimeout: .seconds(1)
            )

            do {
                _ = try await runtime.chat(model: "codex-test", messages: [.init(role: "user", content: "Hello")])
                XCTFail("Expected \(scenario.name) turn failure")
            } catch let error as CodexRuntimeError {
                XCTAssertTrue(scenario.expected(error), "Unexpected \(scenario.name) mapping: \(error)")
            }
            XCTAssertEqual(try String(contentsOf: markerURL, encoding: .utf8), "thread-exact/turn-exact")
            await runtime.shutdown()
        }
    }

    func testTurnTimeoutInterruptsExactTurn() async throws {
        let markerURL = temporaryURL(suffix: ".marker")
        let scriptURL = try makePythonScript(Self.turnTimeoutServer)
        defer {
            try? FileManager.default.removeItem(at: markerURL)
            try? FileManager.default.removeItem(at: scriptURL)
        }

        let client = makeClient(scriptURL: scriptURL, environment: ["MARKER": markerURL.path])
        let runtime = CodexRuntimeService(
            client: client,
            browserOpener: { _ in },
            turnCompletionTimeout: .milliseconds(50)
        )

        do {
            _ = try await runtime.chat(model: "codex-test", messages: [.init(role: "user", content: "Hello")])
            XCTFail("Expected turn timeout")
        } catch let error as CodexAppServerError {
            guard case .timeout = error else { return XCTFail("Expected timeout, got \(error)") }
        }
        XCTAssertEqual(try String(contentsOf: markerURL, encoding: .utf8), "thread-timeout/turn-timeout")
        await runtime.shutdown()
    }

    func testCancellationDuringDelayedTurnStartStillInterruptsReturnedTurn() async throws {
        let turnStartedURL = temporaryURL(suffix: ".started")
        let interruptedURL = temporaryURL(suffix: ".interrupted")
        let scriptURL = try makePythonScript(Self.delayedTurnStartServer)
        defer {
            try? FileManager.default.removeItem(at: turnStartedURL)
            try? FileManager.default.removeItem(at: interruptedURL)
            try? FileManager.default.removeItem(at: scriptURL)
        }

        let client = makeClient(
            scriptURL: scriptURL,
            environment: ["TURN_STARTED": turnStartedURL.path, "INTERRUPTED": interruptedURL.path]
        )
        let runtime = CodexRuntimeService(
            client: client,
            browserOpener: { _ in },
            turnCompletionTimeout: .seconds(1)
        )
        let chat = Task {
            try await runtime.chat(model: "codex-test", messages: [.init(role: "user", content: "Hello")])
        }

        try await waitForFile(at: turnStartedURL)
        chat.cancel()
        do {
            _ = try await chat.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertEqual(try String(contentsOf: interruptedURL, encoding: .utf8), "thread-delayed/turn-delayed")
        await runtime.shutdown()
    }

    func testAuthURLAllowsHTTPSAndOnlyLoopbackHTTP() {
        XCTAssertTrue(CodexRuntimeService.isAllowedAuthURL(URL(string: "https://example.com/login")!))
        XCTAssertTrue(CodexRuntimeService.isAllowedAuthURL(URL(string: "http://localhost:8080/login")!))
        XCTAssertTrue(CodexRuntimeService.isAllowedAuthURL(URL(string: "http://127.0.0.1/login")!))
        XCTAssertTrue(CodexRuntimeService.isAllowedAuthURL(URL(string: "http://127.0.0.2/login")!))
        XCTAssertTrue(CodexRuntimeService.isAllowedAuthURL(URL(string: "http://[::1]/login")!))
        XCTAssertTrue(CodexRuntimeService.isAllowedAuthURL(URL(string: "http://[0:0:0:0:0:0:0:1]/login")!))

        XCTAssertFalse(CodexRuntimeService.isAllowedAuthURL(URL(string: "http://example.com/login")!))
        XCTAssertFalse(CodexRuntimeService.isAllowedAuthURL(URL(string: "ftp://localhost/login")!))
        XCTAssertFalse(CodexRuntimeService.isAllowedAuthURL(URL(string: "https:///missing-host")!))
    }

    private func makeClient(scriptURL: URL, environment: [String: String] = [:]) -> CodexAppServerClient {
        CodexAppServerClient(
            commandResolver: {
                ResolvedCodexCommand(executable: "/usr/bin/python3", arguments: ["-u", scriptURL.path])
            },
            environment: ProcessInfo.processInfo.environment.merging(environment) { _, override in override },
            defaultTimeout: .seconds(1)
        )
    }

    private func makePythonScript(_ source: String) throws -> URL {
        let url = temporaryURL(suffix: ".py")
        try Data(source.utf8).write(to: url)
        return url
    }

    private func temporaryURL(suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("langtools-focused-test-\(UUID().uuidString)\(suffix)")
    }

    private func waitForFile(at url: URL) async throws {
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: url.path) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for fake server marker at \(url.path)")
    }

    private static let preamble = #"""
import json
import os
import sys
import time

def read():
    line = sys.stdin.readline()
    if not line:
        raise SystemExit(90)
    return json.loads(line)

def write(value):
    print(json.dumps(value, separators=(",", ":")), flush=True)

initialize = read()
assert initialize["method"] == "initialize"
write({"id":initialize["id"], "result":{"userAgent":"fake", "codexHome":"/tmp", "platformFamily":"unix", "platformOs":"macos"}})
assert read() == {"method":"initialized"}
"""# + "\n"

    private static let loginFilteringServer = preamble + #"""
request = read()
assert request["method"] == "account/read"
write({"id":request["id"], "result":{"account":None, "requiresOpenaiAuth":True}})
request = read()
assert request["method"] == "account/login/start"
assert request["params"] == {"type":"chatgpt", "codexStreamlinedLogin":True}
write({"method":"account/login/completed", "params":{"loginId":"login-other", "success":False, "error":"must be ignored"}})
write({"method":"account/login/completed", "params":{"loginId":"login-exact", "success":True, "error":None}})
write({"id":request["id"], "result":{"type":"chatgpt", "loginId":"login-exact", "authUrl":"https://auth.example.test/login"}})
request = read()
assert request["method"] == "account/read"
assert request["params"] == {"refreshToken":True}
write({"id":request["id"], "result":{"account":{"type":"chatgpt", "email":"person@example.com", "planType":"plus"}, "requiresOpenaiAuth":False}})
request = read()
assert request["method"] == "model/list"
write({"id":request["id"], "result":{"data":[], "nextCursor":None}})
"""#

    private static let failedLoginServer = preamble + #"""
request = read()
write({"id":request["id"], "result":{"account":None, "requiresOpenaiAuth":True}})
request = read()
write({"id":request["id"], "result":{"type":"chatgpt", "loginId":"failed-login", "authUrl":"http://127.0.0.1/callback"}})
write({"method":"account/login/completed", "params":{"loginId":"failed-login", "success":False, "error":"denied by user"}})
request = read()
assert request["method"] == "account/login/cancel"
assert request["params"] == {"loginId":"failed-login"}
open(os.environ["MARKER"], "w").write("failed-login")
write({"id":request["id"], "result":{"status":"canceled"}})
"""#

    private static let loginTimeoutServer = preamble + #"""
request = read()
write({"id":request["id"], "result":{"account":None, "requiresOpenaiAuth":True}})
request = read()
write({"id":request["id"], "result":{"type":"chatgpt", "loginId":"timed-out-login", "authUrl":"http://localhost/callback"}})
request = read()
assert request["method"] == "account/login/cancel"
assert request["params"] == {"loginId":"timed-out-login"}
open(os.environ["MARKER"], "w").write("timed-out-login")
write({"id":request["id"], "result":{"status":"canceled"}})
"""#

    private static let cursorCycleServer = preamble + #"""
request = read()
assert request["method"] == "model/list"
assert request["params"] == {"limit":100, "includeHidden":False}
write({"id":request["id"], "result":{"data":[], "nextCursor":"cycle"}})
request = read()
assert request["method"] == "model/list"
assert request["params"] == {"cursor":"cycle", "limit":100, "includeHidden":False}
write({"id":request["id"], "result":{"data":[], "nextCursor":" cycle "}})
"""#

    private static let failedTurnServer = preamble + #"""
request = read()
assert request["method"] == "thread/start"
write({"id":request["id"], "result":{"thread":{"id":"thread-exact"}, "model":"codex-test", "modelProvider":"openai"}})
request = read()
assert request["method"] == "turn/start"
assert request["params"]["threadId"] == "thread-exact"
write({"id":request["id"], "result":{"turn":{"id":"turn-exact"}}})
write({"method":"turn/completed", "params":{"threadId":"thread-exact", "turn":{"id":"turn-exact", "status":"failed", "error":{"message":"turn failed", "additionalDetails":None, "codexErrorInfo":__CODEX_ERROR_INFO__}}}})
request = read()
assert request["method"] == "turn/interrupt"
assert request["params"] == {"threadId":"thread-exact", "turnId":"turn-exact"}
open(os.environ["MARKER"], "w").write("thread-exact/turn-exact")
write({"id":request["id"], "result":{}})
"""#

    private static let turnTimeoutServer = preamble + #"""
request = read()
assert request["method"] == "thread/start"
write({"id":request["id"], "result":{"thread":{"id":"thread-timeout"}, "model":"codex-test", "modelProvider":"openai"}})
request = read()
assert request["method"] == "turn/start"
write({"id":request["id"], "result":{"turn":{"id":"turn-timeout"}}})
request = read()
assert request["method"] == "turn/interrupt"
assert request["params"] == {"threadId":"thread-timeout", "turnId":"turn-timeout"}
open(os.environ["MARKER"], "w").write("thread-timeout/turn-timeout")
write({"id":request["id"], "result":{}})
"""#

    private static let delayedTurnStartServer = preamble + #"""
request = read()
assert request["method"] == "thread/start"
write({"id":request["id"], "result":{"thread":{"id":"thread-delayed"}, "model":"codex-test", "modelProvider":"openai"}})
request = read()
assert request["method"] == "turn/start"
open(os.environ["TURN_STARTED"], "w").write("started")
time.sleep(0.15)
write({"id":request["id"], "result":{"turn":{"id":"turn-delayed"}}})
request = read()
assert request["method"] == "turn/interrupt"
assert request["params"] == {"threadId":"thread-delayed", "turnId":"turn-delayed"}
open(os.environ["INTERRUPTED"], "w").write("thread-delayed/turn-delayed")
write({"id":request["id"], "result":{}})
"""#
}
