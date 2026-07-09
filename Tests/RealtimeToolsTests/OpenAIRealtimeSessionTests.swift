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

    // MARK: - STT Wiring

    /// STT stub whose transcription stream can be pushed to on demand
    private final class StubSTT: RealtimeTools.STTProvider, @unchecked Sendable {
        let transcriptions: AsyncThrowingStream<TranscriptionResult, Error>
        private let continuation: AsyncThrowingStream<TranscriptionResult, Error>.Continuation

        init() {
            (transcriptions, continuation) = AsyncThrowingStream.makeStream(of: TranscriptionResult.self)
        }

        func startTranscription() async throws {}
        func stopTranscription() async throws {}
        func transcribe(audio: Data) async throws {}

        func push(_ result: TranscriptionResult) {
            continuation.yield(result)
        }
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

        func reset() async {}
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
