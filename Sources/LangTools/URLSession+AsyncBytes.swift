import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension URLSession {
    #if !canImport(Darwin)
    // Provide async/await wrapper for URLSession.dataTask on Linux.
    // Cancelling the calling task cancels the underlying data task, matching
    // the cancellation behavior of Foundation's async APIs on Apple platforms.
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let cancellation = DataTaskCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                cancellation.install { continuation.resume(with: $0) }
                let task = dataTask(with: request) { data, response, error in
                    if let error = error {
                        cancellation.complete(.failure(error))
                    } else if let data = data, let response = response {
                        cancellation.complete(.success((data, response)))
                    } else {
                        cancellation.complete(.failure(URLError(.badServerResponse)))
                    }
                }
                cancellation.start(resume: { task.resume() }, cancel: { task.cancel() })
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    // Internal action seam keeps ordering tests independent of sockets and of
    // FoundationNetworking's URLProtocol implementation.
    final class DataTaskCancellation: @unchecked Sendable {
        typealias Response = (Data, URLResponse)
        private let lock = NSLock()
        private var completion: ((Result<Response, Error>) -> Void)?
        private var result: Result<Response, Error>?
        private var cancelTask: (() -> Void)?
        private var isStarting = false
        private var isCancelled = false

        func install(_ completion: @escaping (Result<Response, Error>) -> Void) {
            lock.lock()
            let result = result
            if result == nil { self.completion = completion }
            lock.unlock()
            if let result { completion(result) }
        }

        func start(resume: () -> Void, cancel: @escaping () -> Void) {
            lock.lock()
            guard result == nil else {
                lock.unlock()
                cancel()
                return
            }
            // Commit start under the same lock as cancellation. A cancellation
            // that wins this transition never resumes the task. If start wins,
            // defer task cancellation until resume returns (which may reenter).
            isStarting = true
            cancelTask = cancel
            lock.unlock()
            resume()
            lock.lock()
            isStarting = false
            let shouldCancel = isCancelled
            if result != nil { cancelTask = nil }
            lock.unlock()
            if shouldCancel { cancel() }
        }

        func complete(_ result: Result<Response, Error>) {
            lock.lock()
            guard self.result == nil else { lock.unlock(); return }
            self.result = result
            let completion = completion
            self.completion = nil
            cancelTask = nil
            lock.unlock()
            completion?(result)
        }

        func cancel() {
            lock.lock()
            guard result == nil else { lock.unlock(); return }
            isCancelled = true
            let result: Result<Response, Error> = .failure(URLError(.cancelled))
            self.result = result
            let completion = completion
            self.completion = nil
            let cancelTask = isStarting ? nil : cancelTask
            if !isStarting { self.cancelTask = nil }
            lock.unlock()
            // Neither URLSession nor continuation callbacks run under our lock.
            cancelTask?()
            completion?(result)
        }
    }

    // Provide a lightweight implementation of `bytes(for:)` for platforms where
    // this API is unavailable (e.g. Linux). The implementation loads the entire
    // response data and exposes it as an async sequence of bytes, with a `lines` property
    // for line-based access, matching the interface used by Foundation on Apple platforms.
    struct AsyncBytes: AsyncSequence {
        public typealias Element = UInt8
        private let data: Data

        init(data: Data) {
            self.data = data
        }

        struct Iterator: AsyncIteratorProtocol {
            private let data: Data
            private var index: Int = 0
            init(data: Data) { self.data = data }
            mutating func next() async throws -> UInt8? {
                guard index < data.count else { return nil }
                let byte = data[index]
                index += 1
                return byte
            }
        }

        func makeAsyncIterator() -> Iterator { Iterator(data: data) }

        var lines: AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in
                Task {
                    var buffer = Data()
                    for byte in data {
                        if byte == UInt8(ascii: "\n") {
                            if let str = String(data: buffer, encoding: .utf8) {
                                continuation.yield(str)
                            }
                            buffer.removeAll(keepingCapacity: true)
                        } else {
                            buffer.append(byte)
                        }
                    }
                    if !buffer.isEmpty, let str = String(data: buffer, encoding: .utf8) {
                        continuation.yield(str)
                    }
                    continuation.finish()
                }
            }
        }
    }

    func bytes(for request: URLRequest) async throws -> (AsyncBytes, URLResponse) {
        let (data, response) = try await self.data(for: request)
        return (AsyncBytes(data: data), response)
    }
    #endif
}
