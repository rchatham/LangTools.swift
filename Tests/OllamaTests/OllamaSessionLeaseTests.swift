import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LangTools
import Ollama
import XCTest

final class OllamaSessionLeaseTests: XCTestCase {
    override func setUp() {
        super.setUp()
        LeaseURLProtocol.reset()
    }

    override func tearDown() {
        LeaseURLProtocol.reset()
        super.tearDown()
    }

    func testSharedLeaseRetiresOnlyAfterFinalProviderAndOwnerRelease() async throws {
        let invalidated = expectation(description: "Final owner invalidates session")
        var delegate: LeaseDelegate? = LeaseDelegate(invalidated: invalidated)
        weak var weakDelegate = delegate
        var session: URLSession? = makeSession(delegate: delegate!)
        weak var weakSession = session
        var lease: LangToolsSessionLease? = LangToolsSessionLease(session: session!)
        var first: Ollama? = Ollama(baseURL: URL(string: "https://fixture.invalid")!, apiKey: "fixture", sessionLease: lease!)
        var second: Ollama? = Ollama(baseURL: URL(string: "https://fixture.invalid")!, apiKey: "fixture", sessionLease: lease!)
        session = nil
        delegate = nil
        lease = nil
        XCTAssertNotNil(weakSession)
        XCTAssertNotNil(weakDelegate)
        XCTAssertTrue(first?.session === second?.session)
        first = nil
        XCTAssertNotNil(weakSession)
        XCTAssertNotNil(weakDelegate)
        second = nil
        await fulfillment(of: [invalidated], timeout: 3)
        try await waitUntil { weakSession == nil && weakDelegate == nil }
    }

    func testRawSessionInitializerDoesNotAdoptOrInvalidateSession() async throws {
        let delegate = LeaseDelegate(invalidated: expectation(description: "Explicit invalidation"))
        let session = makeSession(delegate: delegate)
        var provider: Ollama? = Ollama(baseURL: URL(string: "https://fixture.invalid")!, apiKey: "fixture", session: session)
        XCTAssertTrue(provider?.session === session)
        provider = nil
        XCTAssertFalse(delegate.isInvalidated)
        let request = Task { try await session.data(from: URL(string: "https://fixture.invalid/data")!) }
        try await waitUntil { LeaseURLProtocol.hasResponse }
        XCTAssertFalse(delegate.isInvalidated)
        LeaseURLProtocol.releaseResponse()
        let (data, _) = try await request.value
        XCTAssertEqual(data, Data("fixture".utf8))
        XCTAssertFalse(delegate.isInvalidated)
        session.finishTasksAndInvalidate()
        await fulfillment(of: [delegate.invalidated], timeout: 3)
    }

    func testFinalLeaseReleaseDrainsAlreadyActiveRawTaskInsteadOfCancelling() async throws {
        let delegate = LeaseDelegate(invalidated: expectation(description: "Drained session invalidates"))
        let session = makeSession(delegate: delegate)
        var lease: LangToolsSessionLease? = LangToolsSessionLease(session: session)
        XCTAssertTrue(lease?.session === session)
        let request = Task { try await session.data(from: URL(string: "https://fixture.invalid/data")!) }
        try await waitUntil { LeaseURLProtocol.hasResponse }
        lease = nil
        XCTAssertFalse(delegate.isInvalidated, "Already-started task is still a legitimate consumer")
        LeaseURLProtocol.releaseResponse()
        let (data, _) = try await request.value
        XCTAssertEqual(data, Data("fixture".utf8))
        await fulfillment(of: [delegate.invalidated], timeout: 3)
    }

    private func makeSession(delegate: LeaseDelegate) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LeaseURLProtocol.self]
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            if Date() >= deadline { throw URLError(.timedOut) }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

private final class LeaseDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let invalidated: XCTestExpectation
    private let lock = NSLock()
    private var didInvalidate = false
    var isInvalidated: Bool { lock.lock(); defer { lock.unlock() }; return didInvalidate }
    init(invalidated: XCTestExpectation) { self.invalidated = invalidated }
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        lock.lock(); didInvalidate = true; lock.unlock()
        invalidated.fulfill()
    }
}

private final class LeaseURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var response: (() -> Void)?
    static var hasResponse: Bool { lock.lock(); defer { lock.unlock() }; return response != nil }
    static func reset() { lock.lock(); defer { lock.unlock() }; response = nil }
    static func releaseResponse() {
        lock.lock(); let pending = response; response = nil; lock.unlock()
        pending?()
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.response = { [self] in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("fixture".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        Self.lock.unlock()
    }
    override func stopLoading() {}
}
