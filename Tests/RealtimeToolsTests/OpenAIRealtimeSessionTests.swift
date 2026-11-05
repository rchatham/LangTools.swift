//
//  OpenAIRealtimeSessionTests.swift
//  LangTools
//
//  Created by Reid Chatham on 1/16/26.
//

import XCTest
@testable import OpenAI
@testable import RealtimeTools
@testable import LangTools
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Mock WebSocket Transport

/// Scripted WebSocket transport: captures sent messages and lets tests
/// push server messages that the session's receive loop will consume.
final class MockWebSocketTask: LangToolsWebSocketTask, @unchecked Sendable {
    private let lock = NSLock()
    private var _sentMessages: [String] = []
    private var pending: [URLSessionWebSocketTask.Message] = []
    private var waiters: [CheckedContinuation<URLSessionWebSocketTask.Message, Error>] = []
    private var closed = false
    private var inFlightSends = 0
    private var _maxConcurrentSends = 0
    private(set) var resumeCallCount = 0

    /// How long each send stays in flight, to widen the window for overlap.
    var sendDelayNanoseconds: UInt64 = 0
    /// When true, every send throws.
    var failSends = false

    var maxConcurrentSends: Int {
        lock.lock(); defer { lock.unlock() }
        return _maxConcurrentSends
    }

    var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    var sentMessages: [String] {
        lock.lock(); defer { lock.unlock() }
        return _sentMessages
    }

    func resume() {
        lock.lock(); resumeCallCount += 1; lock.unlock()
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        lock.lock()
        closed = true
        let pendingWaiters = waiters
        waiters = []
        lock.unlock()
        for waiter in pendingWaiters {
            waiter.resume(throwing: URLError(.cancelled))
        }
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        let delay = try beginSend()
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        endSend(message)
    }

