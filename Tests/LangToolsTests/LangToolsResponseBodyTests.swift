import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LangTools

final class LangToolsResponseBodyTests: XCTestCase {
    private func body(_ source: MemoryLines) -> LangToolsResponseBody {
        LangToolsResponseBody(response: memoryResponse(), nextLine: { try await source.next() }, cancel: { source.cancel() })
    }

    func testSuccessEOFAndCleanupOnce() async throws {
        let source = MemoryLines([.success("one"), .success("two"), .success(nil)])
        let body = body(source)
        let first = try await body.nextLine()
        let second = try await body.nextLine()
        let end = try await body.nextLine()
        let repeatedEnd = try await body.nextLine()
        XCTAssertEqual(first, "one")
        XCTAssertEqual(second, "two")
        XCTAssertNil(end)
        XCTAssertNil(repeatedEnd)
        body.cancel()
        body.cancel()
        XCTAssertEqual(source.counts.reads, 3)
        XCTAssertEqual(source.counts.cancels, 1)
    }

    func testCallbackErrorIsTerminalAndCleansOnce() async {
        let source = MemoryLines([.failure(MemoryFailure.expected), .success("must not read")])
        let body = body(source)
        for _ in 0..<2 {
            do { _ = try await body.nextLine(); XCTFail("Expected terminal error") }
            catch MemoryFailure.expected {}
            catch { XCTFail("Unexpected error: \(error)") }
        }
        body.cancel()
        XCTAssertEqual(source.counts.reads, 1)
        XCTAssertEqual(source.counts.cancels, 1)
    }

    func testUnconsumedDeinitAndExplicitCancelCleanOnce() {
        let abandoned = MemoryLines([])
        var first: LangToolsResponseBody? = body(abandoned)
        XCTAssertNotNil(first)
        first = nil
        XCTAssertEqual(abandoned.counts.cancels, 1)
        let cancelled = MemoryLines([])
        var second: LangToolsResponseBody? = body(cancelled)
        second?.cancel()
        second = nil
        XCTAssertEqual(cancelled.counts.cancels, 1)
    }

    func testOverlappingReadIsNonterminal() async {
        let entered = expectation(description: "first callback entered")
        let source = MemoryLines([], entered: entered)
        let body = body(source)
        let first = Task { try await body.nextLine() }
        await fulfillment(of: [entered], timeout: 2)
        guard source.counts.reads == 1 else {
            first.cancel(); source.cancel(); _ = await first.result
            return XCTFail("First reader did not enter")
        }
        do { _ = try await body.nextLine(); XCTFail("Expected overlap") }
        catch LangToolsResponseBodyError.overlappingRead {}
        catch { XCTFail("Unexpected error: \(error)") }
        source.release(.success("accepted"))
        let result = await first.result
        first.cancel()
        body.cancel()
        switch result {
        case .success(let line): XCTAssertEqual(line, "accepted")
        case .failure(let error): XCTFail("First reader failed: \(error)")
        }
        XCTAssertEqual(source.counts.reads, 1)
        XCTAssertEqual(source.counts.cancels, 1)
    }

    func testCancelledRejectedReaderDoesNotCancelFirstReader() async {
        let entered = expectation(description: "first callback entered")
        let source = MemoryLines([], entered: entered)
        let body = body(source)
        let first = Task { try await body.nextLine() }
        await fulfillment(of: [entered], timeout: 2)
        guard source.counts.reads == 1 else {
            first.cancel(); source.cancel(); _ = await first.result
            return XCTFail("First reader did not enter")
        }
        let ready = expectation(description: "second ready before admission")
        let gate = MemoryLatch()
        let second = Task {
            ready.fulfill()
            await gate.wait()
            return try await body.nextLine()
        }
        await fulfillment(of: [ready], timeout: 2)
        second.cancel()
        gate.open()
        let rejected = await second.result
        XCTAssertEqual(source.counts.cancels, 0)
        source.release(.success("still alive"))
        let accepted = await first.result
        first.cancel()
        body.cancel()
        if case .failure(LangToolsResponseBodyError.overlappingRead) = rejected {} else { XCTFail("Expected overlap, got \(rejected)") }
        if case .success(let line) = accepted { XCTAssertEqual(line, "still alive") } else { XCTFail("First reader was cancelled") }
    }

    func testAlreadyCancelledAdmittedReaderDoesNotInvokeCallback() async {
        let ready = expectation(description: "reader ready")
        let gate = MemoryLatch()
        let source = MemoryLines([.success("not read")])
        let body = body(source)
        let reader = Task {
            ready.fulfill()
            await gate.wait()
            return try await body.nextLine()
        }
        await fulfillment(of: [ready], timeout: 2)
        reader.cancel()
        gate.open()
        let result = await reader.result
        body.cancel()
        assertCancelled(result)
        XCTAssertEqual(source.counts.reads, 0)
        XCTAssertEqual(source.counts.cancels, 1)
    }

