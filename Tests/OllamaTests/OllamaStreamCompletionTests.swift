import XCTest
import LangTools
import OpenAI
import Ollama
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class OllamaStreamCompletionTests: XCTestCase {
    private var api: Ollama!

    override func setUp() {
        super.setUp()
        CompletionStreamingURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CompletionStreamingURLProtocol.self]
        api = Ollama(baseURL: URL(string: "https://ollama-stream.test")!,
                     session: URLSession(configuration: configuration))
    }

    override func tearDown() {
        api.session.invalidateAndCancel()
        api = nil
        super.tearDown()
    }

    func testEmptyPullStreamFailsCompletionValidation() async {
        CompletionStreamingURLProtocol.enqueue(.complete([]))
        await assertIncompletePull()
    }

    func testProgressOnlyPullFailsAfterYieldingEvenFullyDownloadedProgress() async {
        let progress = #"{"status":"downloading model","digest":"sha256:fixture","total":100,"completed":100}"#
        CompletionStreamingURLProtocol.enqueue(.complete([Data((progress + "\n").utf8)]))
        var responses: [Ollama.PullModelResponse] = []
        await assertIncompletePull(onResponse: { responses.append($0) })
        XCTAssertEqual(responses.map(\.status), ["downloading model"])
        XCTAssertEqual(responses.first?.completed, 100)
        XCTAssertEqual(responses.first?.total, 100)
    }

    func testPullSuccessWithoutTrailingNewlineAcrossTransportChunks() async throws {
        let body = #"{"status":"pulling manifest"}"# + "\n" + #"{"status":"success"}"#
        CompletionStreamingURLProtocol.enqueue(.complete(body.utf8.map { Data([$0]) }))
        var statuses: [String] = []
        for try await response in api.streamPullModel("fixture-model") { statuses.append(response.status) }
        XCTAssertEqual(statuses, ["pulling manifest", "success"])
    }

    func testPullRequiresExactSuccessAsFinalStatus() async {
        for body in [
            #"{"status":"success"}"# + "\n" + #"{"status":"writing manifest"}"#,
            #"{"status":"not success"}"#,
            #"{"status":"Success"}"#,
        ] {
            CompletionStreamingURLProtocol.enqueue(.complete([Data(body.utf8)]))
            await assertIncompletePull()
        }
    }

    func testPullErrorRecordAfterProgressFailsInsteadOfCompleting() async {
        let progress = #"{"status":"pulling manifest"}"#
        let errorRecord = #"{"error":"fixture pull failed"}"#
        CompletionStreamingURLProtocol.enqueue(.complete([Data((progress + "\n" + errorRecord + "\n").utf8)]))
        var statuses: [String] = []
        do {
            for try await response in api.streamPullModel("fixture-model") { statuses.append(response.status) }
            XCTFail("An Ollama error record must not complete the pull")
        } catch let error as LangToolsError {
            guard case .failedToDecodeStream(let buffer, _) = error else {
                XCTFail("Expected existing decode error, got \(error)")
                return
            }
            XCTAssertEqual(buffer, errorRecord)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(statuses, ["pulling manifest"])
    }

    func testPullSuccessCannotHideMalformedTrailingRecord() async {
        CompletionStreamingURLProtocol.enqueue(.complete([
            Data((#"{"status":"success"}"# + "\n" + #"{"status":"success""#).utf8)
        ]))
        do {
            for try await _ in api.streamPullModel("fixture-model") {}
            XCTFail("A success record cannot hide malformed trailing data")
        } catch let error as LangToolsError {
            guard case .failedToDecodeStream = error else {
                XCTFail("Expected decode error, got \(error)")
                return
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testNonstreamingPullDoesNotRequireSuccessStatus() async throws {
        CompletionStreamingURLProtocol.enqueue(.complete([Data(#"{"status":"downloading model"}"#.utf8)]))
        for try await response in api.stream(request: Ollama.PullModelRequest(model: "fixture-model", stream: false)) {
            XCTAssertEqual(response.status, "downloading model")
        }
    }

    func testCompleteChatAndGenerateWithoutTrailingNewline() async throws {
        for endpoint in Endpoint.allCases {
            CompletionStreamingURLProtocol.enqueue(.complete([
                Data((endpoint.line(done: false) + "\n" + endpoint.line(done: true, content: "")).utf8)
            ]))
            let result = try await collect(endpoint)
            XCTAssertEqual(result.contents, ["hello", ""])
            XCTAssertEqual(result.done, [false, true])
        }
    }

    func testCompleteChatAndGenerateAcrossPartialTransportChunks() async throws {
        for endpoint in Endpoint.allCases {
            let body = endpoint.line(done: false, content: "héllo") + "\n" + endpoint.line(done: true, content: "") + "\n"
            // Split even the multibyte UTF-8 character and the terminal boolean.
            CompletionStreamingURLProtocol.enqueue(.complete(body.utf8.map { Data([$0]) }))
            let result = try await collect(endpoint)
            XCTAssertEqual(result.contents, ["héllo", ""])
            XCTAssertEqual(result.done, [false, true])
        }
    }

    func testEmptyChatAndGenerateFailCompletionValidation() async {
        for endpoint in Endpoint.allCases {
            CompletionStreamingURLProtocol.enqueue(.complete([]))
            await assertIncomplete(endpoint)
        }
    }

    func testChatAndGenerateMissingDoneFailAfterYieldingPartialContent() async {
        for endpoint in Endpoint.allCases {
            CompletionStreamingURLProtocol.enqueue(.complete([
                Data((endpoint.line(done: false) + "\n").utf8)
            ]))
            var contents: [String] = []
            await assertIncomplete(endpoint, onContent: { contents.append($0) })
            XCTAssertEqual(contents, ["hello"])
        }
    }

    func testMalformedAndTruncatedTerminalRecordsAreNotAccepted() async {
        for endpoint in Endpoint.allCases {
            for terminal in [
                #"{"done":true}"#, // Valid JSON, but not a valid provider response.
                String(endpoint.line(done: true).dropLast()),
                endpoint.line(done: true).replacingOccurrences(of: "true", with: #""true""#),
            ] {
                CompletionStreamingURLProtocol.enqueue(.complete([
                    Data((endpoint.line(done: false) + "\n" + terminal).utf8)
                ]))
                do {
                    _ = try await collect(endpoint)
                    XCTFail("Malformed terminal record must fail: \(terminal)")
                } catch let error as LangToolsError {
                    guard case .failedToDecodeStream = error else {
                        XCTFail("Expected decode failure, got \(error)")
                        continue
                    }
                } catch {
                    XCTFail("Unexpected error: \(error)")
                }
            }
        }
    }

    func testMalformedRecordAfterDoneStillFails() async {
        for endpoint in Endpoint.allCases {
            CompletionStreamingURLProtocol.enqueue(.complete([
                Data((endpoint.line(done: true) + "\n" + #"{"done":true"#).utf8)
            ]))
            do {
                _ = try await collect(endpoint)
                XCTFail("A previous terminal response cannot hide a malformed trailing record")
            } catch let error as LangToolsError {
                guard case .failedToDecodeStream = error else {
                    XCTFail("Expected decode failure, got \(error)")
                    continue
                }
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testNonterminalResponseAfterDoneDoesNotValidate() async {
        for endpoint in Endpoint.allCases {
            CompletionStreamingURLProtocol.enqueue(.complete([
                Data((endpoint.line(done: true) + "\n" + endpoint.line(done: false)).utf8)
            ]))
            await assertIncomplete(endpoint)
        }
    }

    func testCompletedMultilineJSONBufferRemainsSupported() async throws {
        for endpoint in Endpoint.allCases {
            let body = endpoint.line(done: true).replacingOccurrences(of: ",", with: ",\n")
            CompletionStreamingURLProtocol.enqueue(.complete([Data(body.utf8)]))
            let result = try await collect(endpoint)
            XCTAssertEqual(result.done, [true])
        }
    }

    func testTruncatedToolCallStreamDoesNotExecuteTools() async {
        let calls = CompletionToolTracker()
        CompletionStreamingURLProtocol.enqueue(.complete([Data((toolCallLine + "\n").utf8)]))
        await assertIncomplete(.chat, tools: [makeTool(calls)])
        let count = await calls.count
        XCTAssertEqual(count, 0)
        XCTAssertEqual(CompletionStreamingURLProtocol.requestCount, 1)
    }

    func testCompletedToolCallStreamExecutesToolAndStreamsCompletion() async throws {
        let calls = CompletionToolTracker()
        CompletionStreamingURLProtocol.enqueue(.complete([
            Data((toolCallLine + "\n" + Endpoint.chat.line(done: true, content: "")).utf8)
        ]))
        CompletionStreamingURLProtocol.enqueue(.complete([
            Data((Endpoint.chat.line(done: false, content: "answer") + "\n" + Endpoint.chat.line(done: true, content: "")).utf8)
        ]))
        let result = try await collect(.chat, tools: [makeTool(calls)])
        let count = await calls.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(CompletionStreamingURLProtocol.requestCount, 2)
        XCTAssertEqual(result.contents, ["", "", "answer", ""])
        XCTAssertEqual(result.done, [false, true, false, true])
        let requests = CompletionStreamingURLProtocol.requests
        let followup = try JSONDecoder().decode(Ollama.ChatRequest.self, from: XCTUnwrap(requests.last))
        XCTAssertEqual(followup.messages.last?.role, .tool)
        XCTAssertEqual(followup.messages.last?.content.text, "tool result")
    }

    func testCompletedToolFailureStillStreamsFollowupAndReportsErrorResult() async throws {
        let calls = CompletionToolTracker()
        enum FixtureToolError: LocalizedError {
            case failed
            var errorDescription: String? { "fixture tool failed" }
        }
        let tool = OpenAI.Tool(name: "fixture_tool", description: nil, tool_schema: .init(), callback: { _, _ in
            await calls.called()
            throw FixtureToolError.failed
        })
        var errorResults: [Bool] = []
        let request = Ollama.ChatRequest(model: .init(rawValue: "fixture-model")!, messages: [], stream: true,
            tools: [tool], toolEventHandler: { event in
                if case .toolCompleted(let result) = event, let result { errorResults.append(result.is_error) }
            })
        CompletionStreamingURLProtocol.enqueue(.complete([
            Data((toolCallLine + "\n" + Endpoint.chat.line(done: true, content: "")).utf8)
        ]))
        CompletionStreamingURLProtocol.enqueue(.complete([
            Data(Endpoint.chat.line(done: true, content: "tool failed answer").utf8)
        ]))
        var contents: [String] = []
        for try await response in api.stream(request: request) { contents.append(response.message?.content.text ?? "") }
        let count = await calls.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(errorResults, [true])
        XCTAssertEqual(contents, ["", "", "tool failed answer"])
        XCTAssertEqual(CompletionStreamingURLProtocol.requestCount, 2)
        let followup = try JSONDecoder().decode(Ollama.ChatRequest.self, from: XCTUnwrap(CompletionStreamingURLProtocol.requests.last))
        XCTAssertEqual(followup.messages.last?.role, .tool)
        XCTAssertEqual(followup.messages.last?.content.text, "fixture tool failed")
    }

    func testTruncatedRecursiveToolCompletionStreamFails() async {
        let calls = CompletionToolTracker()
        CompletionStreamingURLProtocol.enqueue(.complete([
            Data((toolCallLine + "\n" + Endpoint.chat.line(done: true, content: "")).utf8)
        ]))
        CompletionStreamingURLProtocol.enqueue(.complete([
            Data((Endpoint.chat.line(done: false, content: "partial answer") + "\n").utf8)
        ]))
        var contents: [String] = []
        await assertIncomplete(.chat, tools: [makeTool(calls)], onContent: { contents.append($0) })
        let count = await calls.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(CompletionStreamingURLProtocol.requestCount, 2)
        XCTAssertEqual(contents, ["", "", "partial answer"])
    }

    func testNonstreamingRequestsDoNotRequireTerminalValidation() async throws {
        for endpoint in Endpoint.allCases {
            CompletionStreamingURLProtocol.enqueue(.complete([Data(endpoint.line(done: false).utf8)]))
            switch endpoint {
            case .chat:
                let request = Ollama.ChatRequest(model: .init(rawValue: "fixture-model")!, messages: [], stream: false)
                for try await response in api.stream(request: request) {
                    XCTAssertFalse(response.done)
                    XCTAssertEqual(response.message?.content.text, "hello")
                }
            case .generate:
                let request = Ollama.GenerateRequest(model: "fixture-model", prompt: "hello", stream: false)
                for try await response in api.stream(request: request) {
                    XCTAssertFalse(response.done)
                    XCTAssertEqual(response.response, "hello")
                }
            }
        }
    }

    func testTransportCancellationIsNotReclassifiedAsIncompleteStream() async {
        for endpoint in Endpoint.allCases {
            CompletionStreamingURLProtocol.enqueue(.failed(URLError(.cancelled)))
            do {
                _ = try await collect(endpoint)
                XCTFail("Transport cancellation must escape")
            } catch let error as URLError {
                XCTAssertEqual(error.code, .cancelled)
            } catch {
                XCTFail("Expected original transport cancellation, got \(error)")
            }
        }
    }

    #if canImport(Darwin)
    // The Linux compatibility shim buffers the entire HTTP body, so a blocked
    // response cannot deliver partial content before EOF there.
    func testCancellingIncompleteStreamDoesNotBecomeCompletionFailure() async {
        for endpoint in Endpoint.allCases {
            let received = DispatchSemaphore(value: 0)
            CompletionStreamingURLProtocol.enqueue(.blocked([
                Data((endpoint.line(done: false) + "\n").utf8)
            ]))
            let consumer = Task { () -> Error? in
                do {
                    _ = try await collect(endpoint, onContent: { _ in received.signal() })
                    return nil
                } catch {
                    return error
                }
            }
            XCTAssertEqual(received.wait(timeout: .now() + 2), .success)
            consumer.cancel()
            let error = await consumer.value
            // Existing AsyncThrowingStream consumer cancellation finishes normally.
            XCTAssertNil(error)
            XCTAssertTrue(CompletionStreamingURLProtocol.waitForStop())
        }
    }

    #endif

    private enum Endpoint: CaseIterable {
        case chat, generate

        func line(done: Bool, content: String = "hello") -> String {
            let payload = self == .chat
                ? #""message":{"role":"assistant","content":"\#(content)"}"#
                : #""response":"\#(content)""#
            return #"{"model":"fixture-model","created_at":"2026-10-07T00:00:00Z",\#(payload),"done":\#(done)}"#
        }
    }

    private func collect(_ endpoint: Endpoint, tools: [OpenAI.Tool]? = nil,
                         onContent: (String) -> Void = { _ in }) async throws -> (contents: [String], done: [Bool]) {
        var contents: [String] = []
        var done: [Bool] = []
        switch endpoint {
        case .chat:
            for try await response in api.streamChat(model: .init(rawValue: "fixture-model")!, messages: [], tools: tools) {
                let content = response.message?.content.text ?? ""
                contents.append(content)
                done.append(response.done)
                onContent(content)
            }
        case .generate:
            for try await response in api.streamGenerate(model: "fixture-model", prompt: "hello") {
                contents.append(response.response)
                done.append(response.done)
                onContent(response.response)
            }
        }
        return (contents, done)
    }

    private func assertIncomplete(_ endpoint: Endpoint, tools: [OpenAI.Tool]? = nil,
                                  onContent: (String) -> Void = { _ in },
                                  file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await collect(endpoint, tools: tools, onContent: onContent)
            XCTFail("Expected incomplete stream failure", file: file, line: line)
        } catch let error as LangToolsError {
            guard case .incompleteStream = error else {
                XCTFail("Expected incompleteStream, got \(error)", file: file, line: line)
                return
            }
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    private func assertIncompletePull(onResponse: (Ollama.PullModelResponse) -> Void = { _ in },
                                      file: StaticString = #filePath, line: UInt = #line) async {
        do {
            for try await response in api.streamPullModel("fixture-model") { onResponse(response) }
            XCTFail("Expected incomplete pull failure", file: file, line: line)
        } catch let error as LangToolsError {
            guard case .incompleteStream = error else {
                XCTFail("Expected incompleteStream, got \(error)", file: file, line: line)
                return
            }
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    private var toolCallLine: String {
        #"{"model":"fixture-model","created_at":"2026-10-07T00:00:00Z","message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"fixture_tool","arguments":{}}}]},"done":false}"#
    }

    private func makeTool(_ tracker: CompletionToolTracker) -> OpenAI.Tool {
        .init(name: "fixture_tool", description: nil, tool_schema: .init(), callback: { _, _ in
            await tracker.called()
            return "tool result"
        })
    }
}

private actor CompletionToolTracker {
    private(set) var count = 0
    func called() { count += 1 }
}

private final class CompletionStreamingURLProtocol: URLProtocol {
    enum Response { case complete([Data]), blocked([Data]), failed(Error) }
    private static let lock = NSLock()
    private static var responses: [Response] = []
    private static var bodies: [Data] = []
    private static var stopped = DispatchSemaphore(value: 0)

    static var requests: [Data] { lock.lock(); defer { lock.unlock() }; return bodies }
    static var requestCount: Int { requests.count }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        responses = []
        bodies = []
        stopped = DispatchSemaphore(value: 0)
    }

    static func enqueue(_ response: Response) {
        lock.lock(); defer { lock.unlock() }
        responses.append(response)
    }

    static func waitForStop() -> Bool {
        lock.lock()
        let semaphore = stopped
        lock.unlock()
        return semaphore.wait(timeout: .now() + 2) == .success
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "ollama-stream.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = requestBody()
        Self.lock.lock()
        Self.bodies.append(body)
        let fixture = Self.responses.isEmpty ? nil : Self.responses.removeFirst()
        Self.lock.unlock()
        guard let fixture, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                             headerFields: ["Content-Type": "application/x-ndjson"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        switch fixture {
        case .complete(let chunks):
            chunks.forEach { client?.urlProtocol(self, didLoad: $0) }
            client?.urlProtocolDidFinishLoading(self)
        case .blocked(let chunks):
            chunks.forEach { client?.urlProtocol(self, didLoad: $0) }
        case .failed(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        Self.lock.lock()
        let semaphore = Self.stopped
        Self.lock.unlock()
        semaphore.signal()
    }

    private func requestBody() -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else {
                XCTFail("Failed to read fixture request body")
                return data
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}