    private func beginSend() throws -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        if closed { throw URLError(.cancelled) }
        if failSends { throw URLError(.networkConnectionLost) }
        inFlightSends += 1
        _maxConcurrentSends = max(_maxConcurrentSends, inFlightSends)
        return sendDelayNanoseconds
    }

    private func endSend(_ message: URLSessionWebSocketTask.Message) {
        lock.lock()
        defer { lock.unlock() }
        inFlightSends -= 1
        if case .string(let text) = message {
            _sentMessages.append(text)
        }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        lock.lock()
        if !pending.isEmpty {
            let message = pending.removeFirst()
            lock.unlock()
            return message
        }
        if closed {
            lock.unlock()
            throw URLError(.cancelled)
        }
        lock.unlock()
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !pending.isEmpty {
                let message = pending.removeFirst()
                lock.unlock()
                continuation.resume(returning: message)
            } else if closed {
                lock.unlock()
                continuation.resume(throwing: URLError(.cancelled))
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    /// Push a server message to be delivered to the session's receive loop.
    func push(_ text: String) {
        lock.lock()
        if waiters.isEmpty {
            pending.append(.string(text))
            lock.unlock()
        } else {
            let waiter = waiters.removeFirst()
            lock.unlock()
            waiter.resume(returning: .string(text))
        }
    }
}

// MARK: - Session Integration Tests

final class OpenAIRealtimeSessionTests: XCTestCase {

    private func makeConnectedSession() async throws -> (OpenAIRealtimeSession, MockWebSocketTask) {
        let mock = MockWebSocketTask()
        let session = OpenAIRealtimeSession(apiKey: "test-key")
        session.webSocketTaskFactory = { _ in mock }
        try await session.connect()
        return (session, mock)
    }

    private let sessionCreatedJSON = """
    {"type":"session.created","event_id":"evt_1","session":{"id":"sess_abc","object":"realtime.session","model":"gpt-4o-realtime-preview"}}
    """

    func testConnectResumesTransportAndSetsState() async throws {
        let (session, mock) = try await makeConnectedSession()
        XCTAssertEqual(session.state, .connected)
        XCTAssertEqual(mock.resumeCallCount, 1)
        await session.disconnect()
    }

    func testServerEventFlowsThroughEventsStream() async throws {
        let (session, mock) = try await makeConnectedSession()

        mock.push(sessionCreatedJSON)

        var iterator = session.events.makeAsyncIterator()
        let event = try await iterator.next()

        guard case .sessionCreated(let created)? = event else {
            return XCTFail("Expected sessionCreated, got \(String(describing: event))")
        }
        XCTAssertEqual(created.session.id, "sess_abc")
        await session.disconnect()
    }

    func testEventsPushedBeforeConsumerAttachesAreBuffered() async throws {
        let (session, mock) = try await makeConnectedSession()

        // Push BEFORE any consumer touches `events` — with the old computed
        // property pattern this event was dropped.
        mock.push(sessionCreatedJSON)

        // Wait for a deterministic signal that the receive loop ingested the
        // event: handleServerEvent sets sessionId before yielding to the
        // stream, so once it's visible the yield has already happened.
        let deadline = Date().addingTimeInterval(5)
        while session.sessionId.isEmpty && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(session.sessionId, "sess_abc", "Receive loop did not ingest the pushed event in time")

        var iterator = session.events.makeAsyncIterator()
        let event = try await iterator.next()
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.type, "session.created")
        await session.disconnect()
    }

    func testSessionIdUpdatedFromSessionCreatedEvent() async throws {
        let (session, mock) = try await makeConnectedSession()
        XCTAssertEqual(session.sessionId, "")

        mock.push(sessionCreatedJSON)
        var iterator = session.events.makeAsyncIterator()
        _ = try await iterator.next()

        XCTAssertEqual(session.sessionId, "sess_abc")
        await session.disconnect()
    }

    func testIsGeneratingTracksResponseLifecycle() async throws {
        let (session, mock) = try await makeConnectedSession()
        XCTAssertFalse(session.isGenerating)

        mock.push("""
        {"type":"response.created","event_id":"evt_2","response":{"id":"resp_1","object":"realtime.response","status":"in_progress"}}
        """)
        var iterator = session.events.makeAsyncIterator()
        _ = try await iterator.next()
        XCTAssertTrue(session.isGenerating)

        mock.push("""
        {"type":"response.done","event_id":"evt_3","response":{"id":"resp_1","object":"realtime.response","status":"completed"}}
        """)
        _ = try await iterator.next()
        XCTAssertFalse(session.isGenerating)
        await session.disconnect()
    }

    func testSendEncodesClientEventToTransport() async throws {
        let (session, mock) = try await makeConnectedSession()

        try await session.send(event: .responseCancel(ResponseCancelEvent()))

        XCTAssertEqual(mock.sentMessages.count, 1)
        XCTAssertTrue(mock.sentMessages[0].contains("\"type\":\"response.cancel\""), "Got: \(mock.sentMessages)")
        await session.disconnect()
    }

    func testAppendAudioSendsBase64Payload() async throws {
        let (session, mock) = try await makeConnectedSession()

        let audio = Data("hello".utf8)
        try await session.append(audio: audio)

        XCTAssertEqual(mock.sentMessages.count, 1)
        XCTAssertTrue(mock.sentMessages[0].contains("input_audio_buffer.append"))
        XCTAssertTrue(mock.sentMessages[0].contains(audio.base64EncodedString()))
        await session.disconnect()
    }

    /// Regression test: concurrent callers (e.g. a mic loop appending audio)
    /// must not have two sends in flight on the socket at once.
    func testConcurrentSendsNeverOverlapOnTheSocket() async throws {
        let (session, mock) = try await makeConnectedSession()
        mock.sendDelayNanoseconds = 20_000_000

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<8 {
                group.addTask { try? await session.append(audio: Data([UInt8(i)])) }
            }
        }

        XCTAssertEqual(mock.sentMessages.count, 8)
        XCTAssertEqual(mock.maxConcurrentSends, 1, "Sends overlapped on the socket")
        await session.disconnect()
    }

    func testUpdateSessionSendsFunctionToolChoiceAsObject() async throws {
        let (session, mock) = try await makeConnectedSession()

        try await session.updateSession(configuration: RealtimeSessionConfiguration(toolChoice: .function("get_weather")))

        let sent = try XCTUnwrap(mock.sentMessages.last)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(sent.utf8)) as? [String: Any])
        let sessionJSON = try XCTUnwrap(json["session"] as? [String: Any])
        XCTAssertEqual(sessionJSON["tool_choice"] as? [String: String], ["type": "function", "name": "get_weather"])
        await session.disconnect()
    }

    func testModelIsPercentEncodedInConnectURL() async throws {
        let mock = MockWebSocketTask()
        let session = OpenAIRealtimeSession(apiKey: "test-key", model: "custom model&x=1")
        var requestedURL: URL?
        session.webSocketTaskFactory = { request in
            requestedURL = request.url
            return mock
        }
        try await session.connect()

        let url = try XCTUnwrap(requestedURL)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items?.count, 1, "A raw '&' in the model would add a stray query item")
        XCTAssertEqual(items?.first?.name, "model")
        XCTAssertEqual(items?.first?.value, "custom model&x=1")
        await session.disconnect()
    }

    func testConnectAfterDisconnectThrowsSessionClosed() async throws {
        let (session, _) = try await makeConnectedSession()
        await session.disconnect()

        do {
            try await session.connect()
            XCTFail("Expected sessionClosed")
        } catch let error as OpenAIRealtimeError {
            guard case .sessionClosed = error else {
                return XCTFail("Expected sessionClosed, got \(error)")
            }
        }
    }

    /// Regression test: state used to stay .connected after the socket
    /// failed, so the session looked usable while `events` had ended.
    func testSocketFailureMovesStateToErrorAndClosesSession() async throws {
        let (session, mock) = try await makeConnectedSession()

        mock.cancel(with: .goingAway, reason: nil)

        var iterator = session.events.makeAsyncIterator()
        do {
            while try await iterator.next() != nil {}
            XCTFail("Expected the events stream to throw")
        } catch {}

        XCTAssertEqual(session.state, .error)
        do {
            try await session.connect()
            XCTFail("Expected sessionClosed")
        } catch let error as OpenAIRealtimeError {
            guard case .sessionClosed = error else {
                return XCTFail("Expected sessionClosed, got \(error)")
            }
        }
    }

    func testSendWhileDisconnectedThrows() async throws {
        let session = OpenAIRealtimeSession(apiKey: "test-key")
        do {
            try await session.send(event: .responseCancel(ResponseCancelEvent()))
            XCTFail("Expected notConnected error")
        } catch let error as OpenAIRealtimeError {
            guard case .notConnected = error else {
                return XCTFail("Expected notConnected, got \(error)")
            }
        }
    }

    func testMalformedServerEventDoesNotKillStream() async throws {
        let (session, mock) = try await makeConnectedSession()

        mock.push("{not valid json")
        mock.push(sessionCreatedJSON)

        var iterator = session.events.makeAsyncIterator()
        let event = try await iterator.next()
        XCTAssertEqual(event?.type, "session.created", "Stream should skip the malformed event and deliver the next one")
        await session.disconnect()
    }

    func testDisconnectFinishesEventsStream() async throws {
        let (session, _) = try await makeConnectedSession()
        await session.disconnect()

        var iterator = session.events.makeAsyncIterator()
        let event = try? await iterator.next()
        XCTAssertNil(event ?? nil)
        XCTAssertEqual(session.state, .disconnected)
    }
}