    func testStickyCancellationBeforeUnderlyingReadInstallation() async {
        // Deterministically suspend the admitted callback before it installs its
        // pending read. This covers the sticky-cancel contract for the admission /
        // invocation gap without exposing a production gate hook solely for tests.
        let entered = expectation(description: "admitted callback before read installation")
        let gate = MemoryLatch()
        let source = MemoryLines([])
        let body = LangToolsResponseBody(response: memoryResponse(), nextLine: {
            entered.fulfill()
            await gate.wait()
            return try await source.next()
        }, cancel: { source.cancel() })
        let reader = Task { try await body.nextLine() }
        await fulfillment(of: [entered], timeout: 2)
        body.cancel()
        gate.open()
        // Keep the test joinable even if body cancellation fails to call the
        // fixture. Correct sticky cancellation ignores this fallback payload.
        source.release(.success("late fallback"))
        let result = await reader.result
        reader.cancel()
        assertCancelled(result)
        XCTAssertEqual(source.counts.reads, 1)
        XCTAssertEqual(source.counts.cancels, 1)
    }

    func testInFlightTaskCancellationWakesReader() async {
        let entered = expectation(description: "pending read")
        let source = MemoryLines([], entered: entered)
        let body = body(source)
        let reader = Task { try await body.nextLine() }
        await fulfillment(of: [entered], timeout: 2)
        reader.cancel()
        // Explicit cleanup also guarantees fixture release if handler behavior
        // regresses; the count assertion still requires exactly-once cleanup.
        source.release(.success("late line"))
        let result = await reader.result
        body.cancel()
        assertCancelled(result)
        XCTAssertEqual(source.counts.cancels, 1)
    }

    func testCancellationSuppressesCallbackLineAndError() async {
        let outcomes: [Result<String?, Error>] = [.success("late"), .failure(MemoryFailure.expected)]
        for late in outcomes {
            let entered = expectation(description: "callback entered")
            let gate = MemoryLatch()
            let source = MemoryLines([])
            let body = LangToolsResponseBody(response: memoryResponse(), nextLine: {
                entered.fulfill()
                await gate.wait()
                return try late.get()
            }, cancel: { source.cancel() })
            let reader = Task { try await body.nextLine() }
            await fulfillment(of: [entered], timeout: 2)
            body.cancel()
            gate.open()
            let result = await reader.result
            reader.cancel()
            assertCancelled(result)
            XCTAssertEqual(source.counts.cancels, 1)
        }
    }

    private func assertCancelled(_ result: Result<String?, Error>, file: StaticString = #filePath, line: UInt = #line) {
        if case .failure(is CancellationError) = result {} else {
            XCTFail("Expected cancellation, got \(result)", file: file, line: line)
        }
    }
}

private func memoryResponse() -> URLResponse {
    URLResponse(url: URL(string: "https://memory.invalid/body")!, mimeType: nil, expectedContentLength: -1, textEncodingName: nil)
}

private enum MemoryFailure: Error { case expected, unexpectedOverlap }

// All state is lock protected; continuation delivery and expectation callbacks
// occur outside the lock. release/cancel are sticky even before read installation.
private final class MemoryLines: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Result<String?, Error>]
    private var pending: CheckedContinuation<String?, Error>?
    private var cancelled = false
    private var reads = 0
    private var cancels = 0
    private let entered: XCTestExpectation?

    init(_ values: [Result<String?, Error>], entered: XCTestExpectation? = nil) {
        self.values = values
        self.entered = entered
    }

    var counts: (reads: Int, cancels: Int) {
        lock.lock(); defer { lock.unlock() }
        return (reads, cancels)
    }

    func next() async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            reads += 1
            let value: Result<String?, Error>?
            if cancelled { value = .failure(CancellationError()) }
            else if pending != nil { value = .failure(MemoryFailure.unexpectedOverlap) }
            else if !values.isEmpty { value = values.removeFirst() }
            else { value = nil; pending = continuation }
            lock.unlock()
            entered?.fulfill()
            if let value { continuation.resume(with: value) }
        }
    }

    func release(_ value: Result<String?, Error>) {
        lock.lock()
        let continuation = pending
        pending = nil
        if continuation == nil && !cancelled { values.append(value) }
        lock.unlock()
        continuation?.resume(with: value)
    }

    func cancel() {
        lock.lock()
        cancels += 1
        cancelled = true
        let continuation = pending
        pending = nil
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }
}

private final class MemoryLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if opened { lock.unlock(); continuation.resume() }
            else { waiters.append(continuation); lock.unlock() }
        }
    }

    func open() {
        lock.lock()
        opened = true
        let pending = waiters
        waiters = []
        lock.unlock()
        for waiter in pending { waiter.resume() }
    }
}
