import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LangTools
import OpenAI

/// Pure memory transport: no URLSession instance, URLProtocol registration,
/// sockets, provider configuration or credential stores are used by these tests.
final class LangToolsTransportTests: XCTestCase {
    private let toolMessage = #"{"role":"assistant","content":"","tool_calls":[{"index":0,"id":"call-1","type":"function","function":{"name":"echo","arguments":"{}"}}]}"#
    private let finalMessage = #"{"role":"assistant","content":"finished"}"#

    private func response(_ message: String, streaming: Bool) -> String {
        #"{"object":"chat.completion","created":1,"choices":[{"index":0,"\#(streaming ? "delta" : "message")":\#(message),"finish_reason":"stop"}]}"#
    }

    private func request(_ events: TransportEvents, streaming: Bool) -> OpenAI.ChatCompletionRequest {
        OpenAI.ChatCompletionRequest(model: .gpt35Turbo, messages: [.init(role: .user, content: "test")], stream: streaming, tools: [
            .function(.init(name: "echo", description: "memory callback", parameters: .init(), callback: { _, _ in
                events.record("callback")
                return "tool result"
            }))
        ], toolEventHandler: { event in
            switch event {
            case .toolCalled: events.record("called")
            case .toolCompleted: events.record("completed")
            }
        })
    }

    func testDataOverrideDispatchesForRecursiveProviderCompletion() async throws {
        let events = TransportEvents()
        let fixture = TransportFixture(payloads: [response(toolMessage, streaming: false), response(finalMessage, streaming: false)])
        let client = MemoryTransport(fixture: fixture)
        let result = try await client.perform(request: request(events, streaming: false))
        XCTAssertEqual(result.message?.content.string, "finished")
        XCTAssertEqual(fixture.snapshot.dataCalls, 2)
        XCTAssertEqual(fixture.snapshot.bodyCalls, 0)
        XCTAssertEqual(events.values, ["called", "callback", "completed"])
        XCTAssertTrue(fixture.snapshot.requests.last?.contains("tool result") == true)
    }

    func testBodyOverrideDispatchesForRecursiveProviderCompletion() async throws {
        let events = TransportEvents()
        let fixture = TransportFixture(payloads: [response(toolMessage, streaming: true), response(finalMessage, streaming: true)])
        let client = MemoryTransport(fixture: fixture)
        var content: [String] = []
        for try await result in client.stream(request: request(events, streaming: true)) {
            content.append(result.delta?.content ?? "")
        }
        XCTAssertTrue(content.contains("finished"))
        XCTAssertEqual(fixture.snapshot.bodyCalls, 2)
        XCTAssertEqual(fixture.snapshot.dataCalls, 0)
        XCTAssertEqual(fixture.snapshot.cleanups, 2)
        XCTAssertEqual(events.values, ["called", "callback", "completed"])
        XCTAssertTrue(fixture.snapshot.requests.last?.contains("tool result") == true)
    }

    func testHeaderRejectionCleansUnconsumedBody() async {
        let cleaned = expectation(description: "header-rejected body cleaned")
        let fixture = TransportFixture(payloads: ["unused"], http: false, cleaned: cleaned)
        let client = MemoryTransport(fixture: fixture)
        do {
            for try await _ in client.stream(request: request(TransportEvents(), streaming: true)) {}
            XCTFail("Expected header rejection")
        } catch LangToolsError.requestFailed {}
        catch { XCTFail("Unexpected error: \(error)") }
        await fulfillment(of: [cleaned], timeout: 2)
        XCTAssertEqual(fixture.snapshot.lineReads, 0)
        XCTAssertEqual(fixture.snapshot.cleanups, 1)
    }