// MARK: - Pipeline Mode Tests

final class RealtimePipelineModeTests: XCTestCase {

    /// TTS stub that records synthesized text and returns a one-chunk stream
    /// per call, whose single byte is the call's 1-based index.
    private final class StubTTS: RealtimeTools.TTSProvider, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var synthesized: [String] = []
        var isSynthesizing: Bool = false

        func synthesize(text: String) async throws -> AsyncThrowingStream<Data, Error> {
            lock.lock()
            synthesized.append(text)
            let index = UInt8(synthesized.count)
            lock.unlock()
            let (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
            continuation.yield(Data([index]))
            continuation.finish()
            return stream
        }

        func cancel() async throws {}
    }

    func testModularModeWithoutTextProcessorThrows() async throws {
        let pipeline = RealtimePipelineBuilder()
            .withMode(.modular)
            .build()
        pipeline.setProviders(tts: StubTTS())
        try await pipeline.start()

        do {
            try await pipeline.sendText("hello")
            XCTFail("Expected providerNotConfigured error")
        } catch let error as RealtimePipelineError {
            guard case .providerNotConfigured = error else {
                return XCTFail("Expected providerNotConfigured, got \(error)")
            }
        }
    }

    func testModularModeRunsTextProcessorBeforeTTS() async throws {
        let tts = StubTTS()
        let pipeline = RealtimePipelineBuilder()
            .withMode(.modular)
            .build()
        pipeline.setProviders(tts: tts)
        pipeline.textProcessor = { text in "LLM(\(text))" }
        try await pipeline.start()

        try await pipeline.sendText("hello")

        XCTAssertEqual(tts.synthesized, ["LLM(hello)"])
    }

    /// Regression test: TTSProvider used to expose one shared audioStream,
    /// which the first turn finished, so every later turn produced no audio.
    func testConsecutiveTurnsEachDeliverTheirOwnAudio() async throws {
        let tts = StubTTS()
        let pipeline = RealtimePipelineBuilder()
            .withMode(.modular)
            .build()
        pipeline.setProviders(tts: tts)
        pipeline.textProcessor = { text in "LLM(\(text))" }

        let lock = NSLock()
        var audio: [Data] = []
        let handler = RealtimeEventHandler()
        handler.onAudioReceived = { data in
            lock.lock(); audio.append(data); lock.unlock()
        }
        pipeline.eventHandler = handler
        try await pipeline.start()

        try await pipeline.sendText("first")
        try await pipeline.sendText("second")

        XCTAssertEqual(tts.synthesized, ["LLM(first)", "LLM(second)"])
        lock.lock()
        let received = audio
        lock.unlock()
        XCTAssertEqual(received, [Data([1]), Data([2])], "Each turn should deliver its own audio")
    }

    func testSpeechToSpeechModeThrowsNotImplemented() async throws {
        let pipeline = RealtimePipelineBuilder.openAIRealtime().build()
        try await pipeline.start()

        do {
            try await pipeline.sendText("hello")
            XCTFail("Expected notImplemented error")
        } catch let error as RealtimePipelineError {
            guard case .notImplemented = error else {
                return XCTFail("Expected notImplemented, got \(error)")
            }
        }

        do {
            try await pipeline.sendAudio(Data([0x00]))
            XCTFail("Expected notImplemented error")
        } catch let error as RealtimePipelineError {
            guard case .notImplemented = error else {
                return XCTFail("Expected notImplemented, got \(error)")
            }
        }
    }

    func testSpeechOnlyModeSynthesizesDirectly() async throws {
        let tts = StubTTS()
        let pipeline = RealtimePipelineBuilder()
            .withMode(.speechOnly)
            .build()
        pipeline.setProviders(tts: tts)
        try await pipeline.start()

        try await pipeline.sendText("read this")

        XCTAssertEqual(tts.synthesized, ["read this"])
    }

    // MARK: - STT Wiring

