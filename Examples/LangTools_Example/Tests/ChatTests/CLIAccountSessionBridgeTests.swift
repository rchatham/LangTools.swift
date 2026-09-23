import Anthropic
import Foundation
import LangTools
import OpenAI
import XCTest
@testable import Chat

final class CLIAccountSessionBridgeTests: XCTestCase {
    func testExportOpenAISessionRedactsSensitiveLogOutput() async throws {
        let session = AccountSession(
            provider: .openAI,
            accountIdentifier: "user@example.com",
            accessToken: "secret-access-token",
            refreshToken: "secret-refresh-token",
            idToken: "secret-id-token",
            accessibleModelIDs: ["gpt-5.1-codex"]
        )
        let sessionData = try makeSessionData(session)
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("log")
        let runner = StubCommandRunner { _, arguments in
            XCTAssertTrue(arguments.contains("export-session"))
            return CommandResult(status: 0, stdout: String(decoding: sessionData, as: UTF8.self), stderr: "")
        }
        let bridge = CLIAccountSessionBridge(runner: runner, logger: CLIBridgeLogger(fileURL: logURL))

        let exported = try await bridge.exportOpenAISession()
        let logContents = try String(contentsOf: logURL, encoding: .utf8)

        XCTAssertEqual(exported.accountIdentifier, session.accountIdentifier)
        XCTAssertFalse(logContents.contains("secret-access-token"))
        XCTAssertFalse(logContents.contains("secret-refresh-token"))
        XCTAssertFalse(logContents.contains("secret-id-token"))
        XCTAssertTrue(logContents.contains("stdout:\n<redacted>"))
    }

    func testExportFailureDoesNotExposeHelperOutput() async throws {
        let logURL = tempLogURL()
        let runner = StubCommandRunner { _, _ in
            CommandResult(
                status: 1,
                stdout: #"{"accessToken":"secret-access-token"}"#,
                stderr: "refresh token: secret-refresh-token"
            )
        }
        let bridge = CLIAccountSessionBridge(runner: runner, logger: CLIBridgeLogger(fileURL: logURL))

        do {
            _ = try await bridge.exportOpenAISession()
            XCTFail("Expected export to fail")
        } catch {
            let message = error.localizedDescription
            XCTAssertFalse(message.contains("secret-access-token"))
            XCTAssertFalse(message.contains("secret-refresh-token"))
            XCTAssertTrue(message.contains("OpenAI session export failed"))
            XCTAssertTrue(message.contains("See \(logURL.path) for redacted helper diagnostics"))
        }
    }

