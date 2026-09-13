import Foundation
import XCTest
@testable import LangToolsCLI

final class CodexAppServerClientTests: XCTestCase {
    private struct RequestParams: Codable { let value: String }
    private struct Response: Codable { let value: String }

    func testLaunchInitializationCorrelationEnvironmentAndServerRequestDecline() async throws {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("langtools-app-server-test-\(UUID().uuidString).py")
        try Data(Self.fakeServer.utf8).write(to: scriptURL)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let client = CodexAppServerClient(
            commandResolver: {
                ResolvedCodexCommand(executable: "/usr/bin/python3", arguments: ["-u", scriptURL.path])
            },
            environment: ["LANGTOOLS_CODEX_HOME": "/tmp/langtools-test-codex-home"],
            defaultTimeout: .seconds(5)
        )

        async let first: Response = client.request(method: "test/first", params: RequestParams(value: "one"))
        async let second: Response = client.request(method: "test/second", params: RequestParams(value: "two"))
        let values = try await [first.value, second.value]
        XCTAssertEqual(Set(values), Set(["test/first", "test/second"]))
        await client.shutdown()
    }

    func testSplitAndCombinedNDJSONChunksPreserveResponseAndNotificationOrder() async throws {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("langtools-app-server-chunks-\(UUID().uuidString).py")
        try Data(Self.chunkedServer.utf8).write(to: scriptURL)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let client = CodexAppServerClient(
            commandResolver: {
                ResolvedCodexCommand(executable: "/usr/bin/python3", arguments: ["-u", scriptURL.path])
            },
            defaultTimeout: .seconds(2)
        )

        let subscription = await client.subscribeToNotifications(methods: ["chunk/event"])
        let first: Response = try await client.request(method: "chunk/first", params: RequestParams(value: "one"))
        XCTAssertEqual(first.value, "first-response")

        let firstNotification = try await client.nextNotification(from: subscription, timeout: .seconds(1))
        let secondNotification = try await client.nextNotification(from: subscription, timeout: .seconds(1))
        XCTAssertEqual(try JSONDecoder().decode(Response.self, from: firstNotification.params).value, "first-event")
        XCTAssertEqual(try JSONDecoder().decode(Response.self, from: secondNotification.params).value, "second-event")

        let second: Response = try await client.request(method: "chunk/second", params: RequestParams(value: "two"))
        XCTAssertEqual(second.value, "second-response")
        await client.cancelNotificationSubscription(subscription)
        await client.shutdown()
    }

    func testProcessExitIsReportedAndNextRequestRestartsServer() async throws {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("langtools-app-server-restart-\(UUID().uuidString).py")
        let countURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("langtools-app-server-count-\(UUID().uuidString)")
        try Data(Self.restartingServer.utf8).write(to: scriptURL)
        defer {
            try? FileManager.default.removeItem(at: scriptURL)
            try? FileManager.default.removeItem(at: countURL)
        }

        let client = CodexAppServerClient(
            commandResolver: {
                ResolvedCodexCommand(executable: "/usr/bin/python3", arguments: ["-u", scriptURL.path])
            },
            environment: ["COUNT_FILE": countURL.path],
            defaultTimeout: .seconds(2)
        )

        do {
            let _: Response = try await client.request(method: "process/exit", params: RequestParams(value: "one"))
            XCTFail("Expected process exit")
        } catch let error as CodexAppServerError {
            guard case .exited(let status, _) = error else {
                return XCTFail("Expected exited error, got \(error)")
            }
            XCTAssertEqual(status, 7)
        }

        let restarted: Response = try await client.request(method: "process/restarted", params: RequestParams(value: "two"))
        XCTAssertEqual(restarted.value, "process/restarted")
        XCTAssertEqual(try String(contentsOf: countURL, encoding: .utf8), "2")
        await client.shutdown()
    }

    private static let chunkedServer = #"""
import json
import os
import sys
import time

def read():
    return json.loads(sys.stdin.readline())

def chunks(*values):
    data = "".join(json.dumps(value, separators=(",", ":")) + "\n" for value in values).encode()
    os.write(sys.stdout.fileno(), data[:7])
    time.sleep(0.01)
    os.write(sys.stdout.fileno(), data[7:])

initialize = read()
chunks({"id":initialize["id"], "result":{"userAgent":"fake", "codexHome":"/tmp", "platformFamily":"unix", "platformOs":"macos"}})
assert read()["method"] == "initialized"

request = read()
assert request["method"] == "chunk/first"
chunks(
    {"id":request["id"], "result":{"value":"first-response"}},
    {"method":"chunk/event", "params":{"value":"first-event"}},
    {"method":"chunk/event", "params":{"value":"second-event"}}
)
request = read()
assert request["method"] == "chunk/second"
chunks({"id":request["id"], "result":{"value":"second-response"}})
"""#

    private static let restartingServer = #"""
import json
import os
import sys

count_file = os.environ["COUNT_FILE"]
try:
    count = int(open(count_file).read()) + 1
except FileNotFoundError:
    count = 1
open(count_file, "w").write(str(count))

def read():
    return json.loads(sys.stdin.readline())

def write(value):
    print(json.dumps(value), flush=True)

initialize = read()
write({"id":initialize["id"], "result":{"userAgent":"fake", "codexHome":"/tmp", "platformFamily":"unix", "platformOs":"macos"}})
assert read()["method"] == "initialized"
request = read()
if count == 1:
    print("intentional fake-server exit", file=sys.stderr, flush=True)
    raise SystemExit(7)
write({"id":request["id"], "result":{"value":request["method"]}})
"""#

    private static let fakeServer = #"""
import json
import os
import sys

assert sys.argv[1:] == ["app-server", "--listen", "stdio://"]
assert os.environ.get("CODEX_HOME") == "/tmp/langtools-test-codex-home"
assert os.environ.get("CODEX_INTERNAL_APP_SERVER_REMOTE_CONTROL_DISABLED") == "1"

def read():
    return json.loads(sys.stdin.readline())

def write(value):
    print(json.dumps(value), flush=True)

initialize = read()
assert initialize["method"] == "initialize"
assert initialize["params"]["clientInfo"]["name"] == "langtools-cli"
write({"id": initialize["id"], "result": {
    "userAgent": "fake-codex",
    "codexHome": os.environ["CODEX_HOME"],
    "platformFamily": "unix",
    "platformOs": "macos"
}})
assert read()["method"] == "initialized"

write({"id": "server-request", "method": "item/tool/requestUserInput", "params": {}})
requests = []
did_decline = False
while len(requests) < 2 or not did_decline:
    message = read()
    if message.get("id") == "server-request":
        assert message["result"]["answers"] == {}
        did_decline = True
    else:
        requests.append(message)
for request in reversed(requests):
    write({"id": request["id"], "result": {"value": request["method"]}})
"""#
}