    /// STT stub that hands out a fresh stream per session; push() yields
    /// into the current session's stream.
    private final class StubSTT: RealtimeTools.STTProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: AsyncThrowingStream<TranscriptionResult, Error>.Continuation?
        private var _startCount = 0

        var startCount: Int {
            lock.lock(); defer { lock.unlock() }
            return _startCount
        }

        func startTranscription() async throws -> AsyncThrowingStream<TranscriptionResult, Error> {
            let (stream, continuation) = AsyncThrowingStream.makeStream(of: TranscriptionResult.self)
            beginSession(continuation)
            return stream
        }

        func stopTranscription() async throws {
            endSession()?.finish()
        }

        func transcribe(audio: Data) async throws {}

        func push(_ result: TranscriptionResult) {
            lock.lock()
            let continuation = self.continuation
            lock.unlock()
            continuation?.yield(result)
        }

        private func beginSession(_ continuation: AsyncThrowingStream<TranscriptionResult, Error>.Continuation) {
            lock.lock()
            self.continuation = continuation
            _startCount += 1
            lock.unlock()
        }

        private func endSession() -> AsyncThrowingStream<TranscriptionResult, Error>.Continuation? {
            lock.lock()
            defer { continuation = nil; lock.unlock() }
            return continuation
        }
    }

    /// Polls `condition` until it holds or the timeout passes.
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// STT whose startTranscription() blocks until release(), holding
    /// start() in .starting; counts stopTranscription() calls.
    private final class GatedSTT: RealtimeTools.STTProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var released = false
        private var waiter: CheckedContinuation<Void, Never>?
        private var _stopCount = 0
        private var _startCount = 0

        var startCount: Int {
            lock.lock(); defer { lock.unlock() }
            return _startCount
        }

        var stopCount: Int {
            lock.lock(); defer { lock.unlock() }
            return _stopCount
        }

        func startTranscription() async throws -> AsyncThrowingStream<TranscriptionResult, Error> {
            countStart()
            await withCheckedContinuation { continuation in
                if !park(continuation) { continuation.resume() }
            }
            return AsyncThrowingStream { _ in }
        }

        func stopTranscription() async throws {
            countStop()
        }

        func transcribe(audio: Data) async throws {}

        func release() {
            lock.lock()
            released = true
            let pending = waiter
            waiter = nil
            lock.unlock()
            pending?.resume()
        }

        private func countStart() {
            lock.lock(); _startCount += 1; lock.unlock()
        }

        private func park(_ continuation: CheckedContinuation<Void, Never>) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !released else { return false }
            waiter = continuation
            return true
        }

        private func countStop() {
            lock.lock(); _stopCount += 1; lock.unlock()
        }
    }

    /// Regression test: a stop() while start() was initializing providers
    /// was ignored, and the pipeline then went to .running anyway.
    func testStopDuringStartIsNotLost() async throws {
        let stt = GatedSTT()
        let pipeline = RealtimePipelineBuilder()
            .withMode(.transcriptionOnly)
            .build()
        pipeline.setProviders(stt: stt)

        let starting = Task { try await pipeline.start() }
        let deadline = Date().addingTimeInterval(5)
        while pipeline.state != .starting && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(pipeline.state, .starting)

        await pipeline.stop()
        stt.release()
        try await starting.value

        XCTAssertEqual(pipeline.state, .stopped, "start() must not override the stop")
        XCTAssertGreaterThanOrEqual(stt.stopCount, 2, "The STT session start() opened after the stop must be stopped too")
    }

    /// TTS whose stream stays open until cancel(), which then fails it the
    /// way a real provider's cancelled stream does.
    private final class CancellableTTS: RealtimeTools.TTSProvider, @unchecked Sendable {
        struct Cancelled: Error {}
        var isSynthesizing = false
        private let lock = NSLock()
        private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
        private var _cancelCount = 0

        var cancelCount: Int { lock.lock(); defer { lock.unlock() }; return _cancelCount }
        var isStreaming: Bool { lock.lock(); defer { lock.unlock() }; return continuation != nil }

        func synthesize(text: String) async throws -> AsyncThrowingStream<Data, Error> {
            let (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
            continuation.yield(Data([0x01]))
            store(continuation)
            return stream
        }

        func cancel() async throws {
            lock.lock()
            _cancelCount += 1
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.finish(throwing: Cancelled())
        }

        private func store(_ c: AsyncThrowingStream<Data, Error>.Continuation) {
            lock.lock(); continuation = c; lock.unlock()
        }
    }

    /// Regression tests: interrupt() only worked from .processing, so a
    /// manual interrupt while a reply played (.running) did nothing, and a
    /// cancelled reply's stream error surfaced as a failure.
    func testManualInterruptDuringPlaybackStopsReplyWithoutError() async throws {
        let tts = CancellableTTS()
        let pipeline = RealtimePipelineBuilder()
            .withMode(.speechOnly)
            .build()
        pipeline.setProviders(tts: tts)
        try await pipeline.start()
        XCTAssertEqual(pipeline.state, .running)

        let speaking = Task { try await pipeline.sendText("hello") }
        let deadline = Date().addingTimeInterval(5)
        while !tts.isStreaming && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(tts.isStreaming)

        try await pipeline.interrupt()
        XCTAssertEqual(tts.cancelCount, 1, "A manual interrupt during playback must cancel TTS")
        do {
            try await speaking.value
        } catch {
            XCTFail("An interrupted reply shouldn't fail: \(error)")
        }
        XCTAssertEqual(pipeline.state, .running)
        await pipeline.stop()
    }

    /// Regression test: start() read the state and set .starting in two
    /// steps, so concurrent calls could both initialize providers.
    func testConcurrentStartsInitializeOnce() async throws {
        let stt = GatedSTT()
        let pipeline = RealtimePipelineBuilder()
            .withMode(.transcriptionOnly)
            .build()
        pipeline.setProviders(stt: stt)

        let first = Task { try await pipeline.start() }
        let second = Task { try await pipeline.start() }
        let deadline = Date().addingTimeInterval(5)
        while stt.startCount == 0 && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        stt.release()
        try await first.value
        try await second.value

        XCTAssertEqual(stt.startCount, 1)
        XCTAssertEqual(pipeline.state, .running)
        await pipeline.stop()
    }

    /// Regression test: a start() that failed partway left what it had set
    /// up attached; it now releases it and can be retried.
    func testFailedStartReleasesProvidersAndCanRetry() async throws {
        struct STTFailure: Error {}
        final class FailingOnceSTT: RealtimeTools.STTProvider, @unchecked Sendable {
            private let lock = NSLock()
            private var _calls = 0
            private var _stops = 0
            var stops: Int { lock.lock(); defer { lock.unlock() }; return _stops }
            func startTranscription() async throws -> AsyncThrowingStream<TranscriptionResult, Error> {
                if nextCall() == 1 { throw STTFailure() }
                return AsyncThrowingStream { _ in }
            }
            func stopTranscription() async throws { lock.lock(); _stops += 1; lock.unlock() }
            func transcribe(audio: Data) async throws {}
            private func nextCall() -> Int { lock.lock(); defer { lock.unlock() }; _calls += 1; return _calls }
        }

        let stt = FailingOnceSTT()
        let pipeline = RealtimePipelineBuilder()
            .withMode(.transcriptionOnly)
            .build()
        pipeline.setProviders(stt: stt)

        do {
            try await pipeline.start()
            XCTFail("Expected start() to throw")
        } catch is STTFailure {}
        XCTAssertEqual(pipeline.state, .idle)
        XCTAssertEqual(stt.stops, 1, "The failed start should release its providers")

        try await pipeline.start()
        XCTAssertEqual(pipeline.state, .running)
        await pipeline.stop()
    }

    /// Regression test: a failing LLM/TTS step on a speech-driven turn was
    /// swallowed (`try?`), so nothing reported why no reply came back.
    func testSpeechDrivenTurnFailureReachesOnError() async throws {
        struct LLMFailure: Error {}
        let stt = StubSTT()
        let pipeline = RealtimePipelineBuilder()
            .withMode(.modular)
            .build()
        pipeline.setProviders(stt: stt, tts: StubTTS())
        pipeline.textProcessor = { _ in throw LLMFailure() }

        let reported = expectation(description: "onError fired")
        let handler = RealtimeEventHandler()
        handler.onError = { error in
            if error is LLMFailure { reported.fulfill() }
        }
        pipeline.eventHandler = handler
        try await pipeline.start()

        stt.push(TranscriptionResult(text: "hello", isFinal: true))

        await fulfillment(of: [reported], timeout: 5)
        await pipeline.stop()
    }

    /// Regression test: STTProvider used to expose one long-lived stream.
    /// stop() cancelled its consumer, which terminated that stream, so a
    /// restarted pipeline never received another transcription.
    func testRestartedPipelineReceivesTranscriptionsAgain() async throws {
        let stt = StubSTT()
        let tts = StubTTS()
        let pipeline = RealtimePipelineBuilder()
            .withMode(.modular)
            .build()
        pipeline.setProviders(stt: stt, tts: tts)
        pipeline.textProcessor = { text in "LLM(\(text))" }

        try await pipeline.start()
        stt.push(TranscriptionResult(text: "one", isFinal: true))
        try await waitUntil { tts.synthesized.count == 1 }

        await pipeline.stop()
        try await pipeline.start()
        stt.push(TranscriptionResult(text: "two", isFinal: true))
        try await waitUntil { tts.synthesized.count == 2 }

        XCTAssertEqual(tts.synthesized, ["LLM(one)", "LLM(two)"])
        XCTAssertEqual(stt.startCount, 2, "Each start() should begin a new STT session")
    }

    func testModularModeDrivesTextProcessorFromFinalSTTTranscription() async throws {
        let stt = StubSTT()
        let tts = StubTTS()
        let pipeline = RealtimePipelineBuilder()
            .withMode(.modular)
            .build()
        pipeline.setProviders(stt: stt, tts: tts)
        pipeline.textProcessor = { text in "LLM(\(text))" }
        try await pipeline.start()

        // Partial transcriptions must not trigger the LLM/TTS steps
        stt.push(TranscriptionResult(text: "hel", isFinal: false))
        stt.push(TranscriptionResult(text: "hello", isFinal: true))

        let deadline = Date().addingTimeInterval(5)
        while tts.synthesized.isEmpty && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(tts.synthesized, ["LLM(hello)"], "Final STT transcription should drive textProcessor then TTS")
    }

    func testTranscriptionOnlyModeSurfacesResultsWithoutTTS() async throws {
        let stt = StubSTT()
        let pipeline = RealtimePipelineBuilder.transcriptionOnly().build()
        pipeline.setProviders(stt: stt)

        let lock = NSLock()
        var received: [(String, Bool)] = []
        let handler = RealtimeEventHandler()
        handler.onTranscriptReceived = { text, isFinal in
            lock.lock(); received.append((text, isFinal)); lock.unlock()
        }
        pipeline.eventHandler = handler
        try await pipeline.start()

        stt.push(TranscriptionResult(text: "hi", isFinal: true))

        func isEmpty() -> Bool {
            lock.lock(); defer { lock.unlock() }
            return received.isEmpty
        }

        let deadline = Date().addingTimeInterval(5)
        while isEmpty() && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        lock.lock()
        let result = received
        lock.unlock()
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.0, "hi")
        XCTAssertEqual(result.first?.1, true)
    }
}

