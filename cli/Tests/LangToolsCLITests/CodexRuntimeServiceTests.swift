import Foundation
import XCTest
@testable import CLI

final class CodexRuntimeServiceTests: XCTestCase {
    func testAccountModelsAndImmediateTurnDeltasUseNonLossySubscription() async throws {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("langtools-runtime-test-\(UUID().uuidString).py")
        try Data(Self.fakeServer.utf8).write(to: scriptURL)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let client = CodexAppServerClient(
            commandResolver: {
                ResolvedCodexCommand(executable: "/usr/bin/python3", arguments: ["-u", scriptURL.path])
            },
            defaultTimeout: .seconds(5)
        )
        let runtime = CodexRuntimeService(client: client, browserOpener: { _ in })

        let status = try await runtime.accountStatus()
        XCTAssertTrue(status.authenticated)
        XCTAssertEqual(status.accountIdentifier, "person@example.com")
        let models = try await runtime.modelSlugs()
        let expected = (0..<150).map { "\($0)," }.joined()
        let stream = await runtime.chatStream(model: "codex-one", messages: [.init(role: "user", content: "Stream")])
        var iterator = stream.makeAsyncIterator()
        let firstEvent = try await iterator.next()
        XCTAssertEqual(firstEvent, .delta("0,"))
        var streamed = "0,"
        var completed: String?
        while let event = try await iterator.next() {
            switch event {
            case .delta(let value): streamed += value
            case .complete(let value): completed = value
            }
        }
        XCTAssertEqual(streamed, expected)
        XCTAssertEqual(completed, expected)

        let response = try await runtime.chat(model: "codex-one", messages: [.init(role: "user", content: "Aggregate")])
        XCTAssertEqual(models, ["codex-one", "codex-two"])
        XCTAssertEqual(response, expected)
        await runtime.shutdown()
    }

