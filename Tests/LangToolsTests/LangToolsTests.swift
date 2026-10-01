import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import TestUtils
@testable import LangTools
@testable import OpenAI

final class LangToolsTests: XCTestCase {

    var api: OpenAI!

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        api = OpenAI(apiKey: "").configure(testURLSessionConfiguration: config)
    }

    override func tearDown() {
        MockURLProtocol.resetHandlers()
        URLProtocol.unregisterClass(MockURLProtocol.self)
        super.tearDown()
    }

    func test() async throws {
        MockURLProtocol.setHandler(for: MockRequest.endpoint) { request in
            return (.success(try MockResponse.success.data()), 200)
        }
        let response = try await api.perform(request: MockRequest())
        XCTAssertEqual(response.status, "success")
    }

    func testStream() async throws {
        MockURLProtocol.setHandler(for: MockRequest.endpoint) { request in
            return (.success(try MockResponse.success.streamData()), 200)
        }
        var results: [MockResponse] = []
        for try await response in api.stream(request: MockRequest(stream: true)) {
            results.append(response)
        }
        let content = results.reduce("") { $0 + ($1.status) }
        XCTAssertEqual(content, "success")
    }

    func testCancellingStreamConsumerCancelsURLSessionProducer() async {
        BlockingStreamingURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BlockingStreamingURLProtocol.self]
        let blockingAPI = OpenAI(apiKey: "").configure(
            testURLSessionConfiguration: configuration
        )
        let consumer = Task {
            do {
                for try await _ in blockingAPI.stream(request: MockRequest(stream: true)) {}
            } catch {}
        }
        defer { consumer.cancel() }

        XCTAssertTrue(
            BlockingStreamingURLProtocol.waitForStart(),
            "The stream producer did not start its URLSession request"
        )
        consumer.cancel()
        XCTAssertTrue(
            BlockingStreamingURLProtocol.waitForStop(),
            "Cancelling the consumer must cancel the URLSession producer"
        )
        _ = await consumer.result
    }

    func testCancellationStopsRemainingToolCallbacks() async {
        let callbacks = ToolCallbackTracker()
        let firstCallbackStarted = DispatchSemaphore(value: 0)
        let tools: [ToolCallbackMockTool] = [
            ToolCallbackMockTool(
                name: "first",
                description: nil,
                tool_schema: .init(),
                callback: { _, _ in
                    await callbacks.record("first")
                    firstCallbackStarted.signal()
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    return "first"
                }
            ),
            ToolCallbackMockTool(
                name: "second",
                description: nil,
                tool_schema: .init(),
                callback: { _, _ in
                    await callbacks.record("second")
                    return "second"
                }
            ),
        ]
        let events = ToolEventTracker()
        var request = ToolCallingMockRequest(tools: tools)
        request.toolEventHandler = events.record
        let response = ToolCallingMockResponse(
            message: MockMessage(tool_selection: [
                .init(id: "first", name: "first", arguments: ""),
                .init(id: "second", name: "second", arguments: ""),
            ])
        )
        let task = Task {
            try await request.completion(
                MockLangTool(session: .shared),
                response: response
            )
        }

        XCTAssertEqual(firstCallbackStarted.wait(timeout: .now() + 2), .success)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancellation must escape tool completion")
        } catch is CancellationError {}
        catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        let invocations = await callbacks.all()
        XCTAssertEqual(invocations, ["first"])
        XCTAssertEqual(events.all(), ["called:first", "completed:nil"])
    }

    func testCancellingSingleItemStreamFinishesWithoutError() async {
        let producer = CancellableStreamProducer()
        let stream: AsyncThrowingStream<Int, Error> = AsyncThrowingSingleItemStream(value: {
            producer.started()
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return 1
            } catch let error as CancellationError {
                producer.cancelled()
                throw error
            }
        })
        let consumer = Task { () -> Error? in
            do {
                for try await _ in stream {}
                return nil
            } catch {
                return error
            }
        }
        defer { consumer.cancel() }

        XCTAssertTrue(producer.waitForStart())
        consumer.cancel()
        let result = await consumer.value
        XCTAssertNil(result)
        XCTAssertTrue(producer.waitForCancellation())
    }

    func testCancellingDeferredErrorStreamFinishesWithoutError() async {
        let producer = CancellableStreamProducer()
        let stream: AsyncThrowingStream<Int, Error> = AsyncSingleErrorStream(error: {
            producer.started()
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return MockErrorResponse()
            } catch let error as CancellationError {
                producer.cancelled()
                throw error
            }
        })
        let consumer = Task { () -> Error? in
            do {
                for try await _ in stream {}
                return nil
            } catch {
                return error
            }
        }
        defer { consumer.cancel() }

        XCTAssertTrue(producer.waitForStart())
        consumer.cancel()
        let result = await consumer.value
        XCTAssertNil(result)
        XCTAssertTrue(producer.waitForCancellation())
    }

    func testCancellingOuterToolStreamCancelsNestedProducer() async throws {
        let outerResponse = ToolCallingMockResponse(
            message: MockMessage(tool_selection: [
                .init(id: "tool", name: "tool", arguments: ""),
            ])
        )
        NestedToolStreamingURLProtocol.reset(initialResponse: try outerResponse.streamData())
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NestedToolStreamingURLProtocol.self]
        let langTool = MockLangTool(session: URLSession(configuration: configuration))
        let tools = [ToolCallbackMockTool(
            name: "tool",
            description: nil,
            tool_schema: .init(),
            callback: { _, _ in "completed" }
        )]
        var request = ToolCallingMockRequest(tools: tools)
        request.stream = true
        let consumer = Task { () -> Error? in
            do {
                for try await _ in langTool.stream(request: request) {}
                return nil
            } catch {
                return error
            }
        }
        defer { consumer.cancel() }

        XCTAssertTrue(NestedToolStreamingURLProtocol.waitForNestedStart())
        consumer.cancel()
        let result = await consumer.value
        XCTAssertNil(result)
        XCTAssertTrue(NestedToolStreamingURLProtocol.waitForNestedStop())
    }

    func testMockURLProtocolHandlerRegistrationIsAtomic() async throws {
        MockURLProtocol.resetHandlers()

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<250 {
                group.addTask {
                    MockURLProtocol.setHandler(for: "atomic-registration-\(index)") { _ in
                        (.success(Data()), 200)
                    }
                }
            }
        }

        XCTAssertEqual(MockURLProtocol.handlerCount(), 250)
    }

    func testRemoveHandlerRemovesOnlyThatEndpoint() {
        MockURLProtocol.resetHandlers()
        MockURLProtocol.setHandler(for: "keep-me") { _ in (.success(Data()), 200) }
        MockURLProtocol.setHandler(for: "remove-me") { _ in (.success(Data()), 200) }

        MockURLProtocol.removeHandler(for: "remove-me")

        XCTAssertEqual(MockURLProtocol.handlerCount(), 1)
        let kept = URLRequest(url: URL(string: "https://example.com/keep-me")!)
        let removed = URLRequest(url: URL(string: "https://example.com/remove-me")!)
        XCTAssertTrue(MockURLProtocol.canInit(with: kept), "remaining endpoint must still intercept")
        XCTAssertFalse(MockURLProtocol.canInit(with: removed), "removed endpoint must no longer intercept")
    }

    /// Pins the fail-fast interception: a request to a known API host with no registered
    /// handler must fail immediately with resourceUnavailable — never escape to the real
    /// network, where an unmocked call has no bounded timeout and can hang CI.
    func testUnmockedRequestToKnownHostFailsFast() async throws {
        MockURLProtocol.resetHandlers()
        let session = URLSession(configuration: MockURLProtocol.configuration)
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        do {
            _ = try await session.data(for: request)
            XCTFail("Unmocked request to a known API host must fail fast, not reach the network")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .resourceUnavailable,
                           "Fail-fast interception should surface resourceUnavailable, got \(error)")
        }
    }

    // MARK: - LangToolsError Tests

    func testLangToolsErrorInvalidData() {
        let error = LangToolsError.invalidData
        XCTAssertNotNil(error)
    }

    func testLangToolsErrorInvalidContentType() {
        let error = LangToolsError.invalidContentType
        XCTAssertNotNil(error)
    }

    func testLangToolsErrorInvalidArgument() {
        let error = LangToolsError.invalidArgument("test argument")
        if case .invalidArgument(let message) = error {
            XCTAssertEqual(message, "test argument")
        } else {
            XCTFail("Expected invalidArgument error")
        }
    }

    func testLangToolsErrorResponseUnsuccessful() {
        let error = LangToolsError.responseUnsuccessful(statusCode: 404, nil)
        if case .responseUnsuccessful(let statusCode, _) = error {
            XCTAssertEqual(statusCode, 404)
        } else {
            XCTFail("Expected responseUnsuccessful error")
        }
    }

    // MARK: - LangToolsRole Tests

    func testLangToolsRoleImpl() {
        let systemRole = LangToolsRoleImpl.system
        XCTAssertTrue(systemRole.isSystem)
        XCTAssertFalse(systemRole.isUser)
        XCTAssertFalse(systemRole.isAssistant)
        XCTAssertFalse(systemRole.isTool)

        let userRole = LangToolsRoleImpl.user
        XCTAssertTrue(userRole.isUser)
        XCTAssertFalse(userRole.isSystem)

        let assistantRole = LangToolsRoleImpl.assistant
        XCTAssertTrue(assistantRole.isAssistant)
        XCTAssertFalse(assistantRole.isUser)

        let toolRole = LangToolsRoleImpl.tool
        XCTAssertTrue(toolRole.isTool)
        XCTAssertFalse(toolRole.isAssistant)
    }

    // MARK: - LangToolsContent Tests

    func testLangToolsTextContent() {
        let content = LangToolsTextContent(text: "Hello, World!")
        XCTAssertEqual(content.text, "Hello, World!")
        XCTAssertEqual(content.string, "Hello, World!")
        XCTAssertEqual(content.type, "text")
    }

    func testLangToolsTextContentExpressibleByStringLiteral() {
        let content: LangToolsTextContent = "Test message"
        XCTAssertEqual(content.text, "Test message")
    }

    func testLangToolsTextContentFromContent() {
        let original = LangToolsTextContent(text: "Original text")
        let copy = LangToolsTextContent(original)
        XCTAssertEqual(copy.text, "Original text")
    }

    // MARK: - LangToolsMessage Tests

    func testLangToolsMessageImpl() {
        let message = LangToolsMessageImpl<LangToolsTextContent>(role: .user, string: "Hello")
        XCTAssertTrue(message.role.isUser)
        XCTAssertEqual(message.content.text, "Hello")
    }

    // MARK: - HTTP Error Response Tests

    func testErrorResponse() async throws {
        MockURLProtocol.setHandler(for: MockRequest.endpoint) { request in
            return (.success(Data()), 500)
        }

        do {
            _ = try await api.perform(request: MockRequest())
            XCTFail("Expected error to be thrown")
        } catch let error as LangToolsError {
            if case .responseUnsuccessful(let statusCode, _) = error {
                XCTAssertEqual(statusCode, 500)
            } else {
                XCTFail("Expected responseUnsuccessful error")
            }
        }
    }
}

