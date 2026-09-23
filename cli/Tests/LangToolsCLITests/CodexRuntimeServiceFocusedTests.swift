#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import XCTest
@testable import CLI

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

    func testLogoutPromptlyCancelsUnresponsiveAccountReadBeforeItsOwnRequests() async throws {
        let started = temporaryURL(suffix: ".started")
        let log = temporaryURL(suffix: ".jsonl")
        let scriptURL = try makePythonScript(Self.loginBeforeStartDrainServer)
        defer {
            for url in [started, log, scriptURL] { try? FileManager.default.removeItem(at: url) }
        }
        let client = makeClient(scriptURL: scriptURL, environment: [
            "STARTED": started.path, "LOG": log.path
        ])
        let runtime = CodexRuntimeService(client: client, browserOpener: { _ in
            XCTFail("Stale login must not open a browser")
        })
        let login = Task { try await runtime.login() }
        try await waitForFile(at: started)
        let clock = ContinuousClock()
        let beganLogout = clock.now
        try await runtime.logout()
        XCTAssertLessThan(beganLogout.duration(to: clock.now), .seconds(1))

        do {
            _ = try await login.value
            XCTFail("Expected invalidated login cancellation")
        } catch is CancellationError {
            // Expected.
        }
        let methods = try readJSONLines(log).compactMap { $0["method"] as? String }
        XCTAssertEqual(methods.filter { $0 == "account/read" }.count, 2)
        XCTAssertFalse(methods.contains("account/login/start"))
        await runtime.shutdown()
    }

    func testDirectLoginCancellationRacesDelayedStartResponseAndRestartsUnknownGeneration() async throws {
        let started = temporaryURL(suffix: ".started")
        let release = temporaryURL(suffix: ".release")
        let processCount = temporaryURL(suffix: ".process-count")
        let log = temporaryURL(suffix: ".jsonl")
        let scriptURL = try makePythonScript(Self.unidentifiedLoginDrainServer)
        defer {
            for url in [started, release, processCount, log, scriptURL] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let client = makeClient(scriptURL: scriptURL, environment: [
            "STARTED": started.path,
            "RELEASE_LOGIN_START": release.path,
            "PROCESS_COUNT": processCount.path,
            "LOG": log.path
        ])
        let responseCheckpoint = AsyncCheckpoint()
        let runtime = CodexRuntimeService(
            client: client,
            browserOpener: { _ in
                XCTFail("A cancelled login without an ID must not open a browser")
            },
            loginStartResponseCheckpoint: {
                await responseCheckpoint.reachAndWait()
            }
        )
        let login = Task { try await runtime.login() }
        try await waitForFile(at: started)

        try Data().write(to: release)
        await responseCheckpoint.waitUntilReached()
        login.cancel()
        await responseCheckpoint.release()
        do {
            _ = try await login.value
            XCTFail("Expected direct login cancellation")
        } catch is CancellationError {
            // Expected.
        }

        let status = try await runtime.accountStatus()
        XCTAssertFalse(status.authenticated)
        let records = try readJSONLines(log)
        XCTAssertEqual(records.compactMap { $0["generationStarted"] as? Int }, [1, 2])
        try await assertProcessExited(try XCTUnwrap(records.first?["pid"] as? Int32))
        XCTAssertEqual(
            records.compactMap { $0["method"] as? String },
            ["account/read", "account/login/start", "account/read"]
        )
        XCTAssertFalse(records.contains { $0["method"] as? String == "account/login/cancel" })
        XCTAssertEqual(try String(contentsOf: processCount, encoding: .utf8), "2")
        await runtime.shutdown()
    }

    func testDirectLoginStartTimeoutRestartsUnknownLoginGeneration() async throws {
        let started = temporaryURL(suffix: ".started")
        let processCount = temporaryURL(suffix: ".process-count")
        let log = temporaryURL(suffix: ".jsonl")
        let scriptURL = try makePythonScript(Self.unidentifiedLoginDrainServer)
        defer {
            for url in [started, processCount, log, scriptURL] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let timeoutCheckpoint = AsyncCheckpoint()
        let client = makeClient(
            scriptURL: scriptURL,
            environment: [
                "STARTED": started.path,
                "PROCESS_COUNT": processCount.path,
                "LOG": log.path
            ],
            requestTimeoutSleeper: { method, duration in
                guard method == "account/login/start" else {
                    try await Task.sleep(for: duration)
                    return
                }
                await timeoutCheckpoint.reachAndWait()
                try Task.checkCancellation()
            }
        )
        let runtime = CodexRuntimeService(client: client, browserOpener: { _ in
            XCTFail("A timed-out login without an ID must not open a browser")
        })

        let login = Task { try await runtime.login() }
        try await waitForFile(at: started)
        await timeoutCheckpoint.waitUntilReached()
        await timeoutCheckpoint.release()
        do {
            _ = try await login.value
            XCTFail("Expected account/login/start timeout")
        } catch let error as CodexAppServerError {
            guard case .timeout(let method) = error else {
                return XCTFail("Expected timeout, got \(error)")
            }
            XCTAssertEqual(method, "account/login/start")
        }

        let status = try await runtime.accountStatus()
        XCTAssertFalse(status.authenticated)
        let records = try readJSONLines(log)
        XCTAssertEqual(records.compactMap { $0["generationStarted"] as? Int }, [1, 2])
        try await assertProcessExited(try XCTUnwrap(records.first?["pid"] as? Int32))
        XCTAssertEqual(
            records.compactMap { $0["method"] as? String },
            ["account/read", "account/login/start", "account/read"]
        )
        XCTAssertFalse(records.contains { $0["method"] as? String == "account/login/cancel" })
        XCTAssertEqual(try String(contentsOf: processCount, encoding: .utf8), "2")
        await runtime.shutdown()
    }

    func testLogoutWaitsForDirectUnknownLoginCleanupWithoutDoubleRestart() async throws {
        let started = temporaryURL(suffix: ".started")
        let restartBlocked = temporaryURL(suffix: ".restart-blocked")
        let release = temporaryURL(suffix: ".release")
        let processCount = temporaryURL(suffix: ".process-count")
        let log = temporaryURL(suffix: ".jsonl")
        let scriptURL = try makePythonScript(Self.blockedUnknownLoginRestartServer)
        defer {
            for url in [started, restartBlocked, release, processCount, log, scriptURL] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let client = makeClient(scriptURL: scriptURL, environment: [
            "STARTED": started.path,
            "RESTART_BLOCKED": restartBlocked.path,
            "RELEASE": release.path,
            "PROCESS_COUNT": processCount.path,
            "LOG": log.path
        ])
        let runtime = CodexRuntimeService(client: client, browserOpener: { _ in
            XCTFail("An unknown-ID login must not open a browser")
        })
        let login = Task { try await runtime.login() }
        try await waitForFile(at: started)
        login.cancel()
        try await waitForFile(at: restartBlocked)

        let logout = Task { try await runtime.logout() }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(try String(contentsOf: processCount, encoding: .utf8), "2")
        try Data().write(to: release)

        do {
            _ = try await login.value
            XCTFail("Expected direct login cancellation")
        } catch is CancellationError {
            // Expected.
        }
        try await logout.value
        let status = try await runtime.accountStatus()
        XCTAssertFalse(status.authenticated)

        let records = try readJSONLines(log)
        XCTAssertEqual(records.compactMap { $0["generationStarted"] as? Int }, [1, 2])
        XCTAssertFalse(records.contains { $0["method"] as? String == "account/login/cancel" })
        XCTAssertEqual(try String(contentsOf: processCount, encoding: .utf8), "2")
        await runtime.shutdown()
    }

    func testLogoutRestartsAfterLoginStartMayExistWithoutKnownID() async throws {
        let started = temporaryURL(suffix: ".started")
        let processCount = temporaryURL(suffix: ".process-count")
        let log = temporaryURL(suffix: ".jsonl")
        let scriptURL = try makePythonScript(Self.unidentifiedLoginDrainServer)
        defer {
            for url in [started, processCount, log, scriptURL] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let client = makeClient(scriptURL: scriptURL, environment: [
            "STARTED": started.path,
            "PROCESS_COUNT": processCount.path,
            "LOG": log.path
        ])
        let runtime = CodexRuntimeService(client: client, browserOpener: { _ in
            XCTFail("A login invalidated before its response must not open a browser")
        })
        let login = Task { try await runtime.login() }
        try await waitForFile(at: started)

        let clock = ContinuousClock()
        let beganLogout = clock.now
        try await runtime.logout()
        XCTAssertLessThan(beganLogout.duration(to: clock.now), .seconds(1))

        do {
            _ = try await login.value
            XCTFail("Expected the unidentified login operation to be cancelled")
        } catch is CancellationError {
            // Expected.
        }
        let records = try readJSONLines(log)
        let generations = records.compactMap { $0["generationStarted"] as? Int }
        XCTAssertEqual(generations, [1, 2])
        let requests = records.filter { $0["method"] is String }
        XCTAssertEqual(
            requests.compactMap { $0["method"] as? String },
            ["account/read", "account/login/start", "account/read"]
        )
        XCTAssertEqual(requests.compactMap { $0["generation"] as? Int }, [1, 1, 2])
        XCTAssertFalse(requests.contains { $0["method"] as? String == "account/login/cancel" })
        XCTAssertEqual(try String(contentsOf: processCount, encoding: .utf8), "2")
        await runtime.shutdown()
    }

    func testLogoutPromptlyUnblocksAccountReadWaitingForHangingInitialization() async throws {
        let started = temporaryURL(suffix: ".started")
        let scriptURL = try makePythonScript(Self.hangingInitializationServer)
        defer {
            for url in [started, scriptURL] { try? FileManager.default.removeItem(at: url) }
        }
        let client = makeClient(scriptURL: scriptURL, environment: ["STARTED": started.path])
        let runtime = CodexRuntimeService(client: client, browserOpener: { _ in })
        let account = Task { try await runtime.accountStatus() }
        try await waitForFile(at: started)
        let accountCancelled = expectation(description: "account startup waiter cancelled")
        let accountResult = Task {
            let result = await account.result
            accountCancelled.fulfill()
            return result
        }

        let logout = Task { try await runtime.logout() }
        await fulfillment(of: [accountCancelled], timeout: 0.5)
        switch await accountResult.value {
        case .failure(let error as CancellationError):
            _ = error
        default:
            XCTFail("Expected account/read startup waiter cancellation")
        }

        logout.cancel()
        _ = await logout.result
        await client.shutdown()
    }

    func testLogoutCancelsLoginThatAlreadyStartedBeforeCompletingDrain() async throws {
        let cancelled = temporaryURL(suffix: ".cancelled")
        let log = temporaryURL(suffix: ".jsonl")
        let scriptURL = try makePythonScript(Self.startedLoginDrainServer)
        defer {
            for url in [cancelled, log, scriptURL] { try? FileManager.default.removeItem(at: url) }
        }
        let browserOpened = expectation(description: "browser opened")
        let client = makeClient(scriptURL: scriptURL, environment: [
            "CANCELLED": cancelled.path, "LOG": log.path
        ])
        let runtime = CodexRuntimeService(client: client, browserOpener: { _ in browserOpened.fulfill() })
        let login = Task { try await runtime.login() }
        await fulfillment(of: [browserOpened], timeout: 1)

        try await runtime.logout()
        do {
            _ = try await login.value
            XCTFail("Expected started login cancellation")
        } catch is CancellationError {
            // Expected.
        }
        try await waitForFile(at: cancelled)
        let requests = try readJSONLines(log)
        let methods = requests.compactMap { $0["method"] as? String }
        XCTAssertEqual(methods.filter { $0 == "account/login/start" }.count, 1)
        let cancellations = requests.filter { $0["method"] as? String == "account/login/cancel" }
        XCTAssertEqual(cancellations.count, 1)
        XCTAssertEqual((cancellations.first?["params"] as? [String: String])?["loginId"], "login-race")
        await runtime.shutdown()
    }

    func testShutdownPromptlyCancelsUnresponsiveModelPageWithoutContinuationOrRestart() async throws {
        let started = temporaryURL(suffix: ".started")
        let processCount = temporaryURL(suffix: ".process-count")
        let log = temporaryURL(suffix: ".jsonl")
        let scriptURL = try makePythonScript(Self.modelShutdownDrainServer)
        defer {
            for url in [started, processCount, log, scriptURL] { try? FileManager.default.removeItem(at: url) }
        }
        let client = makeClient(scriptURL: scriptURL, environment: [
            "STARTED": started.path, "PROCESS_COUNT": processCount.path, "LOG": log.path
        ])
        let runtime = CodexRuntimeService(client: client, browserOpener: { _ in })
        let models = Task { try await runtime.modelSlugs() }
        try await waitForFile(at: started)
        let clock = ContinuousClock()
        let beganShutdown = clock.now
        await runtime.shutdown()
        XCTAssertLessThan(beganShutdown.duration(to: clock.now), .seconds(1))

        do {
            _ = try await models.value
            XCTFail("Expected model operation cancellation")
        } catch is CancellationError {
            // Expected.
        }
        let methods = try readJSONLines(log).compactMap { $0["method"] as? String }
        XCTAssertEqual(methods.filter { $0 == "model/list" }.count, 1)
        XCTAssertEqual(try String(contentsOf: processCount, encoding: .utf8), "1")
        do {
            _ = try await runtime.modelSlugs()
            XCTFail("Expected shutdown runtime to reject new model operations")
        } catch let error as CodexRuntimeError {
            guard case .accountConflict = error else { return XCTFail("Expected shutdown conflict, got \(error)") }
        }
    }

    func testShutdownPromptlyCancelsModelListWaitingForHangingInitialization() async throws {
        let started = temporaryURL(suffix: ".started")
        let scriptURL = try makePythonScript(Self.hangingInitializationServer)
        defer {
            for url in [started, scriptURL] { try? FileManager.default.removeItem(at: url) }
        }
        let client = makeClient(scriptURL: scriptURL, environment: ["STARTED": started.path])
        let runtime = CodexRuntimeService(client: client, browserOpener: { _ in })
        let models = Task { try await runtime.modelSlugs() }
        try await waitForFile(at: started)

        let clock = ContinuousClock()
        let beganShutdown = clock.now
        await runtime.shutdown()
        XCTAssertLessThan(beganShutdown.duration(to: clock.now), .seconds(1))
        do {
            _ = try await models.value
            XCTFail("Expected model/list startup waiter cancellation")
        } catch is CancellationError {
            // Expected.
        }
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

    func testTurnStartTimeoutRestartsUnknownTurnGenerationAndNextLifecycleIsClean() async throws {
        let startedURL = temporaryURL(suffix: ".started")
        let processCountURL = temporaryURL(suffix: ".process-count")
        let logURL = temporaryURL(suffix: ".jsonl")
        let scriptURL = try makePythonScript(Self.delayedUnknownTurnTimeoutServer)
        defer {
            for url in [startedURL, processCountURL, logURL, scriptURL] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let timeoutGate = OneShotTurnStartTimeout(markerURL: startedURL)
        let client = makeClient(
            scriptURL: scriptURL,
            environment: [
                "STARTED": startedURL.path,
                "PROCESS_COUNT": processCountURL.path,
                "LOG": logURL.path
            ],
            requestTimeoutSleeper: { method, duration in
                try await timeoutGate.sleep(method: method, duration: duration)
            }
        )
        let runtime = CodexRuntimeService(client: client, browserOpener: { _ in })
        let conversationID = UUID()

        do {
            _ = try await runtime.chat(
                model: "codex-test",
                messages: [.init(role: "user", content: "first")],
                conversationID: conversationID
            )
            XCTFail("Expected turn/start timeout")
        } catch let error as CodexAppServerError {
            guard case .timeout(let method) = error else { return XCTFail("Expected timeout, got \(error)") }
            XCTAssertEqual(method, "turn/start")
        }

        for _ in 0..<100 where (try? String(contentsOf: processCountURL, encoding: .utf8)) != "2" {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(try String(contentsOf: processCountURL, encoding: .utf8), "2")
        let firstPID = try XCTUnwrap(readJSONLines(logURL).first?["pid"] as? Int32)
        try await assertProcessExited(firstPID)
        let recovered = try await runtime.chat(
            model: "codex-test",
            messages: [.init(role: "user", content: "second")],
            conversationID: conversationID
        )
        XCTAssertEqual(recovered, "recovered")
        XCTAssertEqual(try readJSONLines(logURL).count, 2)
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

    func testConversationReuseSuffixIsolationOneShotAndCleanup() async throws {
        let logURL = temporaryURL(suffix: ".jsonl")
        let scriptURL = try makePythonScript(Self.conversationServer)
        let cacheRoot = temporaryURL(suffix: ".cache")
        defer {
            try? FileManager.default.removeItem(at: logURL)
            try? FileManager.default.removeItem(at: scriptURL)
            try? FileManager.default.removeItem(at: cacheRoot)
        }
        let client = makeClient(scriptURL: scriptURL, environment: ["LOG": logURL.path])
        let workspaces = CodexConversationWorkspace(cacheRoot: cacheRoot)
        let runtime = CodexRuntimeService(client: client, browserOpener: { _ in }, workspaces: workspaces)
        let firstID = UUID()
        let secondID = UUID()

        let firstMessages = [HelperChatMessage(role: "user", content: "first input")]
        let firstResponse = try await runtime.chat(model: "model-a", messages: firstMessages, conversationID: firstID)
        let secondMessages = firstMessages + [
            HelperChatMessage(role: "assistant", content: firstResponse),
            HelperChatMessage(role: "user", content: "strict suffix")
        ]
        _ = try await runtime.chat(model: "model-a", messages: secondMessages, conversationID: firstID)
        _ = try await runtime.chat(
            model: "model-a",
            messages: [.init(role: "user", content: "separate conversation")],
            conversationID: secondID
        )
        _ = try await runtime.chat(model: "model-a", messages: [.init(role: "user", content: "one shot")])

        let records = try readJSONLines(logURL)
        let threadParams = records.filter { $0["method"] as? String == "thread/start" }.compactMap { $0["params"] as? [String: Any] }
        let turnParams = records.filter { $0["method"] as? String == "turn/start" }.compactMap { $0["params"] as? [String: Any] }
        XCTAssertEqual(threadParams.count, 3)
        XCTAssertEqual(turnParams.count, 4)
        let firstWorkspace = try XCTUnwrap(threadParams[0]["cwd"] as? String)
        XCTAssertNil(threadParams[0]["runtimeWorkspaceRoots"])
        XCTAssertNotEqual(firstWorkspace, threadParams[1]["cwd"] as? String)
        XCTAssertNil(turnParams[0]["runtimeWorkspaceRoots"])
        XCTAssertNil(turnParams[0]["dynamicTools"])
        XCTAssertTrue((turnParams[1]["input"] as? [[String: Any]])?.first?["text"].flatMap { $0 as? String }?.contains("strict suffix") == true)
        XCTAssertFalse((turnParams[1]["input"] as? [[String: Any]])?.first?["text"].flatMap { $0 as? String }?.contains("first input") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstWorkspace))
        let permissions = try XCTUnwrap((try FileManager.default.attributesOfItem(atPath: firstWorkspace)[.posixPermissions] as? NSNumber)?.intValue)
        XCTAssertEqual(permissions & 0o777, 0o700)
        let oneShotWorkspace = try XCTUnwrap(threadParams.last?["cwd"] as? String)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oneShotWorkspace))

        await runtime.endConversation(id: firstID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstWorkspace))
        await runtime.endConversation(id: firstID)
        let secondWorkspace = try XCTUnwrap(threadParams[1]["cwd"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondWorkspace))
        await runtime.shutdown()
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondWorkspace))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspaces.processRoot.path))
    }

    func testModelTranscriptAndProcessChangesReconstructInSameWorkspace() async throws {
        let logURL = temporaryURL(suffix: ".jsonl")
        let scriptURL = try makePythonScript(Self.conversationServer)
        let cacheRoot = temporaryURL(suffix: ".cache")
        defer {
            try? FileManager.default.removeItem(at: logURL)
            try? FileManager.default.removeItem(at: scriptURL)
            try? FileManager.default.removeItem(at: cacheRoot)
        }
        let client = makeClient(scriptURL: scriptURL, environment: ["LOG": logURL.path])
        let runtime = CodexRuntimeService(
            client: client,
            browserOpener: { _ in },
            workspaces: CodexConversationWorkspace(cacheRoot: cacheRoot)
        )
        let id = UUID()
        var transcript = [HelperChatMessage(role: "user", content: "original")]
        let first = try await runtime.chat(model: "model-a", messages: transcript, conversationID: id)
        transcript += [.init(role: "assistant", content: first), .init(role: "user", content: "model changed")]
        let second = try await runtime.chat(model: "model-b", messages: transcript, conversationID: id)
        transcript = [.init(role: "user", content: "edited history"), .init(role: "assistant", content: second), .init(role: "user", content: "continue")]
        let third = try await runtime.chat(model: "model-b", messages: transcript, conversationID: id)
        transcript += [.init(role: "assistant", content: third), .init(role: "user", content: "after restart")]
        try await client.restart()
        _ = try await runtime.chat(model: "model-b", messages: transcript, conversationID: id)

        let threads = try readJSONLines(logURL)
            .filter { $0["method"] as? String == "thread/start" }
            .compactMap { ($0["params"] as? [String: Any])?["cwd"] as? String }
        XCTAssertEqual(threads.count, 4)
        XCTAssertEqual(Set(threads).count, 1)
        await runtime.shutdown()
    }

    func testIdleExpiryAndConcurrentTurnConflict() async throws {
        let logURL = temporaryURL(suffix: ".jsonl")
        let startedURL = temporaryURL(suffix: ".started")
        let script = Self.conversationServer.replacingOccurrences(
            of: "# DELAY_TURN",
            with: "open(os.environ['STARTED'], 'w').write('started'); time.sleep(0.15)"
        )
        let scriptURL = try makePythonScript(script)
        let cacheRoot = temporaryURL(suffix: ".cache")
        defer {
            try? FileManager.default.removeItem(at: logURL)
            try? FileManager.default.removeItem(at: startedURL)
            try? FileManager.default.removeItem(at: scriptURL)
            try? FileManager.default.removeItem(at: cacheRoot)
        }
        let client = makeClient(scriptURL: scriptURL, environment: ["LOG": logURL.path, "STARTED": startedURL.path])
        let runtime = CodexRuntimeService(
            client: client,
            browserOpener: { _ in },
            conversationIdleTimeout: .milliseconds(40),
            workspaces: CodexConversationWorkspace(cacheRoot: cacheRoot)
        )
        let id = UUID()
        let first = Task { try await runtime.chat(model: "model", messages: [.init(role: "user", content: "slow")], conversationID: id) }
        try await waitForFile(at: startedURL)
        do {
            _ = try await runtime.chat(model: "model", messages: [.init(role: "user", content: "overlap")], conversationID: id)
            XCTFail("Expected same-conversation conflict")
        } catch let error as CodexRuntimeError {
            guard case .accountConflict = error else { return XCTFail("Expected conflict, got \(error)") }
        }
        _ = try await first.value
        let workspace = try XCTUnwrap(
            try readJSONLines(logURL).first { $0["method"] as? String == "thread/start" }?["params"] as? [String: Any]
        )["cwd"] as? String
        let workspacePath = try XCTUnwrap(workspace)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspacePath))
        await runtime.shutdown()
    }

    func testStaleThreadStartRetriesOnceWithFullTranscript() async throws {
        let logURL = temporaryURL(suffix: ".jsonl")
        let scriptURL = try makePythonScript(Self.staleThreadServer)
        let cacheRoot = temporaryURL(suffix: ".cache")
        defer {
            try? FileManager.default.removeItem(at: logURL)
            try? FileManager.default.removeItem(at: scriptURL)
            try? FileManager.default.removeItem(at: cacheRoot)
        }
        let client = makeClient(scriptURL: scriptURL, environment: ["LOG": logURL.path])
        let runtime = CodexRuntimeService(
            client: client,
            browserOpener: { _ in },
            workspaces: CodexConversationWorkspace(cacheRoot: cacheRoot)
        )
        let response = try await runtime.chat(
            model: "model",
            messages: [.init(role: "user", content: "full replay input")],
            conversationID: UUID()
        )
        XCTAssertEqual(response, "recovered")
        let records = try readJSONLines(logURL)
        XCTAssertEqual(records.filter { $0["method"] as? String == "thread/start" }.count, 2)
        let turns = records.filter { $0["method"] as? String == "turn/start" }
        XCTAssertEqual(turns.count, 2)
        let retryText = ((turns.last?["params"] as? [String: Any])?["input"] as? [[String: Any]])?.first?["text"] as? String
        XCTAssertTrue(retryText?.contains("full replay input") == true)
        await runtime.shutdown()
    }

    func testSuccessfulLogoutDeletesConversationWorkspace() async throws {
        let logURL = temporaryURL(suffix: ".jsonl")
        let scriptURL = try makePythonScript(Self.conversationServer)
        let cacheRoot = temporaryURL(suffix: ".cache")
        defer {
            try? FileManager.default.removeItem(at: logURL)
            try? FileManager.default.removeItem(at: scriptURL)
            try? FileManager.default.removeItem(at: cacheRoot)
        }
        let client = makeClient(scriptURL: scriptURL, environment: ["LOG": logURL.path])
        let runtime = CodexRuntimeService(
            client: client,
            browserOpener: { _ in },
            workspaces: CodexConversationWorkspace(cacheRoot: cacheRoot)
        )
        _ = try await runtime.chat(model: "model", messages: [.init(role: "user", content: "hello")], conversationID: UUID())
        let workspace = try XCTUnwrap(
            ((try readJSONLines(logURL).first { $0["method"] as? String == "thread/start" })?["params"] as? [String: Any])?["cwd"] as? String
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace))
        try await runtime.logout()
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace))
        await runtime.shutdown()
    }

    func testTerminationReservesConversationUntilDelayedTurnIsReturnedAndInterrupted() async throws {
        let started = temporaryURL(suffix: ".started")
        let release = temporaryURL(suffix: ".release")
        let interrupted = temporaryURL(suffix: ".interrupted")
        let scriptURL = try makePythonScript(Self.lifecycleRaceServer)
        let cacheRoot = temporaryURL(suffix: ".cache")
        defer {
            for url in [started, release, interrupted, scriptURL, cacheRoot] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let client = makeClient(scriptURL: scriptURL, environment: [
            "RACE_MODE": "turn", "STARTED": started.path,
            "RELEASE": release.path, "INTERRUPTED": interrupted.path
        ])
        let runtime = CodexRuntimeService(
            client: client,
            browserOpener: { _ in },
            workspaces: CodexConversationWorkspace(cacheRoot: cacheRoot)
        )
        let id = UUID()
        let oldChat = Task {
            try await runtime.chat(model: "model", messages: [.init(role: "user", content: "old")], conversationID: id)
        }
        try await waitForFile(at: started)
        let cleanup = Task { await runtime.endConversation(id: id) }
        try await Task.sleep(for: .milliseconds(30))

        do {
            _ = try await runtime.chat(model: "model", messages: [.init(role: "user", content: "too early")], conversationID: id)
            XCTFail("Expected terminating lifecycle to reserve the conversation ID")
        } catch let error as CodexRuntimeError {
            guard case .accountConflict = error else { return XCTFail("Expected lifecycle conflict, got \(error)") }
        }

        try Data().write(to: release)
        await cleanup.value
        do {
            _ = try await oldChat.value
            XCTFail("Expected the terminated chat to be cancelled")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(try String(contentsOf: interrupted, encoding: .utf8), "thread-1/turn-1")

        let replacement = try await runtime.chat(
            model: "model",
            messages: [.init(role: "user", content: "replacement")],
            conversationID: id
        )
        XCTAssertEqual(replacement, "response-2")
        await runtime.shutdown()
    }

    func testLogoutRejectsDifferentConversationWhileCleanupBlockedThenFullyDrainsAndReopens() async throws {
        let started = temporaryURL(suffix: ".started")
        let release = temporaryURL(suffix: ".release")
        let interrupted = temporaryURL(suffix: ".interrupted")
        let scriptURL = try makePythonScript(Self.lifecycleRaceServer)
        let cacheRoot = temporaryURL(suffix: ".cache")
        defer {
            for url in [started, release, interrupted, scriptURL, cacheRoot] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let client = makeClient(scriptURL: scriptURL, environment: [
            "RACE_MODE": "turn", "STARTED": started.path,
            "RELEASE": release.path, "INTERRUPTED": interrupted.path
        ])
        let runtime = CodexRuntimeService(
            client: client,
            browserOpener: { _ in },
            workspaces: CodexConversationWorkspace(cacheRoot: cacheRoot)
        )
        let activeChat = Task {
            try await runtime.chat(
                model: "model",
                messages: [.init(role: "user", content: "active")],
                conversationID: UUID()
            )
        }
        try await waitForFile(at: started)
        let logout = Task { try await runtime.logout() }
        try await Task.sleep(for: .milliseconds(30))

        do {
            _ = try await runtime.chat(
                model: "model",
                messages: [.init(role: "user", content: "different")],
                conversationID: UUID()
            )
            XCTFail("Expected service drain to reject a different conversation ID")
        } catch let error as CodexRuntimeError {
            guard case .accountConflict = error else { return XCTFail("Expected drain conflict, got \(error)") }
        }

        try Data().write(to: release)
        try await logout.value
        do {
            _ = try await activeChat.value
            XCTFail("Expected active chat cancellation during logout")
        } catch is CancellationError {
            // Expected.
        }
        let remainingConversations = try FileManager.default.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil)
            .flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
            .filter { $0.lastPathComponent.hasPrefix("conversation-") }
        XCTAssertTrue(remainingConversations.isEmpty)

        let reopened = try await runtime.chat(
            model: "model",
            messages: [.init(role: "user", content: "after logout")],
            conversationID: UUID()
        )
        XCTAssertEqual(reopened, "response-2")
        await runtime.shutdown()
        do {
            _ = try await runtime.chat(model: "model", messages: [.init(role: "user", content: "closed")])
            XCTFail("Expected shutdown runtime to stay closed")
        } catch let error as CodexRuntimeError {
            guard case .accountConflict = error else { return XCTFail("Expected shutdown conflict, got \(error)") }
        }
    }

    func testDelayedThreadStartContinuationCannotAffectReusedConversationID() async throws {
        let started = temporaryURL(suffix: ".started")
        let release = temporaryURL(suffix: ".release")
        let interrupted = temporaryURL(suffix: ".interrupted")
        let scriptURL = try makePythonScript(Self.lifecycleRaceServer)
        let cacheRoot = temporaryURL(suffix: ".cache")
        defer {
            for url in [started, release, interrupted, scriptURL, cacheRoot] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let client = makeClient(scriptURL: scriptURL, environment: [
            "RACE_MODE": "thread", "STARTED": started.path,
            "RELEASE": release.path, "INTERRUPTED": interrupted.path
        ])
        let runtime = CodexRuntimeService(
            client: client,
            browserOpener: { _ in },
            workspaces: CodexConversationWorkspace(cacheRoot: cacheRoot)
        )
        let id = UUID()
        let oldChat = Task {
            try await runtime.chat(model: "model", messages: [.init(role: "user", content: "old")], conversationID: id)
        }
        try await waitForFile(at: started)
        await runtime.endConversation(id: id)
        let replacement = Task {
            try await runtime.chat(model: "model", messages: [.init(role: "user", content: "replacement")], conversationID: id)
        }
        try Data().write(to: release)

        do {
            _ = try await oldChat.value
            XCTFail("Expected delayed old thread/start to be cancelled")
        } catch is CancellationError {
            // Expected.
        }
        let replacementResponse = try await replacement.value
        XCTAssertEqual(replacementResponse, "response-1")
        await runtime.shutdown()
    }

    func testWorkspaceStartupPreservesStaleLiveLeaseThenRemovesItAfterRelease() throws {
        let cacheRoot = temporaryURL(suffix: ".cache")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let now = Date(timeIntervalSince1970: 3_000_000)
        let liveID = UUID()
        let live = CodexConversationWorkspace(
            cacheRoot: cacheRoot,
            processID: liveID,
            staleProcessAge: 500,
            now: now
        )
        let liveRoot = live.processRoot
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-1_000)],
            ofItemAtPath: liveRoot.path
        )

        _ = CodexConversationWorkspace(
            cacheRoot: cacheRoot,
            processID: UUID(),
            staleProcessAge: 500,
            now: now
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: liveRoot.path))

        live.releaseLease()
        _ = CodexConversationWorkspace(
            cacheRoot: cacheRoot,
            processID: UUID(),
            staleProcessAge: 500,
            now: now
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: liveRoot.path))
    }

    func testWorkspaceStartupScavengesOnlyOldExactDirectProcessDirectoriesWithoutFollowingSymlinks() throws {
        let cacheRoot = temporaryURL(suffix: ".cache")
        let outside = temporaryURL(suffix: ".outside")
        defer {
            try? FileManager.default.removeItem(at: cacheRoot)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 2_000_000)
        let oldDate = now.addingTimeInterval(-1_000)
        let stale = cacheRoot.appendingPathComponent("process-\(UUID().uuidString.lowercased())")
        let fresh = cacheRoot.appendingPathComponent("process-\(UUID().uuidString.lowercased())")
        let malformed = cacheRoot.appendingPathComponent("process-\(UUID().uuidString)")
        let nestedParent = cacheRoot.appendingPathComponent("nested")
        let nested = nestedParent.appendingPathComponent("process-\(UUID().uuidString.lowercased())")
        let symlink = cacheRoot.appendingPathComponent("process-\(UUID().uuidString.lowercased())")
        let currentID = UUID()
        let current = cacheRoot.appendingPathComponent("process-\(currentID.uuidString.lowercased())")
        for directory in [stale, fresh, malformed, nested, current] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
        for oldItem in [stale, malformed, nested, current] {
            try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldItem.path)
        }
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: fresh.path)

        _ = CodexConversationWorkspace(
            cacheRoot: cacheRoot,
            processID: currentID,
            staleProcessAge: 500,
            now: now
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: malformed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path))
        XCTAssertNotNil(try FileManager.default.destinationOfSymbolicLink(atPath: symlink.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
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

    private func makeClient(
        scriptURL: URL,
        environment: [String: String] = [:],
        requestTimeoutSleeper: @escaping CodexAppServerClient.RequestTimeoutSleeper = { _, duration in
            try await Task.sleep(for: duration)
        }
    ) -> CodexAppServerClient {
        CodexAppServerClient(
            commandResolver: {
                ResolvedCodexCommand(executable: "/usr/bin/python3", arguments: ["-u", scriptURL.path])
            },
            environment: ProcessInfo.processInfo.environment.merging(environment) { _, override in override },
            defaultTimeout: .seconds(1),
            requestTimeoutSleeper: requestTimeoutSleeper,
            containmentMode: .disabledForTesting
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

    private func assertProcessExited(_ processID: Int32) async throws {
        for _ in 0..<100 {
            if kill(processID, 0) == -1, errno == ESRCH { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Expected old app-server process \(processID) to terminate")
    }

    private func readJSONLines(_ url: URL) throws -> [[String: Any]] {
        let contents = try String(contentsOf: url, encoding: .utf8)
        return try contents.split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
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

    private static let hangingInitializationServer = #"""
import json
import os
import sys
import time

initialize = json.loads(sys.stdin.readline())
assert initialize["method"] == "initialize"
open(os.environ["STARTED"], "w").write("started")
while True:
    time.sleep(1)
"""#

    private static let loginBeforeStartDrainServer = preamble + #"""
log_path = os.environ["LOG"]
read_count = 0
while True:
    request = read()
    with open(log_path, "a") as log:
        log.write(json.dumps(request, separators=(",", ":")) + "\n")
    if request["method"] == "account/read":
        read_count += 1
        if read_count == 1:
            open(os.environ["STARTED"], "w").write("started")
            continue
        write({"id":request["id"], "result":{"account":None,"requiresOpenaiAuth":True}})
    else:
        write({"id":request["id"], "error":{"code":-32601,"message":"unexpected " + request["method"]}})
"""#

    private static let unidentifiedLoginDrainServer = preamble + #"""
log_path = os.environ["LOG"]
count_path = os.environ["PROCESS_COUNT"]
try:
    generation = int(open(count_path).read()) + 1
except FileNotFoundError:
    generation = 1
open(count_path, "w").write(str(generation))
with open(log_path, "a") as log:
    log.write(json.dumps({"generationStarted":generation, "pid":os.getpid()}, separators=(",", ":")) + "\n")

while True:
    request = read()
    with open(log_path, "a") as log:
        record = {"generation":generation, "method":request["method"]}
        log.write(json.dumps(record, separators=(",", ":")) + "\n")
    if request["method"] == "account/read":
        write({"id":request["id"], "result":{"account":None,"requiresOpenaiAuth":True}})
    elif generation == 1 and request["method"] == "account/login/start":
        open(os.environ["STARTED"], "w").write("created")
        if "RELEASE_LOGIN_START" in os.environ:
            while not os.path.exists(os.environ["RELEASE_LOGIN_START"]):
                time.sleep(0.005)
            write({"id":request["id"], "result":{"type":"chatgpt","loginId":"delayed-login","authUrl":"https://auth.example.test/delayed"}})
    elif request["method"] == "account/login/cancel":
        write({"id":request["id"], "error":{"code":-32602,"message":"cancel requires a known login ID"}})
    else:
        write({"id":request["id"], "error":{"code":-32601,"message":"unexpected " + request["method"]}})
"""#

    private static let blockedUnknownLoginRestartServer = #"""
import json
import os
import sys
import time

count_path = os.environ["PROCESS_COUNT"]
try:
    generation = int(open(count_path).read()) + 1
except FileNotFoundError:
    generation = 1
open(count_path, "w").write(str(generation))
with open(os.environ["LOG"], "a") as log:
    log.write(json.dumps({"generationStarted":generation, "pid":os.getpid()}, separators=(",", ":")) + "\n")

if generation == 2:
    open(os.environ["RESTART_BLOCKED"], "w").write("blocked")
    while not os.path.exists(os.environ["RELEASE"]):
        time.sleep(0.005)

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

while True:
    request = read()
    with open(os.environ["LOG"], "a") as log:
        log.write(json.dumps({"generation":generation, "method":request["method"]}, separators=(",", ":")) + "\n")
    if request["method"] == "account/read":
        write({"id":request["id"], "result":{"account":None,"requiresOpenaiAuth":True}})
    elif generation == 1 and request["method"] == "account/login/start":
        open(os.environ["STARTED"], "w").write("created")
    else:
        write({"id":request["id"], "error":{"code":-32601,"message":"unexpected " + request["method"]}})
"""#

    private static let startedLoginDrainServer = preamble + #"""
log_path = os.environ["LOG"]
while True:
    request = read()
    with open(log_path, "a") as log:
        log.write(json.dumps(request, separators=(",", ":")) + "\n")
    if request["method"] == "account/read":
        write({"id":request["id"], "result":{"account":None,"requiresOpenaiAuth":True}})
    elif request["method"] == "account/login/start":
        write({"id":request["id"], "result":{"type":"chatgpt","loginId":"login-race","authUrl":"https://auth.example.test/login"}})
    elif request["method"] == "account/login/cancel":
        assert request["params"]["loginId"] == "login-race"
        open(os.environ["CANCELLED"], "w").write("cancelled")
        write({"id":request["id"], "result":{"status":"cancelled"}})
    else:
        write({"id":request["id"], "error":{"code":-32601,"message":"unexpected " + request["method"]}})
"""#

    private static let modelShutdownDrainServer = preamble + #"""
log_path = os.environ["LOG"]
count_path = os.environ["PROCESS_COUNT"]
try:
    process_count = int(open(count_path).read()) + 1
except FileNotFoundError:
    process_count = 1
open(count_path, "w").write(str(process_count))
while True:
    request = read()
    with open(log_path, "a") as log:
        log.write(json.dumps(request, separators=(",", ":")) + "\n")
    if request["method"] == "model/list":
        open(os.environ["STARTED"], "w").write("started")
        continue
    write({"id":request["id"], "error":{"code":-32601,"message":"unexpected " + request["method"]}})
"""#

    private static let lifecycleRaceServer = preamble + #"""
mode = os.environ["RACE_MODE"]
thread_count = 0
turn_count = 0

def gate():
    open(os.environ["STARTED"], "w").write("started")
    while not os.path.exists(os.environ["RELEASE"]):
        time.sleep(0.005)

while True:
    request = read()
    if request["method"] == "thread/start":
        thread_count += 1
        if mode == "thread" and thread_count == 1:
            gate()
        write({"id":request["id"], "result":{"thread":{"id":"thread-" + str(thread_count)},"model":"model","modelProvider":"openai"}})
    elif request["method"] == "turn/start":
        turn_count += 1
        turn_id = "turn-" + str(turn_count)
        if mode == "turn" and turn_count == 1:
            gate()
            write({"id":request["id"], "result":{"turn":{"id":turn_id}}})
        else:
            write({"id":request["id"], "result":{"turn":{"id":turn_id}}})
            write({"method":"item/agentMessage/delta","params":{"threadId":request["params"]["threadId"],"turnId":turn_id,"itemId":"agent","delta":"response-" + str(turn_count)}})
            write({"method":"turn/completed","params":{"threadId":request["params"]["threadId"],"turn":{"id":turn_id,"status":"completed","error":None}}})
    elif request["method"] == "turn/interrupt":
        open(os.environ["INTERRUPTED"], "w").write(request["params"]["threadId"] + "/" + request["params"]["turnId"])
        write({"id":request["id"], "result":{}})
    elif request["method"] == "account/read":
        write({"id":request["id"], "result":{"account":None,"requiresOpenaiAuth":True}})
    else:
        write({"id":request["id"], "error":{"code":-32601,"message":"unexpected " + request["method"]}})
"""#

    private static let conversationServer = preamble + #"""
log_path = os.environ["LOG"]
thread_count = 0
turn_count = 0
while True:
    request = read()
    with open(log_path, "a") as log:
        log.write(json.dumps(request, separators=(",", ":")) + "\n")
        log.flush()
    if request["method"] == "thread/start":
        thread_count += 1
        write({"id":request["id"], "result":{"thread":{"id":"thread-" + str(thread_count)},"model":request["params"]["model"],"modelProvider":"openai"}})
    elif request["method"] == "turn/start":
        turn_count += 1
        # DELAY_TURN
        turn_id = "turn-" + str(turn_count)
        write({"id":request["id"], "result":{"turn":{"id":turn_id}}})
        write({"method":"item/agentMessage/delta","params":{"threadId":request["params"]["threadId"],"turnId":turn_id,"itemId":"agent","delta":"response-" + str(turn_count)}})
        write({"method":"turn/completed","params":{"threadId":request["params"]["threadId"],"turn":{"id":turn_id,"status":"completed","error":None}}})
    elif request["method"] == "turn/interrupt":
        write({"id":request["id"], "result":{}})
    elif request["method"] == "account/read":
        write({"id":request["id"], "result":{"account":None,"requiresOpenaiAuth":True}})
    else:
        write({"id":request["id"], "error":{"code":-32601,"message":"unexpected " + request["method"]}})
"""#

    private static let staleThreadServer = preamble + #"""
log_path = os.environ["LOG"]
thread_count = 0
turn_count = 0
while True:
    request = read()
    with open(log_path, "a") as log:
        log.write(json.dumps(request, separators=(",", ":")) + "\n")
    if request["method"] == "thread/start":
        thread_count += 1
        write({"id":request["id"], "result":{"thread":{"id":"thread-" + str(thread_count)},"model":"model","modelProvider":"openai"}})
    elif request["method"] == "turn/start":
        turn_count += 1
        if turn_count == 1:
            write({"id":request["id"], "error":{"code":-32602,"message":"thread not found"}})
        else:
            write({"id":request["id"], "result":{"turn":{"id":"turn-retry"}}})
            write({"method":"item/agentMessage/delta","params":{"threadId":request["params"]["threadId"],"turnId":"turn-retry","itemId":"agent","delta":"recovered"}})
            write({"method":"turn/completed","params":{"threadId":request["params"]["threadId"],"turn":{"id":"turn-retry","status":"completed","error":None}}})
    else:
        write({"id":request["id"], "result":{}})
"""#

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

    private static let delayedUnknownTurnTimeoutServer = preamble + #"""
count_path = os.environ["PROCESS_COUNT"]
try:
    generation = int(open(count_path).read()) + 1
except FileNotFoundError:
    generation = 1
open(count_path, "w").write(str(generation))
with open(os.environ["LOG"], "a") as log:
    log.write(json.dumps({"generation":generation, "pid":os.getpid()}) + "\n")

request = read()
assert request["method"] == "thread/start"
thread_id = "thread-old" if generation == 1 else "thread-new"
write({"id":request["id"], "result":{"thread":{"id":thread_id}, "model":"codex-test", "modelProvider":"openai"}})
request = read()
assert request["method"] == "turn/start"
if generation == 1:
    open(os.environ["STARTED"], "w").write("started")
    time.sleep(0.2)
    write({"id":request["id"], "result":{"turn":{"id":"turn-late"}}})
else:
    write({"id":request["id"], "result":{"turn":{"id":"turn-new"}}})
    write({"method":"item/agentMessage/delta", "params":{"threadId":"thread-new", "turnId":"turn-new", "itemId":"a", "delta":"recovered"}})
    write({"method":"turn/completed", "params":{"threadId":"thread-new", "turn":{"id":"turn-new", "status":"completed", "error":None}}})
while True:
    read()
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

private actor OneShotTurnStartTimeout {
    private let markerURL: URL
    private var didTimeout = false

    init(markerURL: URL) {
        self.markerURL = markerURL
    }

    func sleep(method: String, duration: Duration) async throws {
        guard method == "turn/start", didTimeout == false else {
            try await Task.sleep(for: duration)
            return
        }
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: markerURL.path) {
                didTimeout = true
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: duration)
    }
}

private actor AsyncCheckpoint {
    private var reached = false
    private var released = false
    private var reachedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func reachAndWait() async {
        reached = true
        let waiters = reachedWaiters
        reachedWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        guard released == false else { return }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilReached() async {
        guard reached == false else { return }
        await withCheckedContinuation { continuation in
            reachedWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
