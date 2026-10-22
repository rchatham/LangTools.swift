import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if !canImport(Darwin)
// FoundationNetworking (Linux) has no async `data(for:)` or `bytes(for:)`. These
// shims stream through a session-level data delegate because, on Linux:
// - a per-task `delegate` is ignored, so it cannot observe incremental bytes;
// - a completion-handler data task keeps only the last chunk when a URL protocol
//   delivers a body in several pieces.
// Each request runs on a short-lived session built from the caller's
// configuration (protocol classes, timeouts, headers), and authentication
// challenges and redirects are forwarded to the caller's session delegate so
// pinning and redirect policies still apply.
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

    /// The response body as it arrives, with a `lines` view matching the
    /// interface used on Apple platforms.
    struct AsyncBytes: AsyncSequence {
        typealias Element = UInt8

        let chunks: AsyncThrowingStream<Data, Error>

        struct Iterator: AsyncIteratorProtocol {
            var chunks: AsyncThrowingStream<Data, Error>.AsyncIterator
            var current = Data()
            var index = 0

            mutating func next() async throws -> UInt8? {
                while index >= current.count {
                    guard let chunk = try await chunks.next() else { return nil }
                    current = chunk
                    index = 0
                }
                defer { index += 1 }
                return current[current.startIndex + index]
            }
        }

        func makeAsyncIterator() -> Iterator { Iterator(chunks: chunks.makeAsyncIterator()) }

        /// Lines split on `\n`, with a trailing `\r` removed. Bytes are buffered
        /// until a full line arrives, so multibyte characters split across
        /// chunks decode correctly.
        var lines: AsyncThrowingStream<String, Error> {
            let chunks = self.chunks
            return AsyncThrowingStream { continuation in
                let pump = Task {
                    var buffer = Data()
                    func emit(_ bytes: Data) {
                        var line = bytes
                        if line.last == UInt8(ascii: "\r") { line.removeLast() }
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

/// One request on its own session, delivering the response once and the body
/// as a stream of chunks. Cancelling the waiting task or abandoning the stream
/// cancels the request.
private final class StreamingTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let chunks: AsyncThrowingStream<Data, Error>
    private let chunkContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private let request: URLRequest
    private let configuration: URLSessionConfiguration
    private weak var forwardingDelegate: URLSessionDelegate?
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var responseContinuation: CheckedContinuation<URLResponse, Error>?
    private var responseDelivered = false

    init(request: URLRequest, configuration: URLSessionConfiguration, forwardingDelegate: URLSessionDelegate?) {
        self.request = request
        self.configuration = configuration
        self.forwardingDelegate = forwardingDelegate
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
                responseContinuation = continuation
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                let task = session.dataTask(with: request)
                self.session = session
                self.task = task
                lock.unlock()
                guard !Task.isCancelled else {
                    // The task never started, so no delegate callback will
                    // report the cancellation; fail the transfer here.
                    let error = URLError(.cancelled)
                    deliverResponse(.failure(error))
                    chunkContinuation.finish(throwing: error)
                    session.invalidateAndCancel()
                    return
                }
                task.resume()
            }
        } onCancel: {
            cancel()
        }
    }

    private func cancel() {
        lock.lock()
        let session = self.session
        lock.unlock()
        // Invalidating cancels the task; didCompleteWithError then finishes
        // the stream and fails a pending response with the cancellation.
        session?.invalidateAndCancel()
    }

    private func deliverResponse(_ result: Result<URLResponse, Error>) {
        lock.lock()
        guard !responseDelivered, let continuation = responseContinuation else { lock.unlock(); return }
        responseDelivered = true
        responseContinuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        deliverResponse(.success(response))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        chunkContinuation.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Errors pass through unchanged (a cancelled transfer is
        // `URLError(.cancelled)`), matching Apple's async URLSession APIs.
        if let failure = error {
            deliverResponse(.failure(failure))
            chunkContinuation.finish(throwing: failure)
        } else {
            // A body-less success still needs a response for the caller.
            if let response = task.response { deliverResponse(.success(response)) }
            else { deliverResponse(.failure(URLError(.badServerResponse))) }
            chunkContinuation.finish()
        }
        session.finishTasksAndInvalidate()
    }

    // MARK: Forwarding to the caller's session delegate
    //
    // FoundationNetworking supplies default implementations for these methods
    // (default handling, follow the redirect), so calling through the
    // protocol reaches the caller's override when there is one.

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let forward = forwardingDelegate else { return completionHandler(.performDefaultHandling, nil) }
        forward.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let forward = forwardingDelegate as? URLSessionTaskDelegate else {
            return urlSession(session, didReceive: challenge, completionHandler: completionHandler)
        }
        forward.urlSession(session, task: task, didReceive: challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let forward = forwardingDelegate as? URLSessionTaskDelegate else { return completionHandler(request) }
        forward.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request, completionHandler: completionHandler)
    }
}
#endif