private final class BlockingStreamingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var started = DispatchSemaphore(value: 0)
    private static var stopped = DispatchSemaphore(value: 0)

    static func reset() {
        lock.lock()
        started = DispatchSemaphore(value: 0)
        stopped = DispatchSemaphore(value: 0)
        lock.unlock()
    }

    static func waitForStart() -> Bool {
        lock.lock()
        let semaphore = started
        lock.unlock()
        return semaphore.wait(timeout: .now() + 2) == .success
    }

    static func waitForStop() -> Bool {
        lock.lock()
        let semaphore = stopped
        lock.unlock()
        return semaphore.wait(timeout: .now() + 2) == .success
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "api.openai.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        Self.signalStart()
    }

    override func stopLoading() {
        Self.signalStop()
    }

    private static func signalStart() {
        lock.lock()
        let semaphore = started
        lock.unlock()
        semaphore.signal()
    }

    private static func signalStop() {
        lock.lock()
        let semaphore = stopped
        lock.unlock()
        semaphore.signal()
    }
}

private struct ToolCallingMockRequest: LangToolsToolCallingRequest, LangToolsStreamableRequest {
    typealias LangTool = MockLangTool
    typealias Response = ToolCallingMockResponse
    typealias Message = MockMessage
    typealias Tool = ToolCallbackMockTool

