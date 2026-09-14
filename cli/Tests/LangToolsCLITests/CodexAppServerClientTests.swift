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

        let initialGeneration = try await client.initializedProcessGeneration()
        async let first: Response = client.request(method: "test/first", params: RequestParams(value: "one"))
        async let second: Response = client.request(method: "test/second", params: RequestParams(value: "two"))
        let values = try await [first.value, second.value]
        XCTAssertEqual(Set(values), Set(["test/first", "test/second"]))
        let stableGeneration = try await client.initializedProcessGeneration()
        XCTAssertEqual(stableGeneration, initialGeneration)
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

        let initialGeneration = try await client.initializedProcessGeneration()
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
        let restartedGeneration = try await client.initializedProcessGeneration()
        XCTAssertNotEqual(restartedGeneration, initialGeneration)
        XCTAssertEqual(try String(contentsOf: countURL, encoding: .utf8), "2")
        await client.shutdown()
    }

    func testCancellationScopeCancelsStartupWaiterWithoutCancellingSharedInitialization() async throws {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("langtools-app-server-startup-scope-\(UUID().uuidString).py")
        let acceptedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("langtools-app-server-startup-scope-\(UUID().uuidString).accepted")
        try Data(Self.hangingInitializationServer.utf8).write(to: scriptURL)
        defer {
            try? FileManager.default.removeItem(at: scriptURL)
            try? FileManager.default.removeItem(at: acceptedURL)
        }

        let client = CodexAppServerClient(
            commandResolver: {
                ResolvedCodexCommand(executable: "/usr/bin/python3", arguments: ["-u", scriptURL.path])
            },
            environment: ["ACCEPTED": acceptedURL.path],
            defaultTimeout: .seconds(30)
        )
        let cancelledScope = UUID()
        let blocked = Task {
            try await client.request(
                method: "startup/blocked",
                params: RequestParams(value: "blocked"),
                cancellationScope: cancelledScope
            ) as Response
        }
        for _ in 0..<100 where FileManager.default.fileExists(atPath: acceptedURL.path) == false {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: acceptedURL.path))

        let unrelated = Task {
            try await client.request(
                method: "startup/unrelated",
                params: RequestParams(value: "unrelated"),
                cancellationScope: UUID()
            ) as Response
        }
        let barrierScope = UUID()
        await client.cancelRequests(in: barrierScope)
        await client.closeRequestCancellationScope(barrierScope)
        let cancelledPromptly = expectation(description: "startup waiter cancelled promptly")
        let blockedResult = Task {
            let result = await blocked.result
            cancelledPromptly.fulfill()
            return result
        }
        await client.cancelRequests(in: cancelledScope)
        await fulfillment(of: [cancelledPromptly], timeout: 0.5)

        do {
            let _: Response = try await client.request(
                method: "startup/tombstoned",
                params: RequestParams(value: "tombstoned"),
                cancellationScope: cancelledScope
            )
            XCTFail("Expected cancellation-before-startup tombstone rejection")
        } catch is CancellationError {
            // Expected.
        }

        await client.shutdown()
        switch await blockedResult.value {
        case .failure(let error as CancellationError):
            _ = error
        default:
            XCTFail("Expected scoped startup waiter cancellation")
        }
        switch await unrelated.result {
        case .failure(let error as CodexAppServerError):
            guard case .shutdown = error else {
                return XCTFail("Expected unrelated waiter to remain until shutdown, got \(error)")
            }
        default:
            XCTFail("Expected unrelated startup waiter to fail only at shutdown")
        }
    }

    func testCancellationScopeCancelsOnlyMatchingRequests() async throws {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("langtools-app-server-scope-\(UUID().uuidString).py")
        let acceptedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("langtools-app-server-scope-\(UUID().uuidString).accepted")
        try Data(Self.cancellationScopeServer.utf8).write(to: scriptURL)
        defer {
            try? FileManager.default.removeItem(at: scriptURL)
            try? FileManager.default.removeItem(at: acceptedURL)
        }

        let client = CodexAppServerClient(
            commandResolver: {
                ResolvedCodexCommand(executable: "/usr/bin/python3", arguments: ["-u", scriptURL.path])
            },
            environment: ["ACCEPTED": acceptedURL.path],
            defaultTimeout: .seconds(2)
        )
        let cancelledScope = UUID()
        let blocked = Task {
            try await client.request(
                method: "scope/blocked",
                params: RequestParams(value: "blocked"),
                cancellationScope: cancelledScope
            ) as Response
        }
        for _ in 0..<100 where FileManager.default.fileExists(atPath: acceptedURL.path) == false {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: acceptedURL.path))

        let unrelated: Response = try await client.request(
            method: "scope/unrelated",
            params: RequestParams(value: "unrelated"),
            cancellationScope: UUID()
        )
        await client.cancelRequests(in: cancelledScope)

        XCTAssertEqual(unrelated.value, "unrelated")
        do {
            _ = try await blocked.value
            XCTFail("Expected scoped request cancellation")
        } catch is CancellationError {
            // Expected.
        }
        do {
            let _: Response = try await client.request(
                method: "scope/tombstoned",
                params: RequestParams(value: "tombstoned"),
                cancellationScope: cancelledScope
            )
            XCTFail("Expected cancelled scope tombstone to reject a later request")
        } catch is CancellationError {
            // Expected.
        }
        await client.shutdown()
    }

    private static let hangingInitializationServer = #"""
import json
import os
import sys
import time

initialize = json.loads(sys.stdin.readline())
assert initialize["method"] == "initialize"
open(os.environ["ACCEPTED"], "w").write("accepted")
while True:
    time.sleep(1)
"""#

    private static let cancellationScopeServer = #"""
import json
import os
import sys

def read():
    return json.loads(sys.stdin.readline())

def write(value):
    print(json.dumps(value), flush=True)

initialize = read()
write({"id":initialize["id"], "result":{"userAgent":"fake", "codexHome":"/tmp", "platformFamily":"unix", "platformOs":"macos"}})
assert read()["method"] == "initialized"
blocked = read()
assert blocked["method"] == "scope/blocked"
open(os.environ["ACCEPTED"], "w").write("accepted")
unrelated = read()
assert unrelated["method"] == "scope/unrelated"
write({"id":unrelated["id"], "result":{"value":"unrelated"}})
while True:
    read()
"""#

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

write({"id": "user-input-request", "method": "item/tool/requestUserInput", "params": {}})
write({"id": "permissions-request", "method": "item/permissions/requestApproval", "params": {}})
requests = []
declined = set()
while len(requests) < 2 or len(declined) < 2:
    message = read()
    if message.get("id") == "user-input-request":
        assert message == {"id":"user-input-request","result":{"answers":{}}}
        declined.add("user-input")
    elif message.get("id") == "permissions-request":
        assert message == {"id":"permissions-request","result":{"permissions":{"fileSystem":None,"network":None},"scope":"turn","strictAutoReview":None}}
        declined.add("permissions")
    else:
        requests.append(message)
for request in reversed(requests):
    write({"id": request["id"], "result": {"value": request["method"]}})
"""#
}
