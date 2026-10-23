import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import HelperCore

/// Exercises producer lifetime only. The fake server is not evidence of LAN
/// principal read isolation; the shared Codex process currently has no such boundary.
final class MobileCodexContainmentTests: XCTestCase {
    func testCancelledFactoryQueuedOnActorDoesNotCreateProducer() async throws {
        let fixture = try Fixture(mode: "complete")
        defer { fixture.remove() }
        let runtime = fixture.makeRuntime()
        let gate = CodexFactoryGate(entered: expectation(description: "runtime actor held"))
        defer { gate.release() }
        let holder = Task { await runtime.holdStreamFactory(at: gate) }
        await fulfillment(of: [gate.entered], timeout: 3)
        let requested = expectation(description: "factory caller queued")
        let factory = Task {
            requested.fulfill()
            return try await runtime.chatStreamHandle(
                model: "codex-test", messages: [.init(role: "user", content: "cancelled")],
                conversationID: UUID()
            )
        }
        await fulfillment(of: [requested], timeout: 3)
        factory.cancel()
        gate.release()
        await holder.value
        do {
            let handle = try await factory.value
            await handle.cancelAndWait()
            XCTFail("A queued cancelled caller must be rejected before spawning")
        } catch is CancellationError {
            // Expected from the factory itself, not from a later stream consumer.
        }
        assertNoProducerWork(fixture)
        await runtime.shutdown()
    }

    func testCancelledRouteQueuedOnActorDoesNotCreateProducer() async throws {
        let fixture = try Fixture(mode: "complete")
        defer { fixture.remove() }
        let runtime = fixture.makeRuntime()
        let routes = AccountRouteHandlers(runtime: runtime)
        let gate = CodexFactoryGate(entered: expectation(description: "runtime actor held"))
        defer { gate.release() }
        let holder = Task { await runtime.holdStreamFactory(at: gate) }
        await fulfillment(of: [gate.entered], timeout: 3)
        let requested = expectation(description: "route caller queued")
        let request = Task {
            requested.fulfill()
            try await routes.streamEvents(Self.chatPayload, conversationID: UUID()) { _ in
                XCTFail("Cancelled route must not emit stream events")
            }
        }
        await fulfillment(of: [requested], timeout: 3)
        request.cancel()
        gate.release()
        await holder.value
        do {
            try await request.value
            XCTFail("Expected queued route cancellation")
        } catch is CancellationError {
            // The route's handler covers the factory actor hop.
        }
        assertNoProducerWork(fixture)
        await runtime.shutdown()
    }

    func testCancellationDuringProducerHandoffPreventsActorWork() async throws {
        let fixture = try Fixture(mode: "complete")
        defer { fixture.remove() }
        let runtime = fixture.makeRuntime()
        let cancellation = CodexChatStreamCancellation()
        let gate = CodexFactoryGate(entered: expectation(description: "producer created, handoff held"))
        defer { gate.release() }
        let caller = Task {
            try await withTaskCancellationHandler {
                let handle = try await runtime.createStreamHoldingHandoff(
                    cancellation: cancellation, gate: gate
                )
                await handle.wait()
                return handle
            } onCancel: {
                cancellation.cancel()
            }
        }
        await fulfillment(of: [gate.entered], timeout: 3)
        // Factory has created/registered the producer, but the actor is held and
        // the caller cannot have received its handle. Cancel through reservation.
        caller.cancel()
        gate.release()
        let handle = try await caller.value
        do {
            for try await _ in handle.stream { XCTFail("Cancelled producer emitted an event") }
            XCTFail("Expected producer cancellation before actor chat work")
        } catch is CancellationError {
            // The registered producer was cancelled before it could run chat.
        }
        assertNoProducerWork(fixture)
        await runtime.shutdown()
    }

    func testRouteCancellationDuringDelayedStartJoinsInterruptBeforeReturning() async throws {
        let fixture = try Fixture(mode: "interrupt")
        defer { fixture.remove() }
        let runtime = fixture.makeRuntime()
        let routes = AccountRouteHandlers(runtime: runtime)
        let conversationID = UUID()
        let request = Task {
            defer { try? fixture.mark("route-returned") }
            try await routes.streamEvents(Self.chatPayload, conversationID: conversationID) { _ in
                XCTFail("Cancelled quiet route must not emit events")
            }
        }
        try await fixture.waitFor("started")
        request.cancel()
        try fixture.mark("release-start")
        try await fixture.waitFor("interrupted")
        XCTAssertFalse(fixture.exists("route-returned"), "Cancellation must join upstream interruption")
        try fixture.mark("release-interrupt")
        do {
            try await request.value
            XCTFail("Expected route cancellation after joined cleanup")
        } catch is CancellationError {
            // Dispatch already happened: preserve turn ID and join interruption.
        }
        XCTAssertTrue(fixture.exists("route-returned"))
        let response = try await runtime.chat(
            model: "codex-test", messages: [.init(role: "user", content: "clean next turn")],
            conversationID: conversationID
        )
        XCTAssertEqual(response, "answer")
        await runtime.shutdown()
    }