    static let endpoint = "tool-callback-test"
    var model: MockModel = .mockModel
    var messages: [MockMessage] = []
    var tools: [Tool]?
    var stream: Bool?
    var toolEventHandler: ((LangToolsToolEvent) -> Void)?

    init(tools: [ToolCallbackMockTool]) {
        self.tools = tools
    }

    init(model: MockModel, messages: [any LangToolsMessage]) {
        self.model = model
        self.messages = messages.compactMap { $0 as? MockMessage }
    }

    init(from decoder: Decoder) throws {
        self.init(tools: [])
    }

    func encode(to encoder: Encoder) throws {}
}

extension MockMessage: LangToolsToolMessage {}

private typealias ToolCallbackMockTool = Tool

private struct ToolCallingMockResponse: Codable, LangToolsToolCallingResponse, LangToolsStreamableResponse {
    typealias Message = MockMessage
    typealias ToolSelection = MockToolSelection
    typealias Delta = MockDelta

    var message: MockMessage?
    var delta: MockDelta?

    static var empty: Self { .init(message: nil) }

    func combining(with next: Self) -> Self {
        .init(message: next.message ?? message, delta: next.delta ?? delta)
    }
}

private actor ToolCallbackTracker {
    private var invocations: [String] = []

    func record(_ name: String) {
        invocations.append(name)
    }

    func all() -> [String] {
        invocations
    }
}

