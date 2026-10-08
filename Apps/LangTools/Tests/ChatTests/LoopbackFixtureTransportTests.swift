import Foundation
import Ollama
import XCTest
@testable import Chat

/// Bounded regression tests for `LoopbackURLSession` fixture transport injection.
///
/// No stores, preferences, keys, or real network: the custom scheme
/// `fixture-loopback://` is answered only by a `URLProtocol`, and RFC 2606
/// test hostnames (`fixture.invalid`, `other.invalid`) are used as data only.
final class LoopbackFixtureTransportTests: XCTestCase {
    private var originalSession: URLSession!

    override func setUp() {
        super.setUp()
        #if DEBUG
        LoopbackURLSession.installFixtureProtocols(nil)
        #endif
        originalSession = LoopbackURLSession.shared
    }

    override func tearDown() {
        #if DEBUG
        LoopbackURLSession.installFixtureProtocols(nil)
        #endif
        originalSession = nil
        super.tearDown()
    }

    @MainActor
    func testFixtureProtocolInterceptsCustomSchemeAndResetRestoresOriginalInstance() async throws {
        #if DEBUG
        LoopbackURLSession.installFixtureProtocols([FixtureLoopbackProtocol.self])
        defer { LoopbackURLSession.installFixtureProtocols(nil) }

        let session = LoopbackURLSession.shared
        XCTAssertNotNil(session)
        XCTAssertNotIdentical(session, originalSession)

        let url = URL(string: "fixture-loopback://probe/ping")!
        let (body, response) = try await session.data(for: URLRequest(url: url))

        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(http.url, url)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(payload["probe"] as? String, "fixture-loopback")

        LoopbackURLSession.installFixtureProtocols(nil)
        XCTAssertIdentical(LoopbackURLSession.shared, originalSession)
        #else
        XCTSkip("Fixture protocol injection is only available in DEBUG builds")
        #endif
    }

    @MainActor
    func testBaseURLOllamaFactoryUsesLoopbackSessionInjectionWithoutNetwork() throws {
        let baseURL = URL(string: "https://fixture.invalid")!
        let ollama = try OllamaEndpointPolicy.makeOllama(baseURL: baseURL)

        XCTAssertTrue(ollama.session === LoopbackURLSession.shared)
        XCTAssertEqual(ollama.configuration.baseURL, baseURL)
    }

    @MainActor
    func testRedirectDelegateCancelsCrossOriginRedirectionWithoutExecutingHTTP() throws {
        let session = LoopbackURLSession.shared
        let taskDelegate = try XCTUnwrap(session.delegate as? URLSessionTaskDelegate)

        // Never resumed: the task is only passed to the delegate so the test
        // cannot execute real HTTP or follow the redirect.
        let task = session.dataTask(with: URLRequest(url: URL(string: "https://fixture.invalid/source")!))
        defer { task.cancel() }

        let redirectResponse = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://fixture.invalid/source")!,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": "https://other.invalid/target"]
        ))
        let crossOriginRequest = URLRequest(url: URL(string: "https://other.invalid/target")!)

        let redirectCompletion = expectation(description: "Redirect completion handler called exactly once")
        redirectCompletion.expectedFulfillmentCount = 1
        redirectCompletion.assertForOverFulfill = true

        taskDelegate.urlSession?(
            session, task: task,
            willPerformHTTPRedirection: redirectResponse,
            newRequest: crossOriginRequest,
            completionHandler: { request in
                XCTAssertNil(request, "Loopback redirect delegate must cancel cross-origin redirects")
                redirectCompletion.fulfill()
            }
        )
        wait(for: [redirectCompletion], timeout: 2)
    }
}

/// A `URLProtocol` that answers `fixture-loopback://` URLs with a static 200 JSON
/// body and refuses every other scheme. Never performs real network I/O.
private final class FixtureLoopbackProtocol: URLProtocol {
    static let fixtureBody = Data(#"{"ok": true, "probe": "fixture-loopback"}"#.utf8)

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == "fixture-loopback"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.fixtureBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        // Static fixture: nothing to tear down.
    }
}