    private static var chatPayload: HelperChatRequest {
        get throws {
            try AccountRouteHandlers.decodeChat(Data(#"{"provider":"openAI","model":"codex-test","messages":[{"role":"user","content":"hello"}],"stream":true}"#.utf8))
        }
    }

    private func assertNoProducerWork(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(fixture.exists("launched"), "Cancelled factory must not launch client", file: file, line: line)
        XCTAssertFalse(fixture.exists("started"), "Cancelled factory must not send turn/start", file: file, line: line)
        let files = FileManager.default.enumerator(at: fixture.url("cache"), includingPropertiesForKeys: nil)
        let conversations = files?.compactMap { $0 as? URL }.filter {
            $0.lastPathComponent.hasPrefix("conversation-")
        } ?? []
        XCTAssertTrue(conversations.isEmpty, "Producer must not execute actor chat/workspace creation", file: file, line: line)
    }

    func testCancelAndWaitJoinsDelayedStartAndInterruptFromCancelledCaller() async throws {
        try await assertCancellationJoinsProducer(cancelConsumer: false)
    }

    func testStreamConsumerTerminationThenWaitJoinsProducerCleanup() async throws {
        try await assertCancellationJoinsProducer(cancelConsumer: true)
    }

    func testWaitAllowsCompletionAndIncludesEphemeralWorkspaceCleanup() async throws {
        let fixture = try Fixture(mode: "complete")
        defer { fixture.remove() }
        let runtime = fixture.makeRuntime()
        let handle = try await runtime.chatStreamHandle(
            model: "codex-test", messages: [.init(role: "user", content: "hello")]
        )
        try await fixture.waitFor("started")
        let waiter = Task {
            await handle.wait()
            try fixture.mark("joined")
        }
        XCTAssertFalse(fixture.exists("joined"))
        try fixture.mark("release-start")
        try await waiter.value

        var events: [CodexChatStreamEvent] = []
        for try await event in handle.stream { events.append(event) }
        XCTAssertEqual(events, [.delta("answer"), .complete("answer")])
        XCTAssertFalse(fixture.exists("interrupted"))
        let workspace = try String(contentsOf: fixture.url("workspace"), encoding: .utf8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace))
        await handle.cancelAndWait() // Idempotent after successful completion.
        await runtime.shutdown()
    }

    func testRejectedInterruptKillsAndJoinsOldProcessBeforeConversationReuse() async throws {
        try await assertFailedInterruptTerminatesProcess(mode: "reject")
    }

    func testTimedOutInterruptKillsAndJoinsOldProcessBeforeConversationReuse() async throws {
        try await assertFailedInterruptTerminatesProcess(mode: "timeout")
    }

    func testStaleGenerationCleanupCannotInterruptOrInvalidateReplacementProcess() async throws {
        let fixture = try Fixture(mode: "complete")
        defer { fixture.remove() }
        let client = fixture.makeClient()
        let oldGeneration = try await client.initializedProcessGeneration()
        try await client.restart()
        let newGeneration = try await client.initializedProcessGeneration()
        XCTAssertNotEqual(oldGeneration, newGeneration)
        do {
            let _: CodexEmptyParams = try await client.request(
                method: "turn/interrupt",
                params: CodexTurnInterruptParams(threadId: "old-thread", turnId: "old-turn"),
                expectedProcessGeneration: oldGeneration
            )
            XCTFail("Stale interrupt must not be sent to the replacement process")
        } catch CodexAppServerError.restarted {
            // Expected; the replacement remains initialized.
        }
        await client.invalidateProcessAndWait(expectedGeneration: oldGeneration)
        let remainingGeneration = try await client.initializedProcessGeneration()
        XCTAssertEqual(remainingGeneration, newGeneration)
        XCTAssertFalse(fixture.exists("interrupted"))
        await client.shutdown()
        await client.invalidateProcessAndWait(expectedGeneration: newGeneration)
    }

    private func assertFailedInterruptTerminatesProcess(mode: String) async throws {
        let fixture = try Fixture(mode: mode)
        defer { fixture.remove() }
        let runtime = fixture.makeRuntime(interruptionTimeout: .milliseconds(100))
        let conversationID = UUID()
        let handle = try await runtime.chatStreamHandle(
            model: "codex-test", messages: [.init(role: "user", content: "hello")],
            conversationID: conversationID
        )
        try await fixture.waitFor("started")
        let oldPID = try XCTUnwrap(Int32(try String(contentsOf: fixture.url("oldpid"), encoding: .utf8)))
        let joiner = Task {
            await handle.cancelAndWait()
            try fixture.mark("joined")
        }
        joiner.cancel()
        try fixture.mark("release-start")
        try await fixture.waitFor("interrupted")
        XCTAssertFalse(fixture.exists("joined"))
        try fixture.mark("release-interrupt")
        try await fixture.waitFor("terminated")
        XCTAssertEqual(kill(oldPID, 0), 0, "Fake app-server deliberately ignores SIGTERM")
        XCTAssertFalse(fixture.exists("joined"), "Cannot release ownership while old process lives")
        do {
            _ = try await runtime.chat(
                model: "codex-test", messages: [.init(role: "user", content: "too soon")],
                conversationID: conversationID
            )
            XCTFail("Conversation slot was released before upstream exit")
        } catch CodexRuntimeError.accountConflict {
            // Still reserved until forced termination has been confirmed.
        }
        try await joiner.value
        XCTAssertEqual(kill(oldPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)

        let response = try await runtime.chat(
            model: "codex-test", messages: [.init(role: "user", content: "clean next turn")],
            conversationID: conversationID
        )
        XCTAssertEqual(response, "answer")
        let newPID = try XCTUnwrap(Int32(try String(contentsOf: fixture.url("newpid"), encoding: .utf8)))
        XCTAssertNotEqual(oldPID, newPID)
        XCTAssertEqual(kill(newPID, 0), 0)
        await runtime.shutdown()
    }

    private func assertCancellationJoinsProducer(cancelConsumer: Bool) async throws {
        let fixture = try Fixture(mode: "interrupt")
        defer { fixture.remove() }
        let runtime = fixture.makeRuntime()
        let conversationID = UUID()
        let handle = try await runtime.chatStreamHandle(
            model: "codex-test", messages: [.init(role: "user", content: "hello")],
            conversationID: conversationID
        )
        let consumer = Task { () throws -> Void in
            for try await _ in handle.stream {}
        }
        try await fixture.waitFor("started")
        if cancelConsumer { consumer.cancel() }
        let joiner = Task {
            if cancelConsumer {
                await handle.wait()
            } else {
                await handle.cancelAndWait()
            }
            try fixture.mark("joined")
        }
        // Joining must remain effective even when invoked by a cancelled request task.
        joiner.cancel()
        XCTAssertFalse(fixture.exists("joined"))
        try fixture.mark("release-start")
        try await fixture.waitFor("interrupted")
        XCTAssertFalse(fixture.exists("joined"), "Join returned before interrupt acknowledgement")
        let workspace = try String(contentsOf: fixture.url("workspace"), encoding: .utf8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace))
        try fixture.mark("release-interrupt")
        try await joiner.value
        XCTAssertEqual(
            try String(contentsOf: fixture.url("interrupted"), encoding: .utf8),
            "thread-mobile/turn-mobile"
        )
        do {
            try await consumer.value
            // AsyncThrowingStream may end normally when its consumer is cancelled.
            if cancelConsumer == false { XCTFail("Expected stream cancellation") }
        } catch is CancellationError {
            // Expected; the producer has already finished cleanup.
        }
        // Same actor/conversation is usable immediately after the join: its
        // activeOperation must have been cleared, not merely its stream finished.
        let response = try await runtime.chat(
            model: "codex-test", messages: [.init(role: "user", content: "next")],
            conversationID: conversationID
        )
        XCTAssertEqual(response, "answer")
        await handle.cancelAndWait()
        await runtime.endConversation(id: conversationID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace))
        await runtime.shutdown()
    }

