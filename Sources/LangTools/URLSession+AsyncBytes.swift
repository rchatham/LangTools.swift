import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if !canImport(Darwin)
// FoundationNetworking (Linux) has no async `data(for:)` or `bytes(for:)`. These
// shims stream through a session-level data delegate, because a per-task delegate
// is ignored and a completion handler keeps only the last chunk of a multi-part
// body. Each request runs on a short-lived session built from the caller's
// configuration; challenges and redirects go to the caller's session delegate.
extension URLSession {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await bytes(for: request)
        var data = Data()
        for try await chunk in bytes.chunks { data.append(chunk) }
        return (data, response)
    }

    func bytes(for request: URLRequest) async throws -> (AsyncBytes, URLResponse) {
        let transfer = StreamingTransfer(request: request, configuration: configuration, forwardingDelegate: delegate)
        let response = try await transfer.start()
        return (AsyncBytes(chunks: transfer.chunks), response)
    }

    /// The response body as it arrives, with the `lines` view used on Apple platforms.
    struct AsyncBytes {
        let chunks: AsyncThrowingStream<Data, Error>

        /// Lines split on `\n` without a trailing `\r`; bytes are buffered until a
        /// full line arrives, so multibyte characters split across chunks decode.
        var lines: AsyncThrowingStream<String, Error> {
            let chunks = self.chunks
            return AsyncThrowingStream { continuation in
                let pump = Task {
                    var buffer = Data()
                    func emit(_ line: Data) {
                        let line = line.last == UInt8(ascii: "\r") ? line.dropLast() : line
                        if let string = String(data: line, encoding: .utf8) { continuation.yield(string) }
                    }
                    do {
                        for try await chunk in chunks {
                            buffer.append(chunk)
                            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                                emit(buffer[buffer.startIndex..<newline])
                                buffer.removeSubrange(buffer.startIndex...newline)
                            }
                        }
                        if !buffer.isEmpty { emit(buffer) }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { @Sendable _ in pump.cancel() }
            }
        }
    }
}

/// One request on its own session, delivering the response once and the body as
/// chunks. Cancelling the waiting task or abandoning the stream cancels the request.
private final class StreamingTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let chunks: AsyncThrowingStream<Data, Error>
    private let chunkContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private let request: URLRequest
    private let configuration: URLSessionConfiguration
    private weak var forwardingDelegate: URLSessionDelegate?
    private let lock = NSLock()
    private var session: URLSession?
    private var responseContinuation: CheckedContinuation<URLResponse, Error>?
    private var cancelled = false

    init(request: URLRequest, configuration: URLSessionConfiguration, forwardingDelegate: URLSessionDelegate?) {
        (self.request, self.configuration, self.forwardingDelegate) = (request, configuration, forwardingDelegate)
        (chunks, chunkContinuation) = AsyncThrowingStream.makeStream(of: Data.self)
        super.init()
        chunkContinuation.onTermination = { @Sendable [weak self] termination in
            if case .cancelled = termination { self?.cancel() }
        }
    }

    func start() async throws -> URLResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                // `cancel()` sets `cancelled` under the same lock, so it either runs
                // first (no task starts, so fail here) or finds the running session.
                guard !cancelled else {
                    lock.unlock()
                    continuation.resume(throwing: URLError(.cancelled))
                    chunkContinuation.finish(throwing: URLError(.cancelled))
                    return
                }
                responseContinuation = continuation
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                self.session = session
                session.dataTask(with: request).resume()
                lock.unlock()
            }
        } onCancel: {
            cancel()
        }
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        let session = self.session
        lock.unlock()
        // didCompleteWithError then finishes the stream and fails a pending response.
        session?.invalidateAndCancel()
    }

    private func deliverResponse(_ result: Result<URLResponse, Error>) {
        lock.lock()
        let continuation = responseContinuation
        responseContinuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        deliverResponse(.success(response))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        chunkContinuation.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Errors pass through unchanged, as with Apple's async URLSession APIs. A
        // body-less success still needs a response for the caller.
        deliverResponse(error.map { .failure($0) } ?? task.response.map { .success($0) } ?? .failure(URLError(.badServerResponse)))
        if let error { chunkContinuation.finish(throwing: error) } else { chunkContinuation.finish() }
        session.finishTasksAndInvalidate()
    }

    // FoundationNetworking supplies defaults for these (default handling, follow
    // the redirect), so calling through the protocol reaches any caller override.

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let forward = forwardingDelegate else { return completionHandler(.performDefaultHandling, nil) }
        forward.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let forward = forwardingDelegate as? URLSessionTaskDelegate else { return urlSession(session, didReceive: challenge, completionHandler: completionHandler) }
        forward.urlSession(session, task: task, didReceive: challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let forward = forwardingDelegate as? URLSessionTaskDelegate else { return completionHandler(request) }
        forward.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request, completionHandler: completionHandler)
    }
}
#endif