    func testUnsuccessfulStatusStillDecodesProviderErrorAndCleansBody() async {
        let fixture = TransportFixture(payloads: [#"{"error":{"message":"memory failure","type":"test"}}"#], status: 429)
        let client = MemoryTransport(fixture: fixture)
        do {
            for try await _ in client.stream(request: request(TransportEvents(), streaming: true)) {}
            XCTFail("Expected provider status error")
        } catch LangToolsError.responseUnsuccessful(let code, let error) {
            XCTAssertEqual(code, 429)
            XCTAssertEqual((error as? OpenAI.ErrorResponse)?.error.message, "memory failure")
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(fixture.snapshot.cleanups, 1)
    }

    func testDecodeFailureCleansBody() async {
        let fixture = TransportFixture(payloads: ["not JSON"], appendDoneMarker: false)
        let client = MemoryTransport(fixture: fixture)
        do {
            for try await _ in client.stream(request: request(TransportEvents(), streaming: true)) {}
            XCTFail("Expected decode failure")
        } catch LangToolsError.failedToDecodeStream {}
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(fixture.snapshot.cleanups, 1)
    }
}

private struct MemoryTransport: LangTools {
    typealias Model = OpenAI.Model
    typealias ErrorResponse = OpenAI.ErrorResponse
    let fixture: TransportFixture

    // Fail CLOSED if a regression falls through the default transport. There
    // is deliberately no real URLSession to reach, even with broken dispatch.
    var session: URLSession { fatalError("Memory transport must never access URLSession") }
    static var requestValidators: [(any LangToolsRequest) -> Bool] { [] }
    static func chatRequest(model: any RawRepresentable, messages: [any LangToolsMessage], tools: [any LangToolsTool]?, responseSchema: JSONSchema?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> any LangToolsChatRequest {
        throw LangToolsError.invalidArgument("Unused memory factory")
    }

    func prepare(request: some LangToolsRequest) throws -> URLRequest {
        var result = URLRequest(url: URL(string: "https://memory.invalid/completion")!)
        result.httpBody = try JSONEncoder().encode(request)
        return result
    }

    func transportData(for request: URLRequest) async throws -> (Data, URLResponse) {
        let payload = try fixture.take(request, streaming: false)
        return (Data(payload.utf8), fixture.response)
    }

    func transportBody(for request: URLRequest) async throws -> LangToolsResponseBody {
        let payload = try fixture.take(request, streaming: true)
        var responseLines = fixture.status == 200 ? ["data: " + payload] : [payload]
        if fixture.status == 200 && fixture.appendDoneMarker {
            responseLines.append("data: [DONE]")
        }
        let lines = TransportLines(responseLines)
        return LangToolsResponseBody(response: fixture.response, nextLine: {
            fixture.recordRead()
            return try lines.next()
        }, cancel: {
            lines.cancel()
            fixture.recordCleanup()
        })
    }
}

private enum TransportFixtureError: Error { case exhausted }

// Test-only locks protect all mutable state; no closures are invoked under lock.
private final class TransportFixture: @unchecked Sendable {
    let response: URLResponse
    let status: Int
    let appendDoneMarker: Bool
    private let lock = NSLock()
    private var payloads: [String]
    private var dataCalls = 0
    private var bodyCalls = 0
    private var cleanups = 0
    private var lineReads = 0
    private var requests: [String] = []
    private let cleaned: XCTestExpectation?

    init(payloads: [String], http: Bool = true, status: Int = 200, appendDoneMarker: Bool = true, cleaned: XCTestExpectation? = nil) {
        self.payloads = payloads
        self.status = status
        self.appendDoneMarker = appendDoneMarker
        self.cleaned = cleaned
        let url = URL(string: "https://memory.invalid/completion")!
        response = http ? HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)! : URLResponse(url: url, mimeType: nil, expectedContentLength: -1, textEncodingName: nil)
    }

    var snapshot: (dataCalls: Int, bodyCalls: Int, cleanups: Int, lineReads: Int, requests: [String]) {
        lock.lock(); defer { lock.unlock() }
        return (dataCalls, bodyCalls, cleanups, lineReads, requests)
    }

    func take(_ request: URLRequest, streaming: Bool) throws -> String {
        lock.lock(); defer { lock.unlock() }
        if streaming { bodyCalls += 1 } else { dataCalls += 1 }
        requests.append(String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "")
        guard !payloads.isEmpty else { throw TransportFixtureError.exhausted }
        return payloads.removeFirst()
    }
    func recordCleanup() {
        lock.lock(); cleanups += 1; lock.unlock()
        cleaned?.fulfill()
    }
    func recordRead() { lock.lock(); lineReads += 1; lock.unlock() }
}

private final class TransportLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String]
    private var cancelled = false
    init(_ lines: [String]) { self.lines = lines }
    func next() throws -> String? {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        return lines.isEmpty ? nil : lines.removeFirst()
    }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

private final class TransportEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var values: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    func record(_ event: String) { lock.lock(); recorded.append(event); lock.unlock() }
}
