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
                let task = dataTask(with: request) { data, response, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else if let data = data, let response = response {
                        continuation.resume(returning: (data, response))
                    } else {
                        continuation.resume(throwing: URLError(.badServerResponse))
                    }
                }
                cancellation.start(task)
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private final class DataTaskCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionDataTask?
        private var isCancelled = false

        func start(_ task: URLSessionDataTask) {
            lock.lock()
            self.task = task
            let isCancelled = isCancelled
            lock.unlock()
            task.resume()
            // Cancellation may arrive before the task exists; the cancelled task
            // still calls its completion handler, which resumes the continuation.
            if isCancelled { task.cancel() }
        }

        func cancel() {
            lock.lock()
            isCancelled = true
            let task = task
            lock.unlock()
            task?.cancel()
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