// MARK: - Pipeline State Machine Regression Tests

final class RealtimePipelineStateMachineTests: XCTestCase {

    /// VAD test double whose results are pre-scripted, driving the
    /// InterruptionDetector deterministically without real audio analysis.
    private final class ControllableVAD: RealtimeTools.VoiceActivityDetector, @unchecked Sendable {
        var configuration: VADConfiguration
        private let lock = NSLock()
        private var queue: [VADResult] = []

        init(configuration: VADConfiguration) {
            self.configuration = configuration
        }

        func enqueue(_ result: VADResult) {
            lock.lock(); queue.append(result); lock.unlock()
        }

        func process(audio: Data) async -> VADResult {
            lock.lock()
            defer { lock.unlock() }
            return queue.isEmpty ? VADResult(isSpeech: false, probability: 0, timestamp: 0) : queue.removeFirst()
        }

        private var _resetCount = 0
        var resetCount: Int {
            lock.lock(); defer { lock.unlock() }
            return _resetCount
        }

        func reset() async {
            incrementResetCount()
        }

        private func incrementResetCount() {
            lock.lock(); _resetCount += 1; lock.unlock()
        }
    }

    /// TTS whose cancel() blocks until release(), holding interrupt() in
    /// its .interrupted window.
    private final class GatedTTS: RealtimeTools.TTSProvider, @unchecked Sendable {
        var isSynthesizing = false
        private let lock = NSLock()
        private var released = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func synthesize(text: String) async throws -> AsyncThrowingStream<Data, Error> {
            let (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
            continuation.finish()
            return stream
        }

        func cancel() async throws {
            await withCheckedContinuation { continuation in
                if !enqueue(continuation) { continuation.resume() }
            }
        }

        func release() {
            lock.lock()
            released = true
            let pending = waiters
            waiters = []
            lock.unlock()
            pending.forEach { $0.resume() }
        }

        /// Returns false if already released (the caller resumes directly).
        private func enqueue(_ continuation: CheckedContinuation<Void, Never>) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !released else { return false }
            waiters.append(continuation)
            return true
        }
    }

