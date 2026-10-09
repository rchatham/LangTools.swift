import Foundation
import Ollama
import XCTest
@testable import Chat

/// Bounded regression tests for `LoopbackURLSession` fixture transport injection.
///
/// No real credential stores, keys, or network; isolated synthetic preferences only.
/// The custom scheme
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
    func testSharedSnapshotServiceChatAgentAndManagementUseFixtureNoRedirectSession() async throws {
        #if DEBUG
        LoopbackURLSession.installFixtureProtocols([FactoryOllamaProtocol.self])
        let suite = "LoopbackFixtureTransportTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            LoopbackURLSession.installFixtureProtocols(nil)
        }
        let configuration = OllamaEndpointConfiguration(userDefaults: defaults, credentialStore: OllamaMemoryHelperStore())
        let manager = ProviderAccessManager(keychainService: OllamaMemoryKeychainService(), sessionStore: AuthSessionStore(secretStore: OllamaMemorySecrets()), ollamaEndpointConfiguration: configuration)
        let snapshot = configuration.snapshot()
        let context = try snapshot.makeAgentContext(model: .init(rawValue: "fixture")!, messages: [], eventHandler: { _ in })
        XCTAssertTrue(context.langTool.session === LoopbackURLSession.shared)
        XCTAssertNotNil(context.langTool.session.delegate as? URLSessionTaskDelegate)
        let service = OllamaService(endpointConfiguration: configuration, providerAccessManager: manager)
        try await service.checkConnection(for: snapshot)
        try await service.loadModel(.init(rawValue: "fixture")!, for: snapshot)
        let prepared = try snapshot.makeToolchain().prepare(request: Ollama.ChatRequest(model: .init(rawValue: "fixture")!, messages: [], stream: false))
        XCTAssertEqual(prepared.url?.host, "localhost")
        XCTAssertNil(prepared.value(forHTTPHeaderField: "Authorization"))
        let client = NetworkClient(keychainService: OllamaMemoryKeychainService(), accountLoginService: FixtureTransportLoginService(), providerAccessManager: manager, ollamaEndpointConfiguration: configuration)
        let response = try await client.performChatCompletionRequest(messages: [], model: .ollama(.init(rawValue: "fixture")!), tools: nil, toolChoice: nil)
        XCTAssertEqual(response.text, "fixture")
        service.refreshModels()
        let deadline = Date().addingTimeInterval(3)
        while service.isLoading {
            guard Date() < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertNil(service.error)
        XCTAssertEqual(service.availableModels.map(\.rawValue), ["fixture"])
        #else
        throw XCTSkip("DEBUG fixture factory only")
        #endif
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

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, url.scheme == "fixture-loopback", let response = HTTPURLResponse(
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

/// Every request is intercepted, including unexpected hosts/paths; no passthrough.
private final class FactoryOllamaProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, url.host == "localhost" else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let body: String
        switch url.path {
        case "/api/version": body = #"{"version":"fixture"}"#
        case "/api/tags": body = #"{"models":[{"name":"fixture","modified_at":"2025-01-01T00:00:00Z","size":1,"digest":"fixture","details":{"format":"gguf","family":"llama","families":[],"parameter_size":"1B","quantization_level":"Q4"}}]}"#
        case "/api/ps": body = #"{"models":[]}"#
        case "/api/chat": body = #"{"model":"fixture","created_at":"2025-01-01T00:00:00Z","message":{"role":"assistant","content":"fixture"},"done":true}"#
        default: client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private struct FixtureTransportLoginService: AccountLoginService {
    func beginLogin(for provider: AccountLoginProvider) async throws -> AccountSession { throw URLError(.userAuthenticationRequired) }
    func handleRedirect(_ url: URL) async throws -> AccountSession { throw URLError(.userAuthenticationRequired) }
    func refreshSession(_ session: AccountSession) async throws -> AccountSession { session }
    func logout(provider: AccountLoginProvider) async throws {}
    func fetchAccessibleModels(for provider: AccountLoginProvider) async throws -> [String] { [] }
}
