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
            XCTAssertTrue(message.contains("See \(logURL.path) for helper output"))
        }
    }

    func testPerformOpenAIChatPreservesStructuredMessageContext() async throws {
        let requestCaptureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        let runner = StubCommandRunner { _, arguments in
            let modelIndex = try XCTUnwrap(arguments.firstIndex(of: "--model"))
            XCTAssertEqual(arguments[safe: modelIndex + 1], "gpt-5.5")
            let fileIndex = try XCTUnwrap(arguments.firstIndex(of: "--messages-file"))
            let path = try XCTUnwrap(arguments[safe: fileIndex + 1])
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            try data.write(to: requestCaptureURL)
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

        XCTAssertEqual(response.text, "ok")
        XCTAssertTrue(requestContents.contains("\"role\":\"tool\""))
        XCTAssertTrue(requestContents.contains("\"contentKind\":\"contentCards\""))
        XCTAssertTrue(requestContents.contains("Structured content cards (toolResult), count: 1"))
        XCTAssertTrue(requestContents.contains("\"contentKind\":\"agentEvent\""))
        XCTAssertTrue(requestContents.contains("started planning"))
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
