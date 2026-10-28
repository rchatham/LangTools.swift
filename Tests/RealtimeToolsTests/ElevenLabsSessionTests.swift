//
//  ElevenLabsSessionTests.swift
//  LangTools
//
//  Created by Reid Chatham on 1/16/26.
//

import XCTest
@testable import ElevenLabs
@testable import LangTools

// MARK: - ElevenLabsWebSocketSession Decode Resilience

final class ElevenLabsWebSocketSessionTests: XCTestCase {

    private func makeConnectedSession() async throws -> (ElevenLabsWebSocketSession, MockWebSocketTask) {
        let mock = MockWebSocketTask()
        let session = ElevenLabsWebSocketSession(apiKey: "test-key", voiceId: "voice-123")
        session.webSocketTaskFactory = { _ in mock }
        try await session.connect()
        return (session, mock)
    }

    /// Regression test: a malformed/unrecognized WebSocket message must not
    /// kill the session — only OpenAIRealtimeSession originally handled this
    /// correctly; ElevenLabsWebSocketSession let decode errors propagate to
    /// the outer catch and finish the stream, ending the whole session over
    /// a single bad message.
    func testMalformedMessageDoesNotEndSession() async throws {
        let (session, mock) = try await makeConnectedSession()

        var decodeErrors: [Error] = []
        session.onDecodeError = { decodeErrors.append($0) }

        mock.push("{not valid json")
        mock.push("""
        {"audio": "\(Data("hi".utf8).base64EncodedString())", "isFinal": false}
        """)

        var iterator = session.audioStream.makeAsyncIterator()
        let chunk = try await iterator.next()

        XCTAssertNotNil(chunk, "Stream should survive the malformed message and deliver the next valid chunk")
        XCTAssertEqual(chunk?.audio, Data("hi".utf8))
        session.disconnect()
    }

    func testOnDecodeErrorFiresForMalformedMessage() async throws {
        let (session, mock) = try await makeConnectedSession()

        let expectation = expectation(description: "decode error observed")
        session.onDecodeError = { _ in expectation.fulfill() }

        mock.push("not json at all")

        await fulfillment(of: [expectation], timeout: 5)
        session.disconnect()
    }

    func testConcurrentSendsNeverOverlapOnTheSocket() async throws {
        let (session, mock) = try await makeConnectedSession()
        mock.sendDelayNanoseconds = 20_000_000

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<6 {
                group.addTask { try? await session.send(text: "chunk \(i) ") }
            }
            group.addTask { try? await session.flush() }
        }

        // 1 initial message from connect() + 6 text chunks + 1 flush
        XCTAssertEqual(mock.sentMessages.count, 8)
        XCTAssertEqual(mock.maxConcurrentSends, 1, "Sends overlapped on the socket")
        session.disconnect()
    }

    func testConnectAfterDisconnectThrowsSessionClosed() async throws {
        let (session, _) = try await makeConnectedSession()
        session.disconnect()

        do {
            try await session.connect()
            XCTFail("Expected sessionClosed")
        } catch let error as ElevenLabsWebSocketError {
            guard case .sessionClosed = error else {
                return XCTFail("Expected sessionClosed, got \(error)")
            }
        }
    }

    /// Regression test: a failed initial send used to leave the resumed
    /// socket attached, so the next connect() overwrote (leaked) it.
    func testFailedConnectTearsDownSocketAndAllowsRetry() async throws {
        let failing = MockWebSocketTask()
        failing.failSends = true
        let working = MockWebSocketTask()
        var sockets = [failing, working]

        let session = ElevenLabsWebSocketSession(apiKey: "test-key", voiceId: "voice-123")
        session.webSocketTaskFactory = { _ in sockets.removeFirst() }

        do {
            try await session.connect()
            XCTFail("Expected connect() to throw")
        } catch {}
        XCTAssertFalse(session.isConnected)
        XCTAssertTrue(failing.isClosed, "The failed socket should be cancelled, not leaked")

        try await session.connect()
        XCTAssertTrue(session.isConnected)
        XCTAssertFalse(working.isClosed)
        session.disconnect()
    }
}

// MARK: - ElevenLabsSTTSession Decode Resilience

final class ElevenLabsSTTSessionTests: XCTestCase {

    private func makeConnectedSession() async throws -> (ElevenLabsSTTSession, MockWebSocketTask) {
        let mock = MockWebSocketTask()
        let session = ElevenLabsSTTSession(apiKey: "test-key")
        session.webSocketTaskFactory = { _ in mock }
        try await session.connect()
        return (session, mock)
    }

    /// Same regression as the TTS session: a malformed message must not end
    /// the transcription stream.
    func testMalformedMessageDoesNotEndSession() async throws {
        let (session, mock) = try await makeConnectedSession()

        mock.push("{garbled")
        mock.push("""
        {"type": "transcript", "transcript": {"text": "hello", "is_final": true}}
        """)

        var iterator = session.transcriptions.makeAsyncIterator()
        let result = try await iterator.next()

        XCTAssertEqual(result?.text, "hello")
        XCTAssertEqual(result?.isFinal, true)
        session.disconnect()
    }

    func testOnDecodeErrorFiresForMalformedMessage() async throws {
        let (session, mock) = try await makeConnectedSession()

        let expectation = expectation(description: "decode error observed")
        session.onDecodeError = { _ in expectation.fulfill() }

        mock.push("also not json")

        await fulfillment(of: [expectation], timeout: 5)
        session.disconnect()
    }

    func testFailedConnectTearsDownSocketAndAllowsRetry() async throws {
        let failing = MockWebSocketTask()
        failing.failSends = true
        let working = MockWebSocketTask()
        var sockets = [failing, working]

        let session = ElevenLabsSTTSession(apiKey: "test-key")
        session.webSocketTaskFactory = { _ in sockets.removeFirst() }

        do {
            try await session.connect()
            XCTFail("Expected connect() to throw")
        } catch {}
        XCTAssertFalse(session.isConnected)
        XCTAssertTrue(failing.isClosed, "The failed socket should be cancelled, not leaked")

        try await session.connect()
        XCTAssertTrue(session.isConnected)
        session.disconnect()
    }

    func testConnectAfterDisconnectThrowsSessionClosed() async throws {
        let (session, _) = try await makeConnectedSession()
        session.disconnect()

        do {
            try await session.connect()
            XCTFail("Expected sessionClosed")
        } catch let error as ElevenLabsSTTError {
            guard case .sessionClosed = error else {
                return XCTFail("Expected sessionClosed, got \(error)")
            }
        }
    }

    /// A server-sent "error" message is a valid decode, not a malformed one —
    /// it should still terminate the stream (this is existing, correct
    /// behavior, not part of the decode-resilience fix).
    func testServerErrorMessageEndsStreamWithError() async throws {
        let (session, mock) = try await makeConnectedSession()

        mock.push("""
        {"type": "error", "error": {"message": "something went wrong"}}
        """)

        var iterator = session.transcriptions.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("Expected the stream to throw")
        } catch let error as ElevenLabsSTTError {
            guard case .serverError(let message) = error else {
                return XCTFail("Expected serverError, got \(error)")
            }
            XCTAssertEqual(message, "something went wrong")
        }
        session.disconnect()
    }
}
