import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import OpenAI

final class RealtimeCompatibilityTests: XCTestCase {
    func testSessionRequestsRemainRoutableAndEncodeWithCurrentModels() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let api = OpenAI(baseURL: URL(string: "https://example.invalid/v1/")!, apiKey: "synthetic-test-key", session: session)
        let request = OpenAI.RealtimeSessionCreateRequest(model: .gptRealtime, modalities: ["text", "audio"], max_response_output_tokens: 128)
        XCTAssertTrue(OpenAI.requestValidators.contains { $0(request) })
        let prepared = try api.prepare(request: request)
        XCTAssertEqual(prepared.url?.path, "/v1/realtime/sessions")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(prepared.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "gpt-realtime")
        XCTAssertEqual(body["max_response_output_tokens"] as? Int, 128)
        let transcription = OpenAI.RealtimeTranscriptionSessionCreateRequest(input_audio_format: "pcm16")
        XCTAssertTrue(OpenAI.requestValidators.contains { $0(transcription) })
        XCTAssertEqual(try api.prepare(request: transcription).url?.path, "/v1/realtime/transcription_sessions")
    }

    func testWebSocketPreparationPreservesTransportAndEphemeralAuthorization() throws {
        for (scheme, expected) in [("https", "wss"), ("http", "ws")] {
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let api = OpenAI(baseURL: URL(string: "\(scheme)://example.invalid/v1/")!, apiKey: "synthetic-account-key", session: session)
            let task = try api.realtimeWebSocketTask(clientSecret: "synthetic-ephemeral-key")
            defer { task.cancel() }
            XCTAssertEqual(task.state, .suspended)
            XCTAssertEqual(task.originalRequest?.url?.scheme, expected)
            XCTAssertEqual(task.originalRequest?.url?.path, "/v1/realtime")
            XCTAssertEqual(task.originalRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-ephemeral-key")
        }
    }
}
