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
    private(set) var resumeCallCount = 0

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
        lock.lock()
        defer { lock.unlock() }
        if closed { throw URLError(.cancelled) }
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

        // Give the receive loop a chance to ingest the message
        try await Task.sleep(nanoseconds: 100_000_000)

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

    /// TTS stub that records synthesized text and emits one audio chunk per call
    private final class StubTTS: RealtimeTools.TTSProvider, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var synthesized: [String] = []
        let audioStream: AsyncThrowingStream<Data, Error>
        private let continuation: AsyncThrowingStream<Data, Error>.Continuation
        var isSynthesizing: Bool = false

        init() {
            (audioStream, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
        }

        func synthesize(text: String) async throws {
            lock.lock(); synthesized.append(text); lock.unlock()
            continuation.yield(Data([0x01]))
            continuation.finish()
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
}