private final class ToolEventTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func record(_ event: LangToolsToolEvent) {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case .toolCalled(let selection):
            values.append("called:\(selection.name ?? "nil")")
        case .toolCompleted(let result):
            values.append("completed:\(result?.tool_selection_id ?? "nil")")
        }
    }

    func all() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private final class CancellableStreamProducer: @unchecked Sendable {
    private var start = DispatchSemaphore(value: 0)
    private var cancellation = DispatchSemaphore(value: 0)

    func started() {
        start.signal()
    }

    func cancelled() {
        cancellation.signal()
    }

    func waitForStart() -> Bool {
        start.wait(timeout: .now() + 2) == .success
    }

    func waitForCancellation() -> Bool {
        cancellation.wait(timeout: .now() + 2) == .success
    }
}

private final class NestedToolStreamingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var requestCount = 0
    private static var initialResponse = Data()
    private static var nestedStarted = DispatchSemaphore(value: 0)
    private static var nestedStopped = DispatchSemaphore(value: 0)

    static func reset(initialResponse: Data) {
        lock.lock()
        requestCount = 0
        self.initialResponse = initialResponse
        nestedStarted = DispatchSemaphore(value: 0)
        nestedStopped = DispatchSemaphore(value: 0)
        lock.unlock()
    }

    static func waitForNestedStart() -> Bool {
        lock.lock()
        let semaphore = nestedStarted
        lock.unlock()
        return semaphore.wait(timeout: .now() + 2) == .success
    }

    static func waitForNestedStop() -> Bool {
        lock.lock()
        let semaphore = nestedStopped
        lock.unlock()
        return semaphore.wait(timeout: .now() + 2) == .success
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "localhost"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.lock.lock()
        let isNestedRequest = Self.requestCount > 0
        Self.requestCount += 1
        let data = Self.initialResponse
        let semaphore = Self.nestedStarted
        Self.lock.unlock()
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if isNestedRequest {
            semaphore.signal()
            return
        }
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        Self.lock.lock()
        let semaphore = Self.nestedStopped
        Self.lock.unlock()
        semaphore.signal()
    }
}
