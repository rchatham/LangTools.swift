import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import LangTools

// The shim is Linux-only. These fixtures invoke the same internal state machine
// as data(for:), with synthetic resume/cancel actions: no URLProtocol or sockets.
#if !canImport(Darwin)
final class URLSessionCancellationTests: XCTestCase {
    private typealias Transfer = URLSession.DataTaskCancellation

    func testPreCancelledCallerNeverResumesTask() async {
        let transfer = Transfer()
        let calls = Calls()
        let caller = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    transfer.install { result in
                        calls.completed(result)
                        continuation.resume(returning: result)
                    }
                    transfer.start(resume: { calls.resumed() }, cancel: { calls.cancelled() })
                }
            } onCancel: {
                transfer.cancel()
            }
        }
        let result = await caller.value
        assertCancelled(result)
        XCTAssertEqual(calls.snapshot.resumes, 0)
        XCTAssertEqual(calls.snapshot.cancels, 1)
        XCTAssertEqual(calls.snapshot.completions, 1)
    }

    func testCancellationBetweenContinuationInstallationAndStartNeverResumes() {
        let transfer = Transfer()
        let calls = Calls()
        transfer.install { calls.completed($0) }
        transfer.cancel()
        transfer.start(resume: { calls.resumed() }, cancel: {
            calls.cancelled()
            // Foundation may deliver a synchronous or late cancellation callback.
            transfer.complete(.failure(URLError(.cancelled)))
        })
        transfer.cancel()
        XCTAssertEqual(calls.snapshot.resumes, 0)
        XCTAssertEqual(calls.snapshot.cancels, 1)
        XCTAssertEqual(calls.snapshot.completions, 1)
        XCTAssertEqual(calls.snapshot.errorCode, .cancelled)
    }

    func testCancellationDuringResumeDefersTaskCancelWithoutHoldingLock() {
        let transfer = Transfer()
        let calls = Calls()
        let cancellationWorker = DispatchGroup()
        transfer.install { result in
            calls.completed(result)
            transfer.cancel() // Continuation callback can reenter without deadlock.
        }
        transfer.start(resume: {
            calls.resumed()
            // A deterministic cross-thread cancellation while resume is active.
            let cancellationFinished = DispatchSemaphore(value: 0)
            cancellationWorker.enter()
            DispatchQueue(label: "synthetic-shim-cancellation").async {
                defer { cancellationWorker.leave() }
                transfer.cancel()
                cancellationFinished.signal()
            }
            XCTAssertEqual(cancellationFinished.wait(timeout: .now() + 2), .success)
            XCTAssertEqual(calls.snapshot.cancels, 0)
        }, cancel: {
            calls.cancelled()
            transfer.complete(.failure(URLError(.cancelled)))
        })
        // A timeout records failure, never permission to abandon the worker.
        // A genuine deadlock must be bounded by the isolated test-process watchdog.
        cancellationWorker.wait()
        transfer.complete(success())
        XCTAssertEqual(calls.snapshot.resumes, 1)
        XCTAssertEqual(calls.snapshot.cancels, 1)
        XCTAssertEqual(calls.snapshot.completions, 1)
        XCTAssertEqual(calls.snapshot.errorCode, .cancelled)
    }

    func testCancellationAfterStartWinsOverLateCompletion() {
        let transfer = Transfer()
        let calls = Calls()
        transfer.install { calls.completed($0) }
        transfer.start(resume: { calls.resumed() }, cancel: {
            calls.cancelled()
            transfer.complete(self.success())
        })
        transfer.cancel()
        transfer.complete(success())
        transfer.cancel()
        XCTAssertEqual(calls.snapshot.resumes, 1)
        XCTAssertEqual(calls.snapshot.cancels, 1)
        XCTAssertEqual(calls.snapshot.completions, 1)
        XCTAssertEqual(calls.snapshot.errorCode, .cancelled)
    }

    func testCompletionDuringResumeWinsOverLaterCancellation() {
        let transfer = Transfer()
        let calls = Calls()
        transfer.install { result in
            calls.completed(result)
            transfer.cancel()
        }
        transfer.start(resume: {
            calls.resumed()
            transfer.complete(success())
        }, cancel: { calls.cancelled() })
        transfer.cancel()
        transfer.complete(.failure(URLError(.badServerResponse)))
        XCTAssertEqual(calls.snapshot.resumes, 1)
        XCTAssertEqual(calls.snapshot.cancels, 0)
        XCTAssertEqual(calls.snapshot.completions, 1)
        XCTAssertNil(calls.snapshot.errorCode)
        XCTAssertEqual(calls.snapshot.successfulData, Data("synthetic".utf8))
        XCTAssertEqual(calls.snapshot.successfulURL, URL(string: "https://synthetic.invalid/"))
    }

    func testTransportErrorAfterStartWinsOverLaterCancellation() {
        let transfer = Transfer()
        let calls = Calls()
        transfer.install { calls.completed($0) }
        transfer.start(resume: { calls.resumed() }, cancel: { calls.cancelled() })
        transfer.complete(.failure(URLError(.cannotConnectToHost)))
        transfer.cancel()
        transfer.complete(success())
        XCTAssertEqual(calls.snapshot.resumes, 1)
        XCTAssertEqual(calls.snapshot.cancels, 0)
        XCTAssertEqual(calls.snapshot.completions, 1)
        XCTAssertEqual(calls.snapshot.errorCode, .cannotConnectToHost)
    }

    func testCancellationBeforeInstallationDeliversExactlyOnceAndAllowsReentry() {
        let transfer = Transfer()
        let calls = Calls()
        transfer.cancel()
        transfer.cancel()
        transfer.install { result in
            calls.completed(result)
            transfer.complete(self.success())
            transfer.cancel()
        }
        transfer.start(resume: { calls.resumed() }, cancel: { calls.cancelled() })
        XCTAssertEqual(calls.snapshot.resumes, 0)
        XCTAssertEqual(calls.snapshot.cancels, 1)
        XCTAssertEqual(calls.snapshot.completions, 1)
        XCTAssertEqual(calls.snapshot.errorCode, .cancelled)
    }

    private func success() -> Result<Transfer.Response, Error> {
        .success((Data("synthetic".utf8), URLResponse(
            url: URL(string: "https://synthetic.invalid/")!, mimeType: nil,
            expectedContentLength: 9, textEncodingName: nil
        )))
    }

    private func assertCancelled(_ result: Result<Transfer.Response, Error>,
                                 file: StaticString = #filePath, line: UInt = #line) {
        switch result {
        case .success: XCTFail("Expected cancellation", file: file, line: line)
        case .failure(let error):
            XCTAssertEqual((error as? URLError)?.code, .cancelled, file: file, line: line)
        }
    }

    private final class Calls: @unchecked Sendable {
        struct Snapshot {
            var resumes = 0
            var cancels = 0
            var completions = 0
            var errorCode: URLError.Code?
            var successfulData: Data?
            var successfulURL: URL?
        }
        private let lock = NSLock()
        private var value = Snapshot()
        var snapshot: Snapshot {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        func resumed() {
            lock.lock()
            value.resumes += 1
            lock.unlock()
        }
        func cancelled() {
            lock.lock()
            value.cancels += 1
            lock.unlock()
        }
        func completed(_ result: Result<Transfer.Response, Error>) {
            lock.lock()
            value.completions += 1
            switch result {
            case .success(let response):
                value.successfulData = response.0
                value.successfulURL = response.1.url
            case .failure(let error):
                value.errorCode = (error as? URLError)?.code
            }
            lock.unlock()
        }
    }
}
#endif