    func testPerformOpenAIChatPreservesStructuredMessageContext() async throws {
        let requestCaptureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        let requestDirectoryCaptureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("path")
        defer {
            try? FileManager.default.removeItem(at: requestCaptureURL)
            try? FileManager.default.removeItem(at: requestDirectoryCaptureURL)
        }
        let runner = StubCommandRunner { _, arguments in
            let modelIndex = try XCTUnwrap(arguments.firstIndex(of: "--model"))
            XCTAssertEqual(arguments[safe: modelIndex + 1], "gpt-5.5")
            let fileIndex = try XCTUnwrap(arguments.firstIndex(of: "--messages-file"))
            let path = try XCTUnwrap(arguments[safe: fileIndex + 1])
            let requestURL = URL(fileURLWithPath: path)
            let data = try Data(contentsOf: requestURL)
            try data.write(to: requestCaptureURL)
            try requestURL.deletingLastPathComponent().path.write(
                to: requestDirectoryCaptureURL,
                atomically: true,
                encoding: .utf8
            )
            let directoryPermissions = try XCTUnwrap(
                (try FileManager.default.attributesOfItem(
                    atPath: requestURL.deletingLastPathComponent().path
                )[.posixPermissions] as? NSNumber)?.intValue
            )
            let filePermissions = try XCTUnwrap(
                (try FileManager.default.attributesOfItem(atPath: requestURL.path)[.posixPermissions] as? NSNumber)?.intValue
            )
            XCTAssertEqual(directoryPermissions & 0o777, 0o700)
            XCTAssertEqual(filePermissions & 0o777, 0o600)
            return CommandResult(status: 0, stdout: #"{"content":"ok"}"#, stderr: "")
        }
        let bridge = CLIAccountSessionBridge(runner: runner, logger: CLIBridgeLogger(fileURL: tempLogURL()))
        let toolMessage = Message(role: .tool, contentType: .contentCards(.init(cardType: "toolResult", message: nil, cardsJSON: "[]", cardCount: 1)))
        let eventMessage = Message(role: .assistant, contentType: .agentEvent(.init(type: .started, agentName: "planner", details: "started planning")))

        let response = try await bridge.performOpenAIChat(
            messages: [
                Message(text: "Use the tool result", role: .user),
                toolMessage,
                eventMessage,
            ],
            model: .codex(.gpt5_5)
        )
        let requestContents = try String(contentsOf: requestCaptureURL, encoding: .utf8)
        let requestDirectory = try String(contentsOf: requestDirectoryCaptureURL, encoding: .utf8)

        XCTAssertEqual(response.text, "ok")
        XCTAssertFalse(FileManager.default.fileExists(atPath: requestDirectory))
        XCTAssertTrue(requestContents.contains("\"role\":\"tool\""))
        XCTAssertTrue(requestContents.contains("\"contentKind\":\"contentCards\""))
        XCTAssertTrue(requestContents.contains("Structured content cards (toolResult), count: 1"))
        XCTAssertTrue(requestContents.contains("\"contentKind\":\"agentEvent\""))
        XCTAssertTrue(requestContents.contains("started planning"))
    }

    func testChatLoggingIsOptInAndMetadataOnly() async throws {
        let secretResponse = "secret assistant response"
        let disabledLogURL = tempLogURL()
        let runner = StubCommandRunner { _, _ in
            CommandResult(status: 0, stdout: #"{"content":"secret assistant response"}"#, stderr: "secret diagnostic")
        }
        let disabledBridge = CLIAccountSessionBridge(
            runner: runner,
            logger: CLIBridgeLogger(fileURL: disabledLogURL, logChatResponses: false)
        )

        _ = try await disabledBridge.performOpenAIChat(
            messages: [Message(text: "secret prompt", role: .user)],
            model: .codex(.gpt5_5)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: disabledLogURL.path))

        let enabledLogURL = tempLogURL()
        let enabledBridge = CLIAccountSessionBridge(
            runner: runner,
            logger: CLIBridgeLogger(fileURL: enabledLogURL, logChatResponses: true)
        )
        _ = try await enabledBridge.performOpenAIChat(
            messages: [Message(text: "secret prompt", role: .user)],
            model: .codex(.gpt5_5)
        )
        let contents = try String(contentsOf: enabledLogURL, encoding: .utf8)

        XCTAssertTrue(contents.contains("OpenAI chat"))
        XCTAssertTrue(contents.contains("bytes>"))
        XCTAssertFalse(contents.contains(secretResponse))
        XCTAssertFalse(contents.contains("secret diagnostic"))
        XCTAssertFalse(contents.contains("secret prompt"))
    }

    func testChatFailureDoesNotClaimUnloggedHelperOutputExists() async throws {
        let logURL = tempLogURL()
        let bridge = CLIAccountSessionBridge(
            runner: StubCommandRunner { _, _ in
                CommandResult(status: 1, stdout: "secret response", stderr: "secret diagnostic")
            },
            logger: CLIBridgeLogger(fileURL: logURL, logChatResponses: false)
        )

        do {
            _ = try await bridge.performOpenAIChat(
                messages: [Message(text: "secret prompt", role: .user)],
                model: .codex(.gpt5_5)
            )
            XCTFail("Expected chat failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("OpenAI chat failed"))
            XCTAssertFalse(error.localizedDescription.contains(logURL.path))
            XCTAssertFalse(error.localizedDescription.contains("secret response"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: logURL.path))
        }
    }

    func testBundledHelperLayoutUsesLowercaseExecutableName() throws {
        let bundleURL = URL(fileURLWithPath: "/tmp/LangTools_Example.app")
        let candidates = CLIAccountSessionBridge.bundledCandidatePaths(bundleURL: bundleURL)
        XCTAssertTrue(candidates.contains("/tmp/LangTools_Example.app/Contents/Helpers/langtools"))
        XCTAssertFalse(candidates.contains { $0.hasSuffix("/Helpers/LangToolsCLI") })

        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let project = try String(
            contentsOf: packageRoot.appendingPathComponent("LangTools_Example.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        XCTAssertTrue(project.contains("Helpers/langtools"))
        XCTAssertFalse(project.contains("Helpers/LangToolsCLI\""))
    }

    func testProcessRunnerDrainsLargeStdoutAndStderrWithoutDeadlock() async throws {
        let result = try await ProcessRunner(timeout: 5).run(
            executable: "/bin/sh",
            arguments: ["-c", "yes o | head -c 1048576; yes e | head -c 1048576 >&2"]
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout.utf8.count, 1_048_576)
        XCTAssertEqual(result.stderr.utf8.count, 1_048_576)
    }

    func testProcessRunnerCancellationTerminatesChildProcessGroup() async throws {
        let startedAt = Date()
        let task = Task {
            try await ProcessRunner(timeout: 10).run(
                executable: "/bin/sh",
                arguments: ["-c", "sleep 10 & wait"]
            )
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch let error as CLIAccountSessionBridgeError {
            XCTAssertEqual(error, .commandCancelled)
            XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
        }
    }

    func testProcessRunnerTimeoutTerminatesChildProcessGroup() async throws {
        let startedAt = Date()
        do {
            _ = try await ProcessRunner(timeout: 0.05).run(
                executable: "/bin/sh",
                arguments: ["-c", "sleep 10 & wait"]
            )
            XCTFail("Expected timeout")
        } catch let error as CLIAccountSessionBridgeError {
            XCTAssertEqual(error, .commandTimedOut)
            XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
        }
    }

    private func makeSessionData(_ session: AccountSession) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(session)
    }

    private func tempLogURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("log")
    }
}

final class AccountProxyTransportTests: XCTestCase {
}

private struct AccountProxyTransportRequestProbe: Decodable {
    let stream: Bool
}

private final class StubCommandRunner: CommandRunning {
    private let handler: @Sendable (String, [String]) throws -> CommandResult

    init(handler: @escaping @Sendable (String, [String]) throws -> CommandResult) {
        self.handler = handler
    }

    func run(executable: String, arguments: [String]) async throws -> CommandResult {
        try handler(executable, arguments)
    }
}

private final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