    func testStreamConsumerCancellationInterruptsExactStartedTurn() async throws {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("langtools-runtime-stream-cancel-\(UUID().uuidString).py")
        let markerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("langtools-runtime-stream-cancel-\(UUID().uuidString).marker")
        try Data(Self.streamCancellationServer.utf8).write(to: scriptURL)
        defer {
            try? FileManager.default.removeItem(at: scriptURL)
            try? FileManager.default.removeItem(at: markerURL)
        }

        let client = CodexAppServerClient(
            commandResolver: {
                ResolvedCodexCommand(executable: "/usr/bin/python3", arguments: ["-u", scriptURL.path])
            },
            environment: ["MARKER": markerURL.path],
            defaultTimeout: .seconds(5)
        )
        let runtime = CodexRuntimeService(client: client, browserOpener: { _ in })
        let stream = await runtime.chatStream(
            model: "codex-one",
            messages: [.init(role: "user", content: "Cancel")],
            conversationID: UUID()
        )
        let receivedDelta = expectation(description: "received immediate delta")
        let consumer = Task {
            for try await event in stream {
                if event == .delta("partial") { receivedDelta.fulfill() }
            }
        }
        await fulfillment(of: [receivedDelta], timeout: 1)
        consumer.cancel()
        _ = await consumer.result

        for _ in 0..<100 where FileManager.default.fileExists(atPath: markerURL.path) == false {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(try String(contentsOf: markerURL, encoding: .utf8), "thread-1:turn-1")
        await runtime.shutdown()
    }

    func testPreTurnStartBurstExceedingNotificationBoundsInterruptsExactTurn() async throws {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("langtools-runtime-notification-overflow-\(UUID().uuidString).py")
        let markerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("langtools-runtime-notification-overflow-\(UUID().uuidString).marker")
        try Data(Self.preTurnNotificationOverflowServer.utf8).write(to: scriptURL)
        defer {
            try? FileManager.default.removeItem(at: scriptURL)
            try? FileManager.default.removeItem(at: markerURL)
        }
        let client = CodexAppServerClient(
            commandResolver: {
                ResolvedCodexCommand(executable: "/usr/bin/python3", arguments: ["-u", scriptURL.path])
            },
            environment: ["MARKER": markerURL.path],
            defaultTimeout: .seconds(5)
        )
        let runtime = CodexRuntimeService(client: client, browserOpener: { _ in })
        do {
            _ = try await runtime.chat(model: "codex-one", messages: [.init(role: "user", content: "Burst")])
            XCTFail("Expected notification buffer overflow")
        } catch let error as CodexAppServerError {
            guard case .invalidResponse(let message) = error else {
                return XCTFail("Expected invalid response, got \(error)")
            }
            XCTAssertTrue(message.contains("buffer limits"))
        }
        XCTAssertEqual(try String(contentsOf: markerURL, encoding: .utf8), "thread-burst:turn-burst")
        await runtime.shutdown()
    }

    func testResponseSizeLimitInterruptsExactTurn() async throws {
        XCTAssertEqual(CodexRuntimeService.maximumResponseBytes, 8 * 1_048_576)
        try await assertStreamFailure(
            mode: "response-limit",
            responseByteLimit: 8,
            expectedError: { error in
                if case CodexRuntimeError.responseTooLarge = error { return true }
                return false
            }
        )
    }

    func testBoundedStreamOverflowInterruptsInsteadOfDroppingDelta() async throws {
        XCTAssertEqual(CodexRuntimeService.maximumBufferedStreamEvents, 256)
        try await assertStreamFailure(
            mode: "buffer-overflow",
            responseByteLimit: CodexRuntimeService.maximumResponseBytes,
            consume: false,
            expectedError: { error in
                guard case CodexRuntimeError.runtime(let message) = error else { return false }
                return message.contains("could not keep up")
            }
        )
    }

    private func assertStreamFailure(
        mode: String,
        responseByteLimit: Int,
        consume: Bool = true,
        expectedError: @escaping (Error) -> Bool
    ) async throws {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("langtools-runtime-stream-limit-\(UUID().uuidString).py")
        let markerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("langtools-runtime-stream-limit-\(UUID().uuidString).marker")
        try Data(Self.streamLimitServer.utf8).write(to: scriptURL)
        defer {
            try? FileManager.default.removeItem(at: scriptURL)
            try? FileManager.default.removeItem(at: markerURL)
        }
        let client = CodexAppServerClient(
            commandResolver: {
                ResolvedCodexCommand(executable: "/usr/bin/python3", arguments: ["-u", scriptURL.path])
            },
            environment: ["MARKER": markerURL.path, "MODE": mode],
            defaultTimeout: .seconds(5)
        )
        let runtime = CodexRuntimeService(
            client: client,
            browserOpener: { _ in },
            responseByteLimit: responseByteLimit
        )
        let stream = await runtime.chatStream(model: "codex-one", messages: [.init(role: "user", content: "Limit")])
        if consume {
            do {
                for try await _ in stream {}
                XCTFail("Expected stream failure")
            } catch {
                XCTAssertTrue(expectedError(error), "Unexpected stream error: \(error)")
            }
        } else {
            for _ in 0..<100 where FileManager.default.fileExists(atPath: markerURL.path) == false {
                try await Task.sleep(for: .milliseconds(10))
            }
            var iterator = stream.makeAsyncIterator()
            do {
                while let _ = try await iterator.next() {}
                XCTFail("Expected buffered stream failure")
            } catch {
                XCTAssertTrue(expectedError(error), "Unexpected stream error: \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: markerURL, encoding: .utf8), "thread-limit:turn-limit")
        await runtime.shutdown()
    }

    private static let preTurnNotificationOverflowServer = #"""
import json
import os
import sys
import time

def read():
    return json.loads(sys.stdin.readline())

def write(value):
    print(json.dumps(value), flush=True)

initialize = read()
write({"id":initialize["id"], "result":{"userAgent":"fake","codexHome":"/tmp","platformFamily":"unix","platformOs":"macos"}})
assert read()["method"] == "initialized"
request = read()
assert request["method"] == "thread/start"
write({"id":request["id"], "result":{"thread":{"id":"thread-burst"},"model":"codex-one","modelProvider":"openai"}})
request = read()
assert request["method"] == "turn/start"
for index in range(257):
    write({"method":"item/agentMessage/delta","params":{"threadId":"thread-burst","turnId":"turn-burst","itemId":"a","delta":str(index)}})
    if index % 32 == 31:
        time.sleep(0.01)
write({"id":request["id"], "result":{"turn":{"id":"turn-burst"}}})
request = read()
assert request["method"] == "turn/interrupt"
assert request["params"] == {"threadId":"thread-burst","turnId":"turn-burst"}
open(os.environ["MARKER"], "w").write("thread-burst:turn-burst")
write({"id":request["id"], "result":{}})
while True:
    read()
"""#

    private static let streamLimitServer = #"""
import json
import os
import sys

def read():
    return json.loads(sys.stdin.readline())

def write(value):
    print(json.dumps(value), flush=True)

initialize = read()
write({"id":initialize["id"], "result":{"userAgent":"fake","codexHome":"/tmp","platformFamily":"unix","platformOs":"macos"}})
assert read()["method"] == "initialized"
request = read()
assert request["method"] == "thread/start"
write({"id":request["id"], "result":{"thread":{"id":"thread-limit"},"model":"codex-one","modelProvider":"openai"}})
request = read()
assert request["method"] == "turn/start"
write({"id":request["id"], "result":{"turn":{"id":"turn-limit"}}})
if os.environ["MODE"] == "response-limit":
    deltas = ["123456789"]
else:
    deltas = [str(index) for index in range(257)]
for delta in deltas:
    write({"method":"item/agentMessage/delta","params":{"threadId":"thread-limit","turnId":"turn-limit","itemId":"a","delta":delta}})
request = read()
assert request["method"] == "turn/interrupt"
assert request["params"] == {"threadId":"thread-limit","turnId":"turn-limit"}
open(os.environ["MARKER"], "w").write("thread-limit:turn-limit")
write({"id":request["id"], "result":{}})
while True:
    read()
"""#

    private static let streamCancellationServer = #"""
import json
import os
import sys

def read():
    return json.loads(sys.stdin.readline())

def write(value):
    print(json.dumps(value), flush=True)

initialize = read()
write({"id":initialize["id"], "result":{"userAgent":"fake","codexHome":"/tmp","platformFamily":"unix","platformOs":"macos"}})
assert read()["method"] == "initialized"
request = read()
assert request["method"] == "thread/start"
write({"id":request["id"], "result":{"thread":{"id":"thread-1"},"model":"codex-one","modelProvider":"openai"}})
request = read()
assert request["method"] == "turn/start"
write({"id":request["id"], "result":{"turn":{"id":"turn-1"}}})
write({"method":"item/agentMessage/delta","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"a","delta":"partial"}})
request = read()
assert request["method"] == "turn/interrupt"
assert request["params"] == {"threadId":"thread-1","turnId":"turn-1"}
open(os.environ["MARKER"], "w").write("thread-1:turn-1")
write({"id":request["id"], "result":{}})
while True:
    read()
"""#

    private static let fakeServer = #"""
import json
import sys

def read():
    return json.loads(sys.stdin.readline())

def write(value):
    print(json.dumps(value), flush=True)

def model(id, model):
    return {"id": id, "model": model, "displayName": id, "description": "test", "hidden": False, "isDefault": False}

initialize = read()
write({"id": initialize["id"], "result": {"userAgent":"fake", "codexHome":"/tmp", "platformFamily":"unix", "platformOs":"macos"}})
assert read()["method"] == "initialized"

while True:
    request = read()
    method = request["method"]
    if method == "account/read":
        write({"id":request["id"], "result":{"account":{"type":"chatgpt","email":"person@example.com","planType":"plus"},"requiresOpenaiAuth":False}})
    elif method == "model/list":
        cursor = request["params"].get("cursor")
        if cursor is None:
            write({"id":request["id"], "result":{"data":[model(" codex-one ", "provider-one"), model("codex-one", "duplicate")],"nextCursor":"page-2"}})
        else:
            assert cursor == "page-2"
            write({"id":request["id"], "result":{"data":[model("codex-two", "provider-two")],"nextCursor":None}})
    elif method == "thread/start":
        params = request["params"]
        assert params["model"] == "codex-one"
        assert params["approvalPolicy"] == "never"
        assert params["sandbox"] == "workspace-write"
        assert params["ephemeral"] is True
        assert params["cwd"].startswith("/")
        assert "runtimeWorkspaceRoots" not in params
        assert "dynamicTools" not in params
        assert "environments" not in params
        assert "multiAgentMode" not in params
        assert "selectedCapabilityRoots" not in params
        assert "config" not in params
        write({"id":request["id"], "result":{"thread":{"id":"thread-1"},"model":"codex-one","modelProvider":"openai"}})
    elif method == "turn/start":
        params = request["params"]
        assert params["threadId"] == "thread-1"
        workspace = params["sandboxPolicy"]["writableRoots"][0]
        assert params["sandboxPolicy"] == {"type":"workspaceWrite","writableRoots":[workspace],"networkAccess":False,"excludeTmpdirEnvVar":True,"excludeSlashTmp":True}
        assert "runtimeWorkspaceRoots" not in params
        assert "permissions" not in params
        assert params["input"][0]["text_elements"] == []
        for index in range(75):
            write({"method":"item/agentMessage/delta","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"a","delta":str(index) + ","}})
        write({"id":request["id"], "result":{"turn":{"id":"turn-1"}}})
        write({"method":"item/agentMessage/delta","params":{"threadId":"other","turnId":"other","itemId":"x","delta":"ignore"}})
        for index in range(75, 150):
            write({"method":"item/agentMessage/delta","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"a","delta":str(index) + ","}})
        write({"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","status":"completed","error":None}}})
    else:
        write({"id":request["id"], "error":{"code":-32601,"message":"unexpected " + method}})
"""#
}
