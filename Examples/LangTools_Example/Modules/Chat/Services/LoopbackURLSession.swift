import Foundation

/// A `URLSession` that cancels HTTP redirects so a loopback helper response
/// cannot redirect a credential-bearing request to a different origin.
///
/// The Codex helper and Claude Code backend are validated to loopback
/// (or HTTPS) destinations before every request. If those responses were
/// allowed to redirect, a compromised or misconfigured helper could forward
/// the request body and bearer token to an arbitrary host. Rejecting
/// redirects keeps the validated destination authoritative for the whole
/// request lifecycle.
public enum LoopbackURLSession {
    public static let shared: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = 60
        return URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }()
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Cancel the redirect: the helper must answer from the validated origin.
        completionHandler(nil)
    }
}