import Foundation
import XCTest
@testable import CLI

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

    func testInitializationFailsClosedForUnsupportedContainmentPlatform() async throws {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("langtools-app-server-platform-\(UUID().uuidString).py")
        try Data(Self.unsupportedPlatformServer.utf8).write(to: scriptURL)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let client = CodexAppServerClient(
            commandResolver: {
                ResolvedCodexCommand(executable: "/usr/bin/python3", arguments: ["-u", scriptURL.path])
            },
            defaultTimeout: .seconds(2)
        )
        do {
            _ = try await client.initializedProcessGeneration()
            XCTFail("Expected unsupported containment platform failure")
        } catch let error as CodexAppServerError {
            guard case .unsupportedContainmentPlatform(let platform) = error else {
                return XCTFail("Expected unsupported platform, got \(error)")
            }
            XCTAssertEqual(platform, "linux")
        }
        await client.shutdown()
    }

    func testStableSubscriptionFiltersPreventCrossThreadBuffering() async throws {
        XCTAssertEqual(CodexAppServerClient.maximumBufferedNotificationEvents, 256)
        XCTAssertEqual(CodexAppServerClient.maximumBufferedNotificationBytes, 1_048_576)
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("langtools-app-server-filter-\(UUID().uuidString).py")
        try Data(Self.filteredNotificationsServer.utf8).write(to: scriptURL)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let client = CodexAppServerClient(
            commandResolver: {
                ResolvedCodexCommand(executable: "/usr/bin/python3", arguments: ["-u", scriptURL.path])
            },
            defaultTimeout: .seconds(2)
        )
        let first = await client.subscribeToNotifications(
            methods: ["thread/event"],
            accepts: Self.threadFilter("thread-a")
        )
        let second = await client.subscribeToNotifications(
            methods: ["thread/event"],
            accepts: Self.threadFilter("thread-b")
        )
        let overflow = await client.subscribeToNotifications(
            methods: ["thread/event"],
            maximumBufferedEvents: 1,
            maximumBufferedBytes: 1_024
        )
        let byteOverflow = await client.subscribeToNotifications(
            methods: ["thread/event"],
            maximumBufferedEvents: 10,
            maximumBufferedBytes: 1
        )
        let _: Response = try await client.request(method: "notifications/start", params: RequestParams(value: "start"))

        let firstMetrics = await client.notificationBufferMetrics(for: first)
        let secondMetrics = await client.notificationBufferMetrics(for: second)
        let overflowMetrics = await client.notificationBufferMetrics(for: overflow)
        let byteOverflowMetrics = await client.notificationBufferMetrics(for: byteOverflow)
        XCTAssertEqual(firstMetrics?.events, 1)
        XCTAssertEqual(secondMetrics?.events, 1)
        XCTAssertEqual(firstMetrics?.failed, false)
        XCTAssertEqual(secondMetrics?.failed, false)
        XCTAssertEqual(overflowMetrics?.events, 0)
        XCTAssertEqual(overflowMetrics?.bytes, 0)
        XCTAssertEqual(overflowMetrics?.failed, true)
        XCTAssertEqual(byteOverflowMetrics?.events, 0)
        XCTAssertEqual(byteOverflowMetrics?.bytes, 0)
        XCTAssertEqual(byteOverflowMetrics?.failed, true)
        for _ in 0..<2 {
            do {
                _ = try await client.nextNotification(from: overflow)
                XCTFail("Expected persistent terminal overflow failure")
            } catch let error as CodexAppServerError {
                guard case .invalidResponse(let message) = error else {
                    return XCTFail("Expected invalid response, got \(error)")
                }
                XCTAssertTrue(message.contains("buffer limits"))
            }
        }

        let firstEvent = try await client.nextNotification(from: first)
        let secondEvent = try await client.nextNotification(from: second)
        XCTAssertEqual(try JSONDecoder().decode(ThreadEvent.self, from: firstEvent.params).threadId, "thread-a")
        XCTAssertEqual(try JSONDecoder().decode(ThreadEvent.self, from: secondEvent.params).threadId, "thread-b")
        let drainedFirstMetrics = await client.notificationBufferMetrics(for: first)
        let drainedSecondMetrics = await client.notificationBufferMetrics(for: second)
        XCTAssertEqual(drainedFirstMetrics?.events, 0)
        XCTAssertEqual(drainedSecondMetrics?.events, 0)
        await client.cancelNotificationSubscription(first)
        await client.cancelNotificationSubscription(first)
        await client.cancelNotificationSubscription(second)
        await client.cancelNotificationSubscription(overflow)
        await client.cancelNotificationSubscription(byteOverflow)
        await client.shutdown()
    }

    func testProcessChunkPumpFailsClosedWhenBoundedBufferDropsData() async {
        XCTAssertEqual(CodexAppServerClient.maximumBufferedProcessChunks, 256)
        let overflows = ThreadSafeCounter()
        let pump = ProcessChunkPump(
            label: "test",
            maximumBufferedChunks: 2,
            onOverflow: { overflows.increment() }
        )
        pump.yield(Data("one".utf8))
        pump.yield(Data("two".utf8))
        pump.yield(Data("three".utf8))
        pump.yield(Data("four".utf8))
        XCTAssertEqual(overflows.value, 1)

        var values: [String] = []
        for await data in pump.stream {
            values.append(String(decoding: data, as: UTF8.self))
        }
        XCTAssertEqual(values, ["one", "two"])
    }

    func testOversizedCompleteStdoutLineFailsPendingWorkAndRecovers() async throws {
        try await assertOversizedStdoutFailsClosed(mode: "complete")
    }

    func testOversizedUnterminatedStdoutLineFailsPendingWorkAndRecovers() async throws {
        try await assertOversizedStdoutFailsClosed(mode: "unterminated")
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

    private func assertOversizedStdoutFailsClosed(mode: String) async throws {
        XCTAssertEqual(CodexAppServerClient.maximumStdoutNDJSONLineBytes, 1_048_576)
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("langtools-app-server-oversized-\(UUID().uuidString).py")
        let countURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("langtools-app-server-oversized-\(UUID().uuidString).count")
        try Data(Self.oversizedStdoutServer.utf8).write(to: scriptURL)
        defer {
            try? FileManager.default.removeItem(at: scriptURL)
            try? FileManager.default.removeItem(at: countURL)
        }
        let client = CodexAppServerClient(
            commandResolver: {
                ResolvedCodexCommand(executable: "/usr/bin/python3", arguments: ["-u", scriptURL.path])
            },
            environment: [
                "MODE": mode,
                "COUNT_FILE": countURL.path,
                "LIMIT": String(CodexAppServerClient.maximumStdoutNDJSONLineBytes)
            ],
            defaultTimeout: .seconds(5)
        )
        let subscription = await client.subscribeToNotifications(methods: ["never/event"])
        let notificationWaiter = Task {
            try await client.nextNotification(from: subscription, timeout: .seconds(5))
        }
        for _ in 0..<100 {
            if await client.notificationBufferMetrics(for: subscription)?.waiting == true { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let waitingMetrics = await client.notificationBufferMetrics(for: subscription)
        XCTAssertEqual(waitingMetrics?.waiting, true)

        do {
            let _: Response = try await client.request(method: "oversized/start", params: RequestParams(value: mode))
            XCTFail("Expected oversized stdout failure")
        } catch let error as CodexAppServerError {
            guard case .invalidResponse(let message) = error else {
                return XCTFail("Expected invalid response, got \(error)")
            }
            XCTAssertTrue(message.contains("oversized"))
        }
        switch await notificationWaiter.result {
        case .failure(let error as CodexAppServerError):
            guard case .invalidResponse(let message) = error else {
                return XCTFail("Expected subscription invalid response, got \(error)")
            }
            XCTAssertTrue(message.contains("oversized"))
        default:
            XCTFail("Expected pending subscription to fail closed")
        }

        let recovered: Response = try await client.request(
            method: "oversized/recovered",
            params: RequestParams(value: "recovered")
        )
        XCTAssertEqual(recovered.value, "recovered")
        XCTAssertEqual(try String(contentsOf: countURL, encoding: .utf8), "2")
        await client.shutdown()
    }

    private struct ThreadEvent: Decodable {
        let threadId: String
    }

    private static func threadFilter(_ threadID: String) -> @Sendable (Data) -> Bool {
        { data in
            (try? JSONDecoder().decode(ThreadEvent.self, from: data).threadId) == threadID
        }
    }

    private static let oversizedStdoutServer = #"""
import json
import os
import sys
import time

count_file = os.environ["COUNT_FILE"]
try:
    generation = int(open(count_file).read()) + 1
except FileNotFoundError:
    generation = 1
open(count_file, "w").write(str(generation))

def read():
    return json.loads(sys.stdin.readline())

def write(value):
    print(json.dumps(value), flush=True)

initialize = read()
write({"id":initialize["id"], "result":{"userAgent":"fake","codexHome":"/tmp","platformFamily":"unix","platformOs":"macos"}})
assert read()["method"] == "initialized"
request = read()
if generation == 1:
    oversized = "x" * int(os.environ["LIMIT"])
    for offset in range(0, len(oversized), 32768):
        sys.stdout.write(oversized[offset:offset + 32768])
        sys.stdout.flush()
        time.sleep(0.03)
    if os.environ["MODE"] == "complete":
        sys.stdout.write("x\n")
    else:
        sys.stdout.write("x")
    sys.stdout.flush()
    while True:
        time.sleep(1)
else:
    write({"id":request["id"], "result":{"value":"recovered"}})
    while True:
        read()
"""#

    private static let filteredNotificationsServer = #"""
import json
import sys

def read():
    return json.loads(sys.stdin.readline())

def write(value):
    print(json.dumps(value), flush=True)

initialize = read()
write({"id":initialize["id"], "result":{"userAgent":"fake","codexHome":"/tmp","platformFamily":"unix","platformOs":"macos"}})
assert read()["method"] == "initialized"
request = read()
assert request["method"] == "notifications/start"
write({"method":"thread/event", "params":{"threadId":"thread-b", "value":"b"}})
write({"method":"thread/event", "params":{"threadId":"thread-a", "value":"a"}})
write({"id":request["id"], "result":{"value":"started"}})
while True:
    read()
"""#

    private static let unsupportedPlatformServer = #"""
import json
import sys

request = json.loads(sys.stdin.readline())
print(json.dumps({"id":request["id"], "result":{"userAgent":"fake","codexHome":"/tmp","platformFamily":"unix","platformOs":"linux"}}), flush=True)
while True:
    sys.stdin.readline()
"""#

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

private final class ThreadSafeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int { lock.withLock { storedValue } }

    func increment() {
        lock.withLock { storedValue += 1 }
    }
}
