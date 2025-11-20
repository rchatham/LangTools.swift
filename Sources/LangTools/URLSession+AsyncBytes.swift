import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension URLSession {
    #if !canImport(Darwin)
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
