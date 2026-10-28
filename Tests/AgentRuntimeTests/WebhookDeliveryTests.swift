//
//  WebhookDeliveryTests.swift
//  AgentRuntimeTests
//

import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import AgentRuntime
@testable import TestUtils

final class WebhookDeliveryTests: XCTestCase {
    private var session: URLSession!
    private var sleeps: [TimeInterval] = []
    private let hookURL = URL(string: "https://hooks.example.com/agent-results")!
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        _ = URLProtocol.registerClass(MockURLProtocol.self)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
        sleeps = []
    }

    override func tearDown() {
        MockURLProtocol.resetHandlers()
        URLProtocol.unregisterClass(MockURLProtocol.self)
        super.tearDown()
    }

    private func delivery(secret: String? = "whsec_test", maxAttempts: Int = 3) throws -> WebhookDelivery {
        WebhookDelivery(
            configuration: try WebhookConfiguration(url: hookURL, secret: secret, maxAttempts: maxAttempts),
            session: session,
            sleep: { self.sleeps.append($0) },
            now: { self.fixedNow }
        )
    }

    private let result = AgentRunResult(runID: "run-1", agent: "Helper", provider: "openai", model: "gpt-4o", status: .completed, output: "Pong",
                                        startedAt: Date(timeIntervalSince1970: 0), finishedAt: Date(timeIntervalSince1970: 1))

    /// Answers each request with the next status in `statuses`, recording the requests.
    private func respond(with statuses: [Int], headers: [String: String] = [:]) -> RequestLog {
        let log = RequestLog()
        func handle(_ remaining: ArraySlice<Int>) {
            MockURLProtocol.setHandler(for: "/agent-results") { request in
                log.append(request)
                if remaining.count > 1 { handle(remaining.dropFirst()) }
                return (.success(Data()), remaining.first!)
            }
        }
        handle(statuses[...])
        return log
    }

    // MARK: - Configuration

    func testRejectsPlainHTTPExceptLocalhost() {
        XCTAssertThrowsError(try WebhookConfiguration(url: URL(string: "http://hooks.example.com/x")!, secret: nil))
        XCTAssertThrowsError(try WebhookConfiguration(url: URL(string: "ftp://hooks.example.com/x")!, secret: nil))
        XCTAssertNoThrow(try WebhookConfiguration(url: URL(string: "http://localhost:8080/x")!, secret: nil))
        XCTAssertNoThrow(try WebhookConfiguration(url: URL(string: "http://127.0.0.1:8080/x")!, secret: nil))
        XCTAssertNoThrow(try WebhookConfiguration(url: hookURL, secret: nil))
    }

    func testEmptySecretMeansUnsigned() throws {
        XCTAssertNil(try WebhookConfiguration(url: hookURL, secret: "").secret)
    }

    // MARK: - Delivery

    func testDeliversSignedResult() async throws {
        let log = respond(with: [204])
        let outcome = try await delivery().deliver(result, deliveryID: "d-1")

        XCTAssertEqual(outcome, WebhookDeliveryOutcome(delivered: true, attempts: 1, statusCode: 204, error: nil, deliveryID: "d-1"))
        let request = try XCTUnwrap(log.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: WebhookDelivery.deliveryHeader), "d-1")
        XCTAssertEqual(request.value(forHTTPHeaderField: WebhookDelivery.runIDHeader), "run-1")
        let body = try XCTUnwrap(request.bodyData ?? request.httpBody)
        XCTAssertEqual(try AgentRunResult.decode(from: body), result)
        let signature = try XCTUnwrap(request.value(forHTTPHeaderField: WebhookSignature.header))
        XCTAssertTrue(WebhookSignature.verify(body: body, header: signature, secret: "whsec_test", now: fixedNow))
    }

    func testUnsignedWhenNoSecret() async throws {
        let log = respond(with: [200])
        _ = try await delivery(secret: nil).deliver(result)
        XCTAssertNil(log.requests.first?.value(forHTTPHeaderField: WebhookSignature.header))
    }

    func testRetriesServerErrorsWithBackoffAndKeepsDeliveryID() async throws {
        let log = respond(with: [503, 500, 200])
        let outcome = try await delivery().deliver(result, deliveryID: "d-2")

        XCTAssertTrue(outcome.delivered)
        XCTAssertEqual(outcome.attempts, 3)
        XCTAssertEqual(sleeps, [1, 2])
        XCTAssertEqual(log.requests.map { $0.value(forHTTPHeaderField: WebhookDelivery.deliveryHeader) }, ["d-2", "d-2", "d-2"])
    }

    func testBackoffDoublesCapsAndHonorsRetryAfter() throws {
        let config = try WebhookConfiguration(url: hookURL, secret: nil, initialBackoff: 1, maxBackoff: 10)
        XCTAssertEqual((1...5).map { config.backoff(afterAttempt: $0, retryAfter: nil) }, [1, 2, 4, 8, 10])
        XCTAssertEqual(config.backoff(afterAttempt: 1, retryAfter: 7), 7)
        XCTAssertEqual(config.backoff(afterAttempt: 1, retryAfter: 120), 10, "Retry-After is capped too")
    }

    func testDoesNotRetryClientErrors() async throws {
        let log = respond(with: [400, 200])
        let outcome = try await delivery().deliver(result)
        XCTAssertFalse(outcome.delivered)
        XCTAssertEqual(outcome.attempts, 1)
        XCTAssertEqual(outcome.statusCode, 400)
        XCTAssertEqual(log.requests.count, 1)
        XCTAssertEqual(sleeps, [])
    }

    func testGivesUpAfterMaxAttempts() async throws {
        _ = respond(with: [500, 500, 500])
        let outcome = try await delivery(maxAttempts: 3).deliver(result)
        XCTAssertFalse(outcome.delivered)
        XCTAssertEqual(outcome.attempts, 3)
        XCTAssertEqual(outcome.error, "Webhook answered HTTP 500.")
        XCTAssertEqual(sleeps, [1, 2], "No wait after the last attempt")
    }

    func testRetriesNetworkErrors() async throws {
        MockURLProtocol.setHandler(for: "/agent-results") { _ in
            MockURLProtocol.setHandler(for: "/agent-results") { _ in (.success(Data()), 200) }
            return (.failure(URLError(.timedOut)), nil)
        }
        let outcome = try await delivery().deliver(result)
        XCTAssertTrue(outcome.delivered)
        XCTAssertEqual(outcome.attempts, 2)
    }

    // MARK: - Signature

    func testSignatureVerification() {
        let body = Data(#"{"status":"completed"}"#.utf8)
        let header = WebhookSignature.sign(body: body, secret: "s3cret", timestamp: fixedNow)
        XCTAssertTrue(header.hasPrefix("t=1800000000,v1="))
        XCTAssertTrue(WebhookSignature.verify(body: body, header: header, secret: "s3cret", now: fixedNow))
        XCTAssertFalse(WebhookSignature.verify(body: body, header: header, secret: "other", now: fixedNow), "Wrong secret")
        XCTAssertFalse(WebhookSignature.verify(body: Data(#"{"status":"failed"}"#.utf8), header: header, secret: "s3cret", now: fixedNow), "Tampered body")
        XCTAssertFalse(WebhookSignature.verify(body: body, header: header, secret: "s3cret", now: fixedNow.addingTimeInterval(301)), "Replayed too late")
        XCTAssertFalse(WebhookSignature.verify(body: body, header: "v1=abc", secret: "s3cret", now: fixedNow), "No timestamp")
        XCTAssertFalse(WebhookSignature.verify(body: body, header: "t=1800000000,v1=zz", secret: "s3cret", now: fixedNow), "Bad hex")
    }

    func testSignatureMatchesReferenceHMAC() {
        // echo -n '1800000000.{}' | openssl dgst -sha256 -hmac key
        let header = WebhookSignature.sign(body: Data("{}".utf8), secret: "key", timestamp: fixedNow)
        XCTAssertEqual(header, "t=1800000000,v1=7321475872b03ff21bdc2dfd86ea2d99ec29c479fbe4a77aa6acf4509505493f")
    }
}

final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    func append(_ request: URLRequest) { lock.lock(); _requests.append(request); lock.unlock() }
}
