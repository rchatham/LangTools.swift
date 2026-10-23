import Foundation
import XCTest
@testable import HelperCore

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
            environment: [
                "LANGTOOLS_CODEX_HOME": "/tmp/langtools-test-codex-home",
                "SECRET_API_KEY": "should-not-leak"
            ],
            defaultTimeout: .seconds(5),
            containmentMode: .disabledForTesting
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

    func testInitializationUsesSeparateTimeoutFromOperationalRequests() async throws {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("langtools-app-server-timeouts-\(UUID().uuidString).py")
        try Data(Self.delayedResponseServer.utf8).write(to: scriptURL)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let recorder = TimeoutRecorder()
        let client = CodexAppServerClient(
            commandResolver: {
                ResolvedCodexCommand(executable: "/usr/bin/python3", arguments: ["-u", scriptURL.path])
            },
            defaultTimeout: .seconds(30),
            initializationTimeout: .seconds(8),
            requestTimeoutSleeper: { method, duration in
                recorder.record(method: method, duration: duration)
                try await Task.sleep(for: .seconds(60))
            },
            containmentMode: .disabledForTesting
        )

        _ = try await client.initializedProcessGeneration()
        let response: Response = try await client.request(
            method: "test/delayed",
            params: RequestParams(value: "request")
        )
        XCTAssertEqual(response.value, "test/delayed")
        XCTAssertEqual(recorder.duration(for: "initialize"), .seconds(8))
        XCTAssertEqual(recorder.duration(for: "test/delayed"), .seconds(30))
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
            defaultTimeout: .seconds(2),
            containmentMode: .disabledForTesting
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
            defaultTimeout: .seconds(2),
            containmentMode: .disabledForTesting
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
            defaultTimeout: .seconds(2),
            containmentMode: .disabledForTesting
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

    // The dedicated finite fixture leaves inherited fixture defaults intact.
    func testFiniteResponseFlushThenExitDiagnostic() async throws {
        try await withPass4Fixture() { client, observation in
            _ = try await observation.generation(client)
            let primary: Result<Response, Error>
            do {
                let response: Response = try await client.request(
                    method: "test/delayed", params: RequestParams(value: "request")
                )
                primary = .success(response)
            } catch { primary = .failure(error) }
            observation.mark("primary/finite-response", detail: String(reflecting: primary))
            // On BOTH success and error, observe natural disappearance before any
            // invalidation can terminate the child. exitIntent is not OS status.
            var naturalExitError: Error?
            do {
                // Request cancellation must not cancel this natural-exit observer.
                let observingExit = Task.detached {
                    try await observation.waitForExitIntent(launch: 1)
                    try await observation.waitForChildExit(launch: 1)
                }
                try await observingExit.value
            } catch {
                naturalExitError = error
                observation.mark("finite/natural-exit-observation-error", detail: String(reflecting: error))
                XCTFail("Finite child natural exit was not observed before teardown: \(error)")
            }
            let response = try primary.get() // Preserve the original request error.
            XCTAssertEqual(response.value, "test/delayed")
            if let naturalExitError { throw naturalExitError }
        }
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
            defaultTimeout: .seconds(2),
            containmentMode: .disabledForTesting
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

    func testStdoutCloseBeforeProcessReapingAttributesExitStatus() async throws {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("langtools-app-server-stdout-close-\(UUID().uuidString).py")
        let countURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("langtools-app-server-stdout-close-count-\(UUID().uuidString)")
        try Data(Self.stdoutClosingServer.utf8).write(to: scriptURL)
        defer {
            try? FileManager.default.removeItem(at: scriptURL)
            try? FileManager.default.removeItem(at: countURL)
        }

        let client = CodexAppServerClient(
            commandResolver: {
                ResolvedCodexCommand(executable: "/usr/bin/python3", arguments: ["-u", scriptURL.path])
            },
            environment: ["COUNT_FILE": countURL.path],
            defaultTimeout: .seconds(2),
            containmentMode: .disabledForTesting
        )

        let initialGeneration = try await client.initializedProcessGeneration()
        do {
            let _: Response = try await client.request(method: "stdout/close", params: RequestParams(value: "one"))
            XCTFail("Expected process exit")
        } catch let error as CodexAppServerError {
            // The fixture closes stdout while it is still running, so EOF reaches the client
            // before the reaper observes termination. The exit status must still win.
            guard case .exited(let status, _) = error else {
                return XCTFail("Expected exited error, got \(error)")
            }
            XCTAssertEqual(status, 7)
        }

        let restarted: Response = try await client.request(
            method: "stdout/close/restarted", params: RequestParams(value: "two")
        )
        XCTAssertEqual(restarted.value, "stdout/close/restarted")
        let restartedGeneration = try await client.initializedProcessGeneration()
        XCTAssertNotEqual(restartedGeneration, initialGeneration)
        XCTAssertEqual(try String(contentsOf: countURL, encoding: .utf8), "2")
        await client.shutdown()
    }

    func testAlreadyCancelledTurnDoesNotLaunchClientOrStrandSubsequentStartup() async throws {
        try await observeColdStartup(preCancelled: true)
    }

    func testNormalColdStartupSucceedsWithoutCancelledWaiter() async throws {
        try await observeColdStartup(preCancelled: false)
    }

    func testControlledSlowColdStartupExceedsLegacyObservationWindow() async throws {
        // Both fresh paths use the same controlled fixture. This proves that three
        // seconds can reject valid completion, not the cause of the historical CI delay.
        try await observeColdStartup(preCancelled: false, controlled: true)
        try await observeColdStartup(preCancelled: true, controlled: true)
    }

    func testDelayedFixtureEntryAllowsNormalColdStartup() async throws {
        try await observeColdStartup(preCancelled: false, entryDelayed: true)
    }

    func testDelayedFixtureEntryAllowsPreCancelledRecovery() async throws {
        try await observeColdStartup(preCancelled: true, entryDelayed: true)
    }

    func testColdStartupObservationPreservesBarrierError() async throws {
        try await observeColdStartup(preCancelled: false, barrierError: true)
    }

    private struct ColdStartupTrace: Decodable {
        let stages: [String: UInt64]
        let error: String?
    }

    private final class ColdStartupRecorder: @unchecked Sendable {
        struct Snapshot {
            var phases: [String: ContinuousClock.Instant] = [:]
            var timers: [String: Duration] = [:]
            var result: Result<Response, Error>?
        }

        private let lock = NSLock()
        private var stored = Snapshot()
        var snapshot: Snapshot { lock.withLock { stored } }

        func mark(_ phase: String) {
            lock.withLock {
                if stored.phases[phase] == nil { stored.phases[phase] = ContinuousClock.now }
            }
        }

        func timer(method: String, duration: Duration) {
            lock.withLock {
                stored.phases["timer/\(method)"] = ContinuousClock.now
                stored.timers[method] = duration
            }
        }

        func finish(_ result: Result<Response, Error>) {
            lock.withLock {
                // A terminal timestamp is published only with the explicit outcome.
                stored.result = result
                stored.phases["terminal"] = ContinuousClock.now
            }
        }
    }

    private static func coldStartupFile(_ url: URL) throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    private func observeColdStartup(
        preCancelled: Bool,
        controlled: Bool = false,
        entryDelayed: Bool = false,
        barrierError: Bool = false
    ) async throws {
        // Exercise entry and reply delays separately, never consuming two holds
        // within the unchanged initialization timeout.
        guard !controlled || !entryDelayed else {
            throw NSError(domain: "ColdStartupObservation", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Fixture-entry and initialize-reply holds must not be stacked"
            ])
        }
        let initializationTimeout = Duration.seconds(8)
        let operationalTimeout = Duration.seconds(2)
        let uncoveredResolutionLaunchObservationAllowance = Duration.seconds(3)
        let legacyObservationWindow = Duration.seconds(3)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("langtools-cold-observation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let scriptURL = directory.appendingPathComponent("server.py")
        let logURL = directory.appendingPathComponent("transcript")
        let traceURL = directory.appendingPathComponent("trace.json")
        let releaseURL = directory.appendingPathComponent("release")
        do {
            try Data(Self.coldStartupObservationServer.utf8).write(to: scriptURL)
        } catch {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Cold-start setup cleanup error: \(error)") }
            throw error
        }
        var environment = ["LOG": logURL.path, "TRACE": traceURL.path]
        if controlled {
            environment["INITIALIZE_HOLD_SECONDS"] = "3.25"
            environment["RELEASE"] = releaseURL.path
        }
        if entryDelayed { environment["FIXTURE_ENTRY_HOLD_SECONDS"] = "3.25" }
        if barrierError { environment["BARRIER_ERROR"] = "1" }
        let recorder = ColdStartupRecorder()
        let resolutions = ThreadSafeCounter()
        let client = CodexAppServerClient(
            commandResolver: {
                recorder.mark("resolverEntry")
                resolutions.increment()
                defer { recorder.mark("resolverReturn") }
                return ResolvedCodexCommand(executable: "/usr/bin/python3", arguments: ["-u", scriptURL.path])
            },
            environment: environment,
            defaultTimeout: operationalTimeout,
            initializationTimeout: initializationTimeout,
            requestTimeoutSleeper: { method, duration in
                recorder.timer(method: method, duration: duration)
                try await Task.sleep(for: duration)
            },
            containmentMode: .disabledForTesting
        )
        var requests: [Task<Void, Never>] = []
        var trace: ColdStartupTrace?
        var transcript: String?
        var primaryError: Error?

        func readEvidence() throws {
            if let data = try Self.coldStartupFile(traceURL) {
                let decoded = try JSONDecoder().decode(ColdStartupTrace.self, from: data)
                trace = decoded
                for stage in decoded.stages.keys { recorder.mark("observed/\(stage)") }
            }
            if let data = try Self.coldStartupFile(logURL) {
                transcript = try XCTUnwrap(String(data: data, encoding: .utf8), "Invalid transcript UTF-8")
            }
        }

        do {
            if preCancelled {
                let cancelled = ColdStartupRecorder()
                cancelled.mark("requestStart")
                requests.append(Task {
                    withUnsafeCurrentTask { $0?.cancel() }
                    do {
                        let response: Response = try await client.request(
                            method: "turn/start",
                            params: RequestParams(value: "cancelled"),
                            cancelOnTaskCancellation: false
                        )
                        cancelled.finish(.success(response))
                    } catch { cancelled.finish(.failure(error)) }
                })
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                while cancelled.snapshot.result == nil && ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                let outcome = try XCTUnwrap(cancelled.snapshot.result, "Pre-cancelled request remained pending")
                guard case .failure(let error) = outcome, error is CancellationError else {
                    throw NSError(domain: "ColdStartupObservation", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "Expected CancellationError, got \(outcome)"
                    ])
                }
                try readEvidence()
                XCTAssertEqual(resolutions.value, 0)
                XCTAssertNil(trace, "Pre-cancelled input launched the fixture")
                XCTAssertNil(transcript, "Pre-cancelled input wrote a transcript/turn")
                let snapshot = cancelled.snapshot
                let start = try XCTUnwrap(snapshot.phases["requestStart"])
                let terminal = try XCTUnwrap(snapshot.phases["terminal"])
                print("COLD_START_CANCELLED result=\(outcome) elapsed=\(start.duration(to: terminal)) " +
                      "resolverCount=\(resolutions.value) traceMissing=\(trace == nil) transcriptMissing=\(transcript == nil)")
            }

            // Freeze the policy: 8s initialization + 2s request + 3s uncovered
            // resolution/launch/observation allowance. Historical successful cold
            // totals of 2.113/2.852s motivate that allowance, not a production bound.
            // Every phase shares this original absolute deadline; none restarts it.
            // Receipt and host polling can occur beyond 3s while initialization
            // remains within its 8s timer; phase observations are diagnostics.
            recorder.mark("requestStart")
            let start = try XCTUnwrap(recorder.snapshot.phases["requestStart"])
            let deadline = start.advanced(by: initializationTimeout + operationalTimeout +
                                          uncoveredResolutionLaunchObservationAllowance)
            requests.append(Task {
                do {
                    let response: Response = try await client.request(
                        method: "test/barrier", params: RequestParams(value: "barrier")
                    )
                    recorder.finish(.success(response))
                } catch { recorder.finish(.failure(error)) }
            })
            if controlled {
                let legacyDeadline = start.advanced(by: legacyObservationWindow)
                while ContinuousClock.now < legacyDeadline {
                    try readEvidence()
                    try await Task.sleep(for: .milliseconds(10))
                }
                try readEvidence()
                XCTAssertNil(recorder.snapshot.result, "Controlled startup completed before release")
                XCTAssertFalse(FileManager.default.fileExists(atPath: releaseURL.path))
                print("COLD_START_LEGACY preCancelled=\(preCancelled) elapsed=\(start.duration(to: .now)) " +
                      "pending=\(recorder.snapshot.result == nil) releaseAbsent=true")
                try Data().write(to: releaseURL)
            }
            while ContinuousClock.now < deadline {
                try readEvidence()
                if recorder.snapshot.result != nil && trace?.stages["barrierResponseFlushed"] != nil { break }
                // On an early error, preserve it immediately instead of waiting for
                // a success trace that the failed fixture cannot produce.
                if case .failure? = recorder.snapshot.result, !barrierError { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            try readEvidence()
            let snapshot = recorder.snapshot
            let outcome = try XCTUnwrap(snapshot.result, "Cold-start request still pending at absolute 13s deadline")
            if barrierError {
                guard case .failure(let error as CodexAppServerError) = outcome,
                      case .server(let code, let message) = error else {
                    throw NSError(domain: "ColdStartupObservation", code: 2, userInfo: [
                        NSLocalizedDescriptionKey: "Expected exact barrier server error, got \(outcome)"
                    ])
                }
                XCTAssertEqual(code, -32077)
                XCTAssertEqual(message, "cold-start observation barrier error")
            } else {
                let response = try outcome.get()
                XCTAssertEqual(response.value, "test/barrier")
            }
            XCTAssertEqual(resolutions.value, 1)
            XCTAssertEqual(transcript?.split(separator: "\n"), ["initialize", "initialized", "test/barrier"])
            XCTAssertEqual(snapshot.timers["initialize"], initializationTimeout)
            XCTAssertEqual(snapshot.timers["test/barrier"], operationalTimeout)
            let stages = try XCTUnwrap(trace).stages
            if entryDelayed {
                let holdStarted = try XCTUnwrap(stages["entryHoldStarted"])
                let fixtureEntry = try XCTUnwrap(stages["fixtureEntry"])
                XCTAssertGreaterThanOrEqual(fixtureEntry, holdStarted)
                let entryHold = (Double(fixtureEntry) - Double(holdStarted)) / 1_000_000_000
                XCTAssertGreaterThanOrEqual(entryHold, 3.25, "Opt-in entry hold must actually run")
                // Host durations use only ContinuousClock. Both old success
                // predicates must reject this valid, successful cold startup.
                for stage in ["observed/fixtureEntry", "observed/initializeReceived"] {
                    let instant = try XCTUnwrap(snapshot.phases[stage], "Missing host stage: \(stage)")
                    XCTAssertGreaterThan(start.duration(to: instant), legacyObservationWindow, stage)
                }
            }
            let initializeReceived = try XCTUnwrap(stages["initializeReceived"])
            let initializeFlushed = try XCTUnwrap(stages["initializeResponseFlushed"])
            let barrierReceived = try XCTUnwrap(stages["barrierReceived"])
            let barrierFlushed = try XCTUnwrap(stages["barrierResponseFlushed"])
            // Differences stay within the Python clock origin; host observations
            // above use only ContinuousClock timestamps.
            XCTAssertGreaterThanOrEqual(initializeFlushed, initializeReceived)
            XCTAssertGreaterThanOrEqual(barrierFlushed, barrierReceived)
            let initialization = (Double(initializeFlushed) - Double(initializeReceived)) / 1_000_000_000
            let barrier = (Double(barrierFlushed) - Double(barrierReceived)) / 1_000_000_000
            XCTAssertLessThan(initialization, 8)
            XCTAssertLessThan(barrier, 2)
            if controlled { XCTAssertGreaterThanOrEqual(initialization, 3.25) }
            XCTAssertLessThanOrEqual(ContinuousClock.now, deadline, "All success/error evidence must fit the absolute budget")
        } catch {
            primaryError = error
            // Missing evidence is not allowed to replace the original outcome.
            do { try readEvidence() }
            catch { XCTFail("Cold-start evidence read/parse error before teardown: \(error)") }
        }

        // Durable test logs capture both clock origins, the explicit result and
        // transcript availability BEFORE cancellation/shutdown, including failures.
        let snapshot = recorder.snapshot
        let hostPhases = snapshot.phases.sorted { $0.key < $1.key }.map { stage, instant in
            let elapsed = snapshot.phases["requestStart"].map { $0.duration(to: instant) }
            return "\(stage)=\(elapsed.map(String.init(describing:)) ?? "before-request")"
        }.joined(separator: ", ")
        print("COLD_START preCancelled=\(preCancelled) controlled=\(controlled) entryDelayed=\(entryDelayed) barrierError=\(barrierError) " +
              "result=\(snapshot.result.map(String.init(describing:)) ?? "pending") primaryError=\(primaryError.map(String.init(describing:)) ?? "none") " +
              "resolverCount=\(resolutions.value) timers=\(snapshot.timers) " +
              "host={\(hostPhases)} fixture=\(trace.map(String.init(describing:)) ?? "missing") transcript=\(transcript.map { String(reflecting: $0) } ?? "missing")")

        requests.forEach { $0.cancel() }
        let shutdown = Task { await client.shutdown() }
        let joined = ThreadSafeCounter()
        let joining = Task {
            for request in requests { await request.value }
            await shutdown.value
            joined.increment()
        }
        let cleanupDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while joined.value == 0 && ContinuousClock.now < cleanupDeadline {
            // Cleanup must still run if the observing task was itself cancelled.
            do { try await Task.sleep(for: .milliseconds(10)) }
            catch { XCTFail("Cold-start cleanup polling cancelled: \(error)"); break }
        }
        if joined.value == 0 {
            XCTFail("Cold-start cleanup timeout (3s), separate from primary outcome; scratch retained at \(directory.path)")
            joining.cancel()
        } else {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Cold-start scratch cleanup error: \(error)") }
        }
        if let primaryError { throw primaryError }
    }

    func testCancellationImmediatelyBeforeTurnDispatchSendsNoTurn() async throws {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("langtools-pre-dispatch-\(UUID().uuidString).py")
        let logURL = scriptURL.appendingPathExtension("log")
        try Data(Self.preDispatchCancellationServer.utf8).write(to: scriptURL)
        defer {
            for url in [scriptURL, logURL] { try? FileManager.default.removeItem(at: url) }
        }
        let client = CodexAppServerClient(
            commandResolver: {
                ResolvedCodexCommand(executable: "/usr/bin/python3", arguments: ["-u", scriptURL.path])
            },
            environment: ["LOG": logURL.path],
            defaultTimeout: .seconds(2),
            containmentMode: .disabledForTesting
        )
        _ = try await client.initializedProcessGeneration()
        let turn = Task {
            try await client.request(
                method: "turn/start",
                params: CancellingTurnParams(),
                cancelOnTaskCancellation: false
            ) as Response
        }
        do {
            _ = try await turn.value
            XCTFail("Expected cancellation at the write boundary")
        } catch is CancellationError {
            // Encoding deterministically cancels after request/startup preflight.
        }
        // A response to a later request proves the server drained preceding input.
        let _: Response = try await client.request(method: "test/barrier", params: RequestParams(value: "barrier"))
        let methods = try String(contentsOf: logURL, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(methods, ["initialize", "initialized", "test/barrier"])
        await client.shutdown()
    }

    func testCancellationDuringInitializationSendsNoTurnAndPreservesSharedStartup() async throws {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("langtools-startup-cancellation-\(UUID().uuidString).py")
        let logURL = scriptURL.appendingPathExtension("log")
        let acceptedURL = scriptURL.appendingPathExtension("accepted")
        let releaseURL = scriptURL.appendingPathExtension("release")
        try Data(Self.preDispatchCancellationServer.utf8).write(to: scriptURL)
        defer {
            for url in [scriptURL, logURL, acceptedURL, releaseURL] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let client = CodexAppServerClient(
            commandResolver: {
                ResolvedCodexCommand(executable: "/usr/bin/python3", arguments: ["-u", scriptURL.path])
            },
            environment: ["LOG": logURL.path, "ACCEPTED": acceptedURL.path, "RELEASE": releaseURL.path],
            defaultTimeout: .seconds(2),
            containmentMode: .disabledForTesting
        )
        let turn = Task {
            try await client.request(
                method: "turn/start",
                params: RequestParams(value: "cancelled"),
                cancelOnTaskCancellation: false
            ) as Response
        }
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: acceptedURL.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: acceptedURL.path))
        turn.cancel()
        do {
            _ = try await turn.value
            XCTFail("Expected initialization waiter cancellation")
        } catch is CancellationError {
            // Cancellation must not submit a turn after initialization completes.
        }
        try Data().write(to: releaseURL)
        let _: Response = try await client.request(method: "test/barrier", params: RequestParams(value: "barrier"))
        let methods = try String(contentsOf: logURL, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(methods, ["initialize", "initialized", "test/barrier"])
        await client.shutdown()
    }

    private struct CancellingTurnParams: Encodable {
        func encode(to encoder: Encoder) throws {
            // Cancel within the requesting task, after startup/preflight but before
            // the actor writes. No sleeps, detached cancellation, or production hook.
            withUnsafeCurrentTask { $0?.cancel() }
            try RequestParams(value: "cancelled during encoding").encode(to: encoder)
        }
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
            defaultTimeout: .seconds(30),
            containmentMode: .disabledForTesting
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
            defaultTimeout: .seconds(2),
            containmentMode: .disabledForTesting
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
            defaultTimeout: .seconds(5),
            containmentMode: .disabledForTesting
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

    private func withPass4Fixture(
        body: (CodexAppServerClient, Pass4Observation) async throws -> Void
    ) async throws {
        let observation = try Pass4Observation()
        try Data(Self.pass4DiagnosticServer.utf8).write(to: observation.scriptURL)
        let client = CodexAppServerClient(
            commandResolver: {
                observation.resolve()
                return ResolvedCodexCommand(executable: "/usr/bin/python3", arguments: ["-u", observation.scriptURL.path])
            },
            environment: [
                "TRACE": observation.traceURL.path, "COUNT_FILE": observation.countURL.path
            ],
            defaultTimeout: .seconds(5),
            initializationTimeout: .seconds(8),
            requestTimeoutSleeper: { method, duration in
                observation.mark("timer/\(method)", detail: String(describing: duration))
                try await Task.sleep(for: duration)
            },
            containmentMode: .disabledForTesting
        )
        var primaryError: Error?
        do { try await body(client, observation) }
        catch { primaryError = error }
        // Primary result, both separate clock origins and protocol transcript are
        // durable BEFORE cancellation/invalidation, on every outcome.
        do { try observation.snapshot(stage: "before-teardown", primaryError: primaryError) }
        catch { XCTFail("Pass4 evidence failure: \(error)"); if primaryError == nil { primaryError = error } }
        let cleanupError = await observation.cleanup(client)
        if let cleanupError { XCTFail("PASS4_STOP cleanup failure: \(cleanupError); retain \(observation.directory.path)") }
        do { try observation.snapshot(stage: "after-teardown", primaryError: primaryError) }
        catch { XCTFail("Pass4 final evidence failure: \(error)"); if primaryError == nil { primaryError = error } }
        if let primaryError { throw primaryError }
        if let cleanupError { throw cleanupError }
    }

    private static let pass4DiagnosticServer = #"""
import json
import os
import sys
import time

origin = time.monotonic_ns()
count_file = os.environ["COUNT_FILE"]
try:
    launch = int(open(count_file).read()) + 1
except FileNotFoundError:
    launch = 1
with open(count_file, "w") as count:
    count.write(str(launch))

def mark(stage, message=None):
    record = {"stage": stage, "pid": os.getpid(), "launch": launch,
              "monotonicNanoseconds": time.monotonic_ns() - origin, "message": message}
    with open(os.environ["TRACE"], "a") as trace:
        trace.write(json.dumps(record) + "\n")

def read():
    line = sys.stdin.readline()
    if not line:
        mark("stdinEOF")
        raise SystemExit(0)
    message = json.loads(line)
    mark("requestReceived", json.dumps(message))
    return message

def write(value):
    print(json.dumps(value), flush=True)
    mark("responseFlushed", json.dumps(value))

try:
    mark("fixtureEntry")
    initialize = read()
    assert initialize["method"] == "initialize"
    time.sleep(0.05)
    write({"id": initialize["id"], "result": {"userAgent": "fake", "codexHome": "/tmp", "platformFamily": "unix", "platformOs": "macos"}})
    assert read()["method"] == "initialized"
    request = read()
    time.sleep(0.05)
    write({"id": request["id"], "result": {"value": request["method"]}})
    mark("exitIntent", "0")
    raise SystemExit(0)
except SystemExit:
    raise
except Exception as error:
    mark("fixtureError", repr(error))
    print("pass4 fixture: " + repr(error), file=sys.stderr, flush=True)
    raise
"""#

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

    private static let preDispatchCancellationServer = #"""
import json
import os
import sys
import time

for line in sys.stdin:
    request = json.loads(line)
    with open(os.environ["LOG"], "a") as log:
        log.write(request["method"] + "\n")
    if request["method"] == "initialize":
        if "RELEASE" in os.environ:
            open(os.environ["ACCEPTED"], "w").close()
            while not os.path.exists(os.environ["RELEASE"]):
                time.sleep(0.005)
        result = {"userAgent":"fake", "codexHome":"/tmp", "platformFamily":"unix", "platformOs":"macos"}
    else:
        result = {"value":request["method"]}
    if "id" in request:
        print(json.dumps({"id":request["id"], "result":result}), flush=True)
"""#

    private static let coldStartupObservationServer = #"""
import json
import os
import sys
import time

stages = {}
trace_path = os.environ["TRACE"]
log_path = os.environ["LOG"]

def publish(error=None):
    snapshot = {"stages": stages, "error": error}
    temporary = trace_path + ".tmp"
    with open(temporary, "w") as trace:
        json.dump(snapshot, trace)
    os.replace(temporary, trace_path)

def mark(stage):
    stages[stage] = time.monotonic_ns()
    publish()

def respond(request, payload):
    print(json.dumps({"jsonrpc": "2.0", "id": request["id"], **payload}), flush=True)

try:
    hold = float(os.environ.get("INITIALIZE_HOLD_SECONDS", "0"))
    entry_hold = float(os.environ.get("FIXTURE_ENTRY_HOLD_SECONDS", "0"))
    if hold < 0 or hold >= 8 or (hold > 0 and "RELEASE" not in os.environ):
        raise ValueError("invalid controlled initialization gate")
    if not 0 <= entry_hold < 8 or (entry_hold > 0 and hold > 0):
        raise ValueError("invalid or stacked fixture-entry hold")
    if entry_hold > 0:
        mark("entryHoldStarted")
        while True:
            elapsed = (time.monotonic_ns() - stages["entryHoldStarted"]) / 1_000_000_000
            if elapsed >= 8:
                raise TimeoutError("fixture-entry hold exceeded unchanged 8s budget")
            if elapsed >= entry_hold:
                break
            time.sleep(0.005)
    mark("fixtureEntry")  # Before the first stdin read, unlike the shared fixture.
    for line in sys.stdin:
        request = json.loads(line)
        method = request["method"]
        with open(log_path, "a") as log:
            log.write(method + "\n")  # Close before the corresponding response.
        if method == "initialize":
            mark("initializeReceived")
            received = stages["initializeReceived"]
            while hold > 0:
                elapsed = (time.monotonic_ns() - received) / 1_000_000_000
                if elapsed >= 8:
                    raise TimeoutError("initialization gate exceeded unchanged 8s budget")
                if elapsed >= hold and os.path.exists(os.environ["RELEASE"]):
                    break
                time.sleep(0.005)
            respond(request, {"result": {"userAgent": "fake", "codexHome": "/tmp", "platformFamily": "unix", "platformOs": "macos"}})
            mark("initializeResponseFlushed")
        elif method == "test/barrier":
            mark("barrierReceived")
            if os.environ.get("BARRIER_ERROR") == "1":
                respond(request, {"error": {"code": -32077, "message": "cold-start observation barrier error"}})
            else:
                respond(request, {"result": {"value": method}})
            mark("barrierResponseFlushed")
        elif method != "initialized":
            raise ValueError("unexpected method: " + method)
except Exception as error:
    print("cold-start fixture: " + repr(error), file=sys.stderr, flush=True)
    try:
        publish(repr(error))
    except Exception as trace_error:
        print("cold-start trace failure: " + repr(trace_error), file=sys.stderr, flush=True)
    sys.exit(1)
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

    /// Closes the OS stdout descriptor while still running, then exits 7 shortly
    /// afterwards, so EOF is observed before reaping rather than only when the reaper loses.
    private static let stdoutClosingServer = #"""
import json
import os
import sys
import time

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
    sys.stdout.flush()
    os.close(1)
    time.sleep(0.15)
    raise SystemExit(7)
write({"id":request["id"], "result":{"value":request["method"]}})
"""#

    private static let delayedResponseServer = #"""
import json, sys, time

def read():
    line = sys.stdin.readline()
    if not line:
        sys.exit(0)
    return json.loads(line)

def write(value):
    print(json.dumps(value), flush=True)

initialize = read()
time.sleep(0.05)
write({"id": initialize["id"], "result": {
    "userAgent": "fake",
    "codexHome": "/tmp",
    "platformFamily": "unix",
    "platformOs": "macos"
}})
assert read()["method"] == "initialized"
request = read()
time.sleep(0.05)
write({"id": request["id"], "result": {"value": request["method"]}})
"""#

    private static let fakeServer = #"""
import json
import os
import sys

assert sys.argv[1:] == ["app-server", "--listen", "stdio://", "-c", "model_provider=openai"]
assert os.environ.get("CODEX_HOME") == "/tmp/langtools-test-codex-home"
assert os.environ.get("CODEX_INTERNAL_APP_SERVER_REMOTE_CONTROL_DISABLED") == "1"
assert os.environ.get("SECRET_API_KEY") is None
assert os.environ.get("LANGTOOLS_CODEX_HOME") == "/tmp/langtools-test-codex-home"

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

    // MARK: - Environment scrubbing

    func testSensitiveEnvironmentKeyDeniesExactMatches() {
        XCTAssertTrue(CodexAppServerClient.isSensitiveEnvironmentKey("SECRET_API_KEY"))
        XCTAssertTrue(CodexAppServerClient.isSensitiveEnvironmentKey("OPENAI_API_KEY"))
        XCTAssertTrue(CodexAppServerClient.isSensitiveEnvironmentKey("GITHUB_TOKEN"))
        XCTAssertTrue(CodexAppServerClient.isSensitiveEnvironmentKey("SSH_AUTH_SOCK"))
    }

    func testSensitiveEnvironmentKeyDeniesSubstringMatches() {
        XCTAssertTrue(CodexAppServerClient.isSensitiveEnvironmentKey("MY_SECRET"))
        XCTAssertTrue(CodexAppServerClient.isSensitiveEnvironmentKey("DATABASE_PASSWORD"))
        XCTAssertTrue(CodexAppServerClient.isSensitiveEnvironmentKey("CREDENTIAL_DIR"))
        XCTAssertTrue(CodexAppServerClient.isSensitiveEnvironmentKey("GCP_PRIVATE_KEY_FILE"))
        XCTAssertTrue(CodexAppServerClient.isSensitiveEnvironmentKey("VERBOSE_API_KEY_DEBUG"))
    }

    func testSensitiveEnvironmentKeyAllowsPassthrough() {
        // Load-bearing: the runtime depends on these through the denylist.
        XCTAssertFalse(CodexAppServerClient.isSensitiveEnvironmentKey("LANGTOOLS_CODEX_HOME"))
        XCTAssertFalse(CodexAppServerClient.isSensitiveEnvironmentKey("CODEX_CONFIG_PATH"))
        XCTAssertFalse(CodexAppServerClient.isSensitiveEnvironmentKey("CODEX_LOG_LEVEL"))
    }

    func testSensitiveEnvironmentKeyKnownConservativeMatches() {
        // The substring heuristic is intentionally aggressive. These
        // variables are harmless but match via substring; documenting
        // that they are dropped to prevent accidental secret leakage.
        XCTAssertTrue(CodexAppServerClient.isSensitiveEnvironmentKey("PASSWORD_MANAGER_VERSION"))
        XCTAssertTrue(CodexAppServerClient.isSensitiveEnvironmentKey("API_KEY_BACKUP_DIR"))
        XCTAssertTrue(CodexAppServerClient.isSensitiveEnvironmentKey("TOKEN_EXPIRY_SECONDS"))
        XCTAssertTrue(CodexAppServerClient.isSensitiveEnvironmentKey("ALL_TOKENS_CACHE"))
    }

    func testSensitiveEnvironmentKeyIsCaseInsensitive() {
        XCTAssertTrue(CodexAppServerClient.isSensitiveEnvironmentKey("secret_api_key"))
        XCTAssertTrue(CodexAppServerClient.isSensitiveEnvironmentKey("My_Token"))
        XCTAssertFalse(CodexAppServerClient.isSensitiveEnvironmentKey("codex_home"))
    }
}

private final class TimeoutRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var durations: [String: Duration] = [:]

    func record(method: String, duration: Duration) {
        lock.withLock { durations[method] = duration }
    }

    func duration(for method: String) -> Duration? {
        lock.withLock { durations[method] }
    }
}

private final class Pass4Observation: @unchecked Sendable {
    private struct FixtureEvent: Decodable {
        let stage: String
        let pid: Int32
        let launch: Int
        let monotonicNanoseconds: UInt64
        let message: String?
    }
    private struct HostEvent: Encodable {
        let stage: String
        let elapsed: String
        let detail: String
    }
    private struct KnownChild {
        let generation: UUID
        let launch: Int
        let pid: Int32
    }
    private let origin = ContinuousClock.now
    private let lock = NSLock()
    private var events: [HostEvent] = []
    private var instants: [String: ContinuousClock.Instant] = [:]
    private var resolutions = 0
    private var children: [KnownChild] = []
    let directory: URL
    var scriptURL: URL { directory.appendingPathComponent("fixture.py") }
    var traceURL: URL { directory.appendingPathComponent("fixture.ndjson") }
    var countURL: URL { directory.appendingPathComponent("count") }
    var launchCount: Int { lock.withLock { resolutions } }

    init() throws {
        let root = ProcessInfo.processInfo.environment["PR77_TEST_EVIDENCE"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        directory = root.appendingPathComponent("pass4-timer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        mark("host/origin", detail: "ContinuousClock origin; fixture nanoseconds are independently relative to each PID's fixture-entry origin")
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "PR77Pass4Observation", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    func mark(_ stage: String, detail: String = "") {
        let now = ContinuousClock.now
        lock.withLock {
            instants[stage] = now
            events.append(HostEvent(stage: stage, elapsed: String(describing: origin.duration(to: now)), detail: detail))
        }
    }

    func instant(_ stage: String) -> ContinuousClock.Instant? { lock.withLock { instants[stage] } }

    func resolve() {
        let count = lock.withLock { resolutions += 1; return resolutions }
        mark("resolver/\(count)")
    }

    private func fixtureEvents() throws -> [FixtureEvent] {
        let data = try Data(contentsOf: traceURL)
        // An append may be visible before its terminating newline. Decode only
        // committed records; bounded callers retry for the record they need.
        guard let newline = data.lastIndex(of: 10) else { return [] }
        return try data[..<newline].split(separator: 10).map {
            try JSONDecoder().decode(FixtureEvent.self, from: Data($0))
        }
    }

    func generation(_ client: CodexAppServerClient) async throws -> UUID {
        mark("generation/getter-begin")
        let generation = try await client.initializedProcessGeneration()
        let launch = launchCount
        let entry = try await waitForFixtureEntry(launch: launch)
        lock.withLock {
            if !children.contains(where: { $0.generation == generation }) {
                children.append(KnownChild(generation: generation, launch: launch, pid: entry.pid))
            }
        }
        mark("generation/known", detail: "launch=\(launch) PID=\(entry.pid) UUID=\(generation)")
        return generation
    }

    private func waitForFixtureEntry(launch: Int) async throws -> FixtureEvent {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if let entry = try fixtureEvents().first(where: { $0.launch == launch && $0.stage == "fixtureEntry" }) {
                return entry
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw Self.failure("Missing complete fixture entry for launch \(launch) within 2s")
    }

    func waitForExitIntent(launch: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if try fixtureEvents().contains(where: { $0.launch == launch && $0.stage == "exitIntent" }) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw Self.failure("Missing finite exit intent for launch \(launch)")
    }

    private static func isAlive(_ pid: Int32) throws -> Bool {
        if kill(pid, 0) == 0 { return true }
        guard errno == ESRCH else { throw failure("Cannot observe PID \(pid), errno \(errno)") }
        return false
    }

    func waitForChildExit(launch: Int) async throws {
        let child = try XCTUnwrap(lock.withLock { children.first { $0.launch == launch } })
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while try Self.isAlive(child.pid) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        guard try !Self.isAlive(child.pid) else { throw Self.failure("Finite child PID \(child.pid) still alive") }
        mark("finite/child-exited", detail: "launch=\(launch) PID=\(child.pid) UUID=\(child.generation)")
    }

    func snapshot(stage: String, primaryError: Error?) throws {
        mark(stage, detail: primaryError.map { String(reflecting: $0) } ?? "body-completed")
        let host = try JSONEncoder().encode(lock.withLock { events })
        try host.write(to: directory.appendingPathComponent("\(stage)-host.json"))
        if FileManager.default.fileExists(atPath: traceURL.path) {
            try Data(contentsOf: traceURL).write(to: directory.appendingPathComponent("\(stage)-fixture.ndjson"))
        } else {
            try Data("fixture trace missing\n".utf8).write(to: directory.appendingPathComponent("\(stage)-fixture-missing.txt"))
        }
        print("PASS4 \(stage) scratch=\(directory.path) primary=\(primaryError.map { String(reflecting: $0) } ?? "body-completed") launches=\(launchCount)")
    }

    func cleanup(_ client: CodexAppServerClient) async -> Error? {
        // Await a cancellation-independent supervisor. A cancelled test still
        // observes the real cleanup deadline and actual PID disappearance,
        // preserving its primary CancellationError even if cleanup fails.
        let supervisor = Task.detached { await self.superviseCleanup(client) }
        return await supervisor.value
    }

    private func superviseCleanup(_ client: CodexAppServerClient) async -> Error? {
        // Separate absolute cleanup budget, never the primary request clock.
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        let known = lock.withLock { children }
        let completed = ThreadSafeCounter()
        // Start shutdown independently of observation-task completion. Neither
        // this task's completion nor shutdown alone proves the child has exited.
        let invalidating = Task.detached {
            self.mark("cleanup/shutdown-begin")
            await client.shutdown()
            self.mark("cleanup/shutdown-returned")
            for child in known {
                self.mark("cleanup/invalidate-begin", detail: "launch=\(child.launch) PID=\(child.pid) UUID=\(child.generation)")
                await client.invalidateProcessAndWait(expectedGeneration: child.generation)
                self.mark("cleanup/invalidate-returned", detail: "launch=\(child.launch) PID=\(child.pid) UUID=\(child.generation)")
            }
            self.mark("cleanup/invalidation-completed")
            completed.increment()
        }
        while completed.value == 0 && ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(5)) }
            catch { mark("cleanup/observer-cancelled", detail: String(reflecting: error)); break }
        }
        guard completed.value == 1 else {
            invalidating.cancel()
            return Self.failure("Cleanup exceeded separate 3s budget; shutdown/invalidation incomplete and child exit unconfirmed, scratch retained")
        }
        guard let completion = instant("cleanup/invalidation-completed"), completion <= deadline else {
            return Self.failure("Cleanup invalidation completed after the separate 3s deadline; child exit unconfirmed, scratch retained")
        }
        guard Set(known.map(\.launch)).count == launchCount else {
            return Self.failure("Unknown generation: \(launchCount) launches but \(known.count) known children; no new generation getter in teardown")
        }
        do {
            for child in known {
                while try Self.isAlive(child.pid) && ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(5))
                }
                guard try !Self.isAlive(child.pid) else { throw Self.failure("Cleanup failed within separate 3s budget: PID \(child.pid) still observable; scratch retained") }
                mark("cleanup/actual-child-absent", detail: "launch=\(child.launch) PID=\(child.pid) UUID=\(child.generation)")
                guard ContinuousClock.now <= deadline else {
                    throw Self.failure("Child disappearance observed after separate 3s cleanup deadline")
                }
            }
        } catch { return error }
        return nil
    }
}

private final class ThreadSafeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int { lock.withLock { storedValue } }

    func increment() {
        lock.withLock { storedValue += 1 }
    }
}
