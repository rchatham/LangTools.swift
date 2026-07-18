//
//  MockURLProtocol.swift
//  LangTools
//
//  Created by Reid Chatham on 12/30/23.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LangTools

class MockURLProtocol: URLProtocol {
    typealias MockNetworkHandler = (URLRequest) throws -> (result: Result<Data, Error>, statusCode: Int?)

    // Handlers are registered from the test thread but read from URLSession's loader
    // threads (canInit/startLoading). The lock guarantees memory visibility across
    // threads — without it, a freshly registered handler can be missed by canInit,
    // letting the request escape to the real network and hang CI indefinitely.
    private static let lock = NSLock()
    private static var _handlers: [String: MockNetworkHandler] = [:]

    public static var mockNetworkHandlers: [String: MockNetworkHandler] {
        get { lock.lock(); defer { lock.unlock() }; return _handlers }
        set { lock.lock(); defer { lock.unlock() }; _handlers = newValue }
    }

    // Requests to these hosts are intercepted even when no handler is registered and
    // failed fast, so an unmocked request surfaces as an immediate test failure instead
    // of a real network call (which has no bounded timeout and can hang a CI job).
    private static let interceptedHosts: Set<String> = [
        "api.openai.com",
        "api.anthropic.com",
        "api.x.ai",
        "generativelanguage.googleapis.com",
    ]

    private static func hasHandler(forPath path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return _handlers.keys.contains(where: { path.hasSuffix($0) })
    }

    /// Atomically finds and removes the handler matching `path` (consume-on-use).
    ///
    /// Note: canInit (hasHandler, a peek) and startLoading (takeHandler, a consume) take the
    /// lock independently. If two concurrent requests race for the same endpoint, both can pass
    /// canInit but only one gets the handler — the loser fails fast with resourceUnavailable.
    /// Sequential await-driven tests are unaffected; concurrent tests against the same endpoint
    /// must register one handler per expected request.
    private static func takeHandler(forPath path: String) -> MockNetworkHandler? {
        lock.lock(); defer { lock.unlock() }
        guard let key = _handlers.keys.first(where: { path.hasSuffix($0) }) else { return nil }
        return _handlers.removeValue(forKey: key)
    }

    private static func shouldIntercept(url: URL?) -> Bool {
        guard let host = url?.host else { return false }
        return interceptedHosts.contains(host)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        hasHandler(forPath: request.path) || shouldIntercept(url: request.url)
    }
    override class func canInit(with task: URLSessionTask) -> Bool {
        hasHandler(forPath: task.path) || shouldIntercept(url: task.currentRequest?.url)
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.takeHandler(forPath: request.path) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable, userInfo: [
                NSLocalizedDescriptionKey: "MockURLProtocol: no mock handler registered for \(request.path). Register a handler before making this request."
            ]))
            return
        }

        let response: (result: Result<Data, Error>, statusCode: Int?)
        do { response = try handler(request) }
        catch {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        if let statusCode = response.statusCode {
            let httpURLResponse = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            self.client?.urlProtocol(
                 self,
                 didReceive: httpURLResponse,
                 cacheStoragePolicy: .notAllowed
            )
        }

        switch response.result {
        case let .success(data):
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)

        case let .failure(error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}

}

extension URL {
    var endpoint: String { pathComponents[2...].joined(separator: "/") }
}

extension URLRequest {
    // canInit(with:) now runs for every request while this protocol is registered (it also
    // checks shouldIntercept), so a request with no URL must not crash here — fall through
    // to "no match" instead.
    var path: String { url?.path ?? "" }

    /// The request body as `Data`, whether URLSession left it in `httpBody` or moved it into
    /// `httpBodyStream`. URLSession converts an `httpBody` into an `httpBodyStream` before the
    /// request reaches a `URLProtocol`, so `httpBody` is typically nil inside a mock handler and
    /// the body must be drained from the stream instead. Returns nil when there is no body.
    var bodyData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read < 0 { return nil } // stream read error
            if read == 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

extension URLSessionTask {
    var path: String { currentRequest?.path ?? "" }
}

extension MockURLProtocol {
    static func registerResponse(for endpoint: String, data: Data, statusCode:
    Int) {
        MockURLProtocol.mockNetworkHandlers[endpoint] = { request in
        (.success(data), statusCode) }
    }

    static var configuration: URLSessionConfiguration {
        URLProtocol.registerClass(MockURLProtocol.self)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return config
    }

}