    /// Regression test: stop() during interrupt()'s .interrupted window was
    /// silently ignored (and the pipeline then went back to .running), and
    /// sendAudio() threw notRunning, dropping the user's barge-in speech.
    func testStopAndAudioDuringInterruptionAreNotLost() async throws {
        let vadConfig = VADConfiguration(mode: .onDevice, minSpeechDuration: 0, silenceTimeout: 0)
        let vad = ControllableVAD(configuration: vadConfig)
        let tts = GatedTTS()
        let pipeline = RealtimePipelineBuilder()
            .withMode(.modular)
            .withAudioSettings(AudioProcessingSettings(vadConfig: vadConfig))
            .build()
        pipeline.setProviders(tts: tts, vad: vad)
        try await pipeline.start()

        pipeline.notifyPlaybackStarted()
        // The first frame after the report anchors the 0.5 s grace period;
        // speech then commits at 0.75 s, past it.
        vad.enqueue(VADResult(isSpeech: false, probability: 0.1, timestamp: 0.00))
        try await pipeline.sendAudio(Data([0x00, 0x00]))
        vad.enqueue(VADResult(isSpeech: true, probability: 0.9, timestamp: 0.60))
        try await pipeline.sendAudio(Data([0x00, 0x00]))
        vad.enqueue(VADResult(isSpeech: true, probability: 0.9, timestamp: 0.75))
        try await pipeline.sendAudio(Data([0x00, 0x00]))

        let deadline = Date().addingTimeInterval(5)
        while pipeline.state != .interrupted && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(pipeline.state, .interrupted)

        // The user's speech keeps arriving during the barge-in.
        try await pipeline.sendAudio(Data([0x00, 0x00]))

        let stopping = Task { await pipeline.stop() }
        while pipeline.state == .interrupted && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        tts.release()
        await stopping.value

        // Give interrupt() time to finish; it must not revert to .running.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(pipeline.state, .stopped)
    }