    private struct Fixture: Sendable {
        let root: URL

        init(mode: String) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("mobile-codex-lifetime-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            try Data(Self.server.utf8).write(to: root.appendingPathComponent("server.py"))
            try Data(mode.utf8).write(to: root.appendingPathComponent("mode"))
        }

        func url(_ name: String) -> URL { root.appendingPathComponent(name) }
        func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: url(name).path) }
        func mark(_ name: String) throws { try Data("ready".utf8).write(to: url(name)) }
        func remove() { try? FileManager.default.removeItem(at: root) }

        func waitFor(_ name: String) async throws {
            for _ in 0..<500 {
                if exists(name) { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw CodexRuntimeError.timeout("Fake Codex did not reach \(name)")
        }

        func makeClient() -> CodexAppServerClient {
            let script = url("server.py")
            return CodexAppServerClient(
                commandResolver: {
                    ResolvedCodexCommand(executable: "/usr/bin/python3", arguments: ["-u", script.path])
                },
                environment: ProcessInfo.processInfo.environment,
                defaultTimeout: .seconds(10),
                containmentMode: .disabledForTesting
            )
        }

        func makeRuntime(interruptionTimeout: Duration = .seconds(5)) -> CodexRuntimeService {
            return CodexRuntimeService(
                client: makeClient(), browserOpener: { _ in },
                turnCompletionTimeout: .seconds(10),
                workspaces: CodexConversationWorkspace(cacheRoot: url("cache")),
                interruptionTimeout: interruptionTimeout
            )
        }

        private static let server = #"""
import json
import os
import signal
import sys
import time

root = os.path.dirname(__file__)
mode = open(os.path.join(root, "mode")).read()

def mark(name, value):
    with open(os.path.join(root, name), "w") as f:
        f.write(value)

def wait(name):
    deadline = time.monotonic() + 10
    while not os.path.exists(os.path.join(root, name)):
        if time.monotonic() > deadline:
            raise RuntimeError("gate timed out: " + name)
        time.sleep(0.005)

def write(value):
    print(json.dumps(value), flush=True)

if mode in ("reject", "timeout"):
    if os.path.exists(os.path.join(root, "oldpid")):
        mark("newpid", str(os.getpid()))
        mode = "complete"
    else:
        mark("oldpid", str(os.getpid()))
        signal.signal(signal.SIGTERM, lambda *_: mark("terminated", str(os.getpid())))

def complete():
    write({"method":"item/agentMessage/delta", "params":{"threadId":"thread-mobile", "turnId":"turn-mobile", "itemId":"item-mobile", "delta":"answer"}})
    write({"method":"turn/completed", "params":{"threadId":"thread-mobile", "turn":{"id":"turn-mobile", "status":"completed", "error":None}}})

mark("launched", str(os.getpid()))
turn_count = 0
for line in sys.stdin:
    request = json.loads(line)
    method = request["method"]
    if method == "initialize":
        write({"id":request["id"], "result":{"userAgent":"fake", "codexHome":"/tmp", "platformFamily":"unix", "platformOs":"macos"}})
    elif method == "initialized":
        continue
    elif method == "thread/start":
        mark("workspace", request["params"]["cwd"])
        write({"id":request["id"], "result":{"thread":{"id":"thread-mobile"}, "model":"codex-test", "modelProvider":"openai"}})
    elif method == "turn/start":
        turn_count += 1
        if turn_count == 1:
            mark("started", "ready")
            wait("release-start")
        write({"id":request["id"], "result":{"turn":{"id":"turn-mobile"}}})
        if mode == "complete" or turn_count > 1:
            complete()
    elif method == "turn/interrupt":
        assert request["params"] == {"threadId":"thread-mobile", "turnId":"turn-mobile"}
        mark("interrupted", "thread-mobile/turn-mobile")
        wait("release-interrupt")
        if mode == "reject":
            write({"id":request["id"], "error":{"code":-32602, "message":"interrupt rejected"}})
        elif mode != "timeout":
            write({"id":request["id"], "result":{}})
    else:
        raise RuntimeError("unexpected method: " + method)

# Closing stdin and SIGTERM must not accidentally make the failure tests pass.
while mode in ("reject", "timeout"):
    time.sleep(0.01)
"""#
    }
}

/// Test-only synchronous actor gates: no hooks or blocking paths in production.
private final class CodexFactoryGate: @unchecked Sendable {
    let entered: XCTestExpectation
    private let semaphore = DispatchSemaphore(value: 0)

    init(entered: XCTestExpectation) { self.entered = entered }

    func hold() {
        entered.fulfill()
        if semaphore.wait(timeout: .now() + 5) != .success {
            XCTFail("Factory test actor gate was not released")
        }
    }

    func release() { semaphore.signal() }
}

private extension CodexRuntimeService {
    func holdStreamFactory(at gate: CodexFactoryGate) {
        gate.hold()
    }

    func createStreamHoldingHandoff(
        cancellation: CodexChatStreamCancellation,
        gate: CodexFactoryGate
    ) throws -> CodexChatStreamHandle {
        let handle = try chatStreamHandle(
            model: "codex-test", messages: [.init(role: "user", content: "cancelled handoff")],
            conversationID: UUID(), cancellation: cancellation
        )
        gate.hold()
        return handle
    }
}