    /// Regression test: the detector's barge-in used to go through a
    /// spawned interrupt() Task, so a silence frame right after it could
    /// fire .speechEnded first, move state to .running, and make the
    /// interrupt skip cancelling TTS.
    func testSpeechEndedRightAfterBargeInDoesNotSkipTheInterrupt() async throws {
        let vadConfig = VADConfiguration(mode: .onDevice, minSpeechDuration: 0, silenceTimeout: 0)
        let vad = ControllableVAD(configuration: vadConfig)
        let tts = GatedTTS()
        let pipeline = RealtimePipelineBuilder()
            .withMode(.modular)
            .withAudioSettings(AudioProcessingSettings(vadConfig: vadConfig))
            .build()
        pipeline.setProviders(tts: tts, vad: vad)
        try await pipeline.start()

        pipeline.notifyPlaybackStarted()
        vad.enqueue(VADResult(isSpeech: false, probability: 0.1, timestamp: 0.00))
        try await pipeline.sendAudio(Data([0x00, 0x00]))
        vad.enqueue(VADResult(isSpeech: true, probability: 0.9, timestamp: 0.60))
        try await pipeline.sendAudio(Data([0x00, 0x00]))
        vad.enqueue(VADResult(isSpeech: true, probability: 0.9, timestamp: 0.75))
        try await pipeline.sendAudio(Data([0x00, 0x00]))

        // The barge-in is claimed synchronously, before any later frame.
        XCTAssertEqual(pipeline.state, .interrupted)

        // The user stops talking immediately.
        vad.enqueue(VADResult(isSpeech: false, probability: 0.1, timestamp: 0.80))
        try await pipeline.sendAudio(Data([0x00, 0x00]))
        vad.enqueue(VADResult(isSpeech: false, probability: 0.1, timestamp: 0.85))
        try await pipeline.sendAudio(Data([0x00, 0x00]))
        XCTAssertEqual(pipeline.state, .interrupted, ".speechEnded must not clobber an in-flight interrupt")

        tts.release()
        let deadline = Date().addingTimeInterval(5)
        while pipeline.state != .running && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(pipeline.state, .running)
        await pipeline.stop()
    }

    func testStopResetsTheVAD() async throws {
        let vadConfig = VADConfiguration(mode: .onDevice)
        let vad = ControllableVAD(configuration: vadConfig)
        let pipeline = RealtimePipelineBuilder()
            .withMode(.modular)
            .withAudioSettings(AudioProcessingSettings(vadConfig: vadConfig))
            .build()
        pipeline.setProviders(vad: vad)

        try await pipeline.start()
        await pipeline.stop()

        XCTAssertEqual(vad.resetCount, 1, "A restart shouldn't inherit the previous session's VAD state")
    }

    /// The documented barge-in wiring: with a VAD configured and the player
    /// reporting playback, user speech interrupts the reply.
    func testSpeechDuringReportedPlaybackFiresInterruption() async throws {
        let vadConfig = VADConfiguration(mode: .onDevice, minSpeechDuration: 0, silenceTimeout: 0)
        let vad = ControllableVAD(configuration: vadConfig)
        let pipeline = RealtimePipelineBuilder()
            .withMode(.modular)
            .withAudioSettings(AudioProcessingSettings(vadConfig: vadConfig))
            .build()
        pipeline.setProviders(vad: vad)

        let interrupted = expectation(description: "onInterruption fired")
        let handler = RealtimeEventHandler()
        handler.onInterruption = { interrupted.fulfill() }
        pipeline.eventHandler = handler
        try await pipeline.start()

        pipeline.notifyPlaybackStarted()
        // The first frame after the report anchors the 0.5 s grace period;
        // speech then commits at 0.75 s, past it.
        vad.enqueue(VADResult(isSpeech: false, probability: 0.1, timestamp: 0.00))
        try await pipeline.sendAudio(Data([0x00, 0x00]))
        vad.enqueue(VADResult(isSpeech: true, probability: 0.9, timestamp: 0.60))
        try await pipeline.sendAudio(Data([0x00, 0x00]))
        vad.enqueue(VADResult(isSpeech: true, probability: 0.9, timestamp: 0.75))
        try await pipeline.sendAudio(Data([0x00, 0x00]))

        await fulfillment(of: [interrupted], timeout: 5)
    }

    /// Regression test: notifyPlaybackStarted() without a timestamp skipped
    /// the grace period, so echo right after playback began interrupted it.
    func testSpeechInsideGracePeriodDoesNotInterrupt() async throws {
        let vadConfig = VADConfiguration(mode: .onDevice, minSpeechDuration: 0, silenceTimeout: 0)
        let vad = ControllableVAD(configuration: vadConfig)
        let pipeline = RealtimePipelineBuilder()
            .withMode(.modular)
            .withAudioSettings(AudioProcessingSettings(vadConfig: vadConfig))
            .build()
        pipeline.setProviders(vad: vad)

        let interrupted = expectation(description: "onInterruption fired")
        interrupted.isInverted = true
        let handler = RealtimeEventHandler()
        handler.onInterruption = { interrupted.fulfill() }
        pipeline.eventHandler = handler
        try await pipeline.start()

        pipeline.notifyPlaybackStarted()
        vad.enqueue(VADResult(isSpeech: true, probability: 0.9, timestamp: 0.00))
        try await pipeline.sendAudio(Data([0x00, 0x00]))
        vad.enqueue(VADResult(isSpeech: true, probability: 0.9, timestamp: 0.15))
        try await pipeline.sendAudio(Data([0x00, 0x00]))

        await fulfillment(of: [interrupted], timeout: 0.5)
    }

    /// Push-to-talk (.manual) leaves turns to the caller: no barge-in.
    func testManualVADModeNeverAutoInterrupts() async throws {
        let vadConfig = VADConfiguration(mode: .manual, minSpeechDuration: 0, silenceTimeout: 0)
        let vad = ControllableVAD(configuration: vadConfig)
        let pipeline = RealtimePipelineBuilder()
            .withMode(.modular)
            .withAudioSettings(AudioProcessingSettings(vadConfig: vadConfig))
            .build()
        pipeline.setProviders(vad: vad)

        let interrupted = expectation(description: "onInterruption fired")
        interrupted.isInverted = true
        let handler = RealtimeEventHandler()
        handler.onInterruption = { interrupted.fulfill() }
        pipeline.eventHandler = handler
        try await pipeline.start()

        pipeline.notifyPlaybackStarted()
        for t in [0.00, 0.60, 0.75] {
            vad.enqueue(VADResult(isSpeech: t > 0, probability: 0.9, timestamp: t))
            try await pipeline.sendAudio(Data([0x00, 0x00]))
        }

        await fulfillment(of: [interrupted], timeout: 0.5)
        // Push-to-talk: the injected VAD must not drive turn state either.
        XCTAssertEqual(pipeline.state, .running)
        await pipeline.stop()
    }

    /// Without a playback report, the same speech is a normal turn.
    func testSpeechWithoutReportedPlaybackDoesNotInterrupt() async throws {
        let vadConfig = VADConfiguration(mode: .onDevice, minSpeechDuration: 0, silenceTimeout: 0)
        let vad = ControllableVAD(configuration: vadConfig)
        let pipeline = RealtimePipelineBuilder()
            .withMode(.modular)
            .withAudioSettings(AudioProcessingSettings(vadConfig: vadConfig))
            .build()
        pipeline.setProviders(vad: vad)

        let interrupted = expectation(description: "onInterruption fired")
        interrupted.isInverted = true
        let handler = RealtimeEventHandler()
        handler.onInterruption = { interrupted.fulfill() }
        pipeline.eventHandler = handler
        try await pipeline.start()

        vad.enqueue(VADResult(isSpeech: true, probability: 0.9, timestamp: 0.00))
        try await pipeline.sendAudio(Data([0x00, 0x00]))
        vad.enqueue(VADResult(isSpeech: true, probability: 0.9, timestamp: 0.15))
        try await pipeline.sendAudio(Data([0x00, 0x00]))

        await fulfillment(of: [interrupted], timeout: 0.5)
        XCTAssertEqual(pipeline.state, .processing)
    }

    /// Regression test for a bug where a normal (non-interrupting) end of
    /// utterance left the pipeline stuck in `.processing` forever, since
    /// `.speechEnded` only forwarded the event to `onSpeechStopped` without
    /// resetting `isProcessing`/state back to `.running`.
    func testSpeechEndedResetsStateToRunning() async throws {
        let vadConfig = VADConfiguration(mode: .onDevice, minSpeechDuration: 0, silenceTimeout: 0)
        let vad = ControllableVAD(configuration: vadConfig)
        let pipeline = RealtimePipelineBuilder()
            .withMode(.modular)
            .withAudioSettings(AudioProcessingSettings(vadConfig: vadConfig))
            .build()
        pipeline.setProviders(vad: vad)
        try await pipeline.start()
        XCTAssertEqual(pipeline.state, .running)

        // Debounce/min-speech-duration requires >= 0.1s of continuous speech
        // (InterruptionConfiguration.speechDetectionDebounce default) before
        // speechStarted commits.
        vad.enqueue(VADResult(isSpeech: true, probability: 0.9, timestamp: 0.00))
        try await pipeline.sendAudio(Data([0x00, 0x00]))

        vad.enqueue(VADResult(isSpeech: true, probability: 0.9, timestamp: 0.15))
        try await pipeline.sendAudio(Data([0x00, 0x00]))
        XCTAssertEqual(pipeline.state, .processing, "Speech should have committed and moved the pipeline to .processing")

        vad.enqueue(VADResult(isSpeech: false, probability: 0.1, timestamp: 0.20))
        try await pipeline.sendAudio(Data([0x00, 0x00]))

        vad.enqueue(VADResult(isSpeech: false, probability: 0.1, timestamp: 0.21))
        try await pipeline.sendAudio(Data([0x00, 0x00]))

        XCTAssertEqual(pipeline.state, .running, "Normal end-of-utterance must return the pipeline to .running, not leave it stuck in .processing")
    }
}
