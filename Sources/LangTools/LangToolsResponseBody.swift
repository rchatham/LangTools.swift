import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum LangToolsResponseBodyError: Error, Sendable {
    case overlappingRead
}

/// A single-consumer, pull-based response body. No buffering or line parsing is
/// imposed by this type. Concurrent reads are rejected, not queued.
public final class LangToolsResponseBody: Sendable {
    public let response: URLResponse
    private let cursor: Cursor
    private let readLine: @Sendable () async throws -> String?
    private let cancelUnderlying: @Sendable () -> Void

    /// `cancel` must be thread-safe, nonblocking and sticky: it must wake pending
    /// reads and make subsequently started reads terminate promptly. Neither
    /// callback is called under a lock. Do not recursively read this body.
    public init(
        response: URLResponse,
        nextLine: @escaping @Sendable () async throws -> String?,
        cancel: @escaping @Sendable () -> Void
    ) {
        self.response = response
        self.cursor = Cursor()
        self.readLine = nextLine
        self.cancelUnderlying = cancel
    }

    public func nextLine() async throws -> String? {
        // Admission MUST precede installing the handler: a cancelled overlapping
        // reader must never cancel the legitimate reader's underlying transport.
        if let terminal = try cursor.admit() { return try terminal.get() }
        return try await withTaskCancellationHandler {
            let result: Result<String?, Error>
            do {
                try Task.checkCancellation()
                result = .success(try await readLine())
            } catch {
                result = .failure(error)
            }
            let outcome = cursor.finish(result)
            if outcome.cleanup { cancelUnderlying() }
            return try outcome.result.get()
        } onCancel: {
            self.cancel()
        }
    }

    /// Ends consumption and cleans up exactly once, including after EOF/error.
    /// Owners must also cancel/join their reader tasks. An active read retains
    /// this body; deinitialization cannot break that task's lifetime.
    public func cancel() {
        if cursor.cancel() { cancelUnderlying() }
    }

    deinit { cancel() }

    // All mutable fields are protected by lock. No callback or await occurs
    // under it. This is the only unchecked synchronization claim for the gate;
    // the public body itself has compiler-checked Sendable conformance.
    private final class Cursor: @unchecked Sendable {
        private let lock = NSLock()
        private var active = false
        private var terminal: Result<String?, Error>?
        private var cleanedUp = false

        func admit() throws -> Result<String?, Error>? {
            lock.lock()
            defer { lock.unlock() }
            guard !active else { throw LangToolsResponseBodyError.overlappingRead }
            if let terminal { return terminal }
            active = true
            return nil
        }

        func finish(_ result: Result<String?, Error>) -> (result: Result<String?, Error>, cleanup: Bool) {
            lock.lock()
            defer { lock.unlock() }
            active = false
            if terminal == nil {
                switch result {
                case .success(.some): break
                case .success(.none), .failure: terminal = result
                }
            }
            let cleanup = terminal != nil && !cleanedUp
            if cleanup { cleanedUp = true }
            return (terminal ?? result, cleanup)
        }

        func cancel() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if terminal == nil { terminal = .failure(CancellationError()) }
            guard !cleanedUp else { return false }
            cleanedUp = true
            return true
        }
    }
}

extension LangTools {
    public func transportData(for request: URLRequest) async throws -> (Data, URLResponse) {
        #if canImport(Darwin)
        return try await session.data(for: request, delegate: session.delegate as? any URLSessionTaskDelegate)
        #else
        return try await session.data(for: request)
        #endif
    }

    public func transportBody(for request: URLRequest) async throws -> LangToolsResponseBody {
        try Task.checkCancellation()
        #if canImport(Darwin)
        let (bytes, response) = try await session.bytes(
            for: request, delegate: session.delegate as? any URLSessionTaskDelegate
        )
        // Once headers exist, cancellation must not orphan the acquired task.
        do { try Task.checkCancellation() } catch { bytes.task.cancel(); throw error }
        let iterator = ResponseLineIterator(bytes.lines.makeAsyncIterator())
        let task = bytes.task
        return LangToolsResponseBody(response: response, nextLine: {
            try await iterator.next()
        }, cancel: { task.cancel() })
        #else
        // Keep the existing fully buffered shim and its exact line semantics.
        let (bytes, response) = try await session.bytes(for: request)
        try Task.checkCancellation()
        let reader = BufferedResponseLineReader(bytes.lines.makeAsyncIterator())
        return LangToolsResponseBody(response: response, nextLine: {
            try await reader.next()
        }, cancel: { reader.cancel() })
        #endif
    }
}

// The escaping callback owns this box exclusively; there are no external
// iterator aliases/clones. Only a body's admitted reader accesses next().
// Cancellation touches the transport/reader task, NEVER the iterator. The
// body gate holds admission across suspension, protecting every iterator access.
private final class ResponseLineIterator<Iterator: AsyncIteratorProtocol>: @unchecked Sendable where Iterator.Element == String {
    private var iterator: Iterator
    init(_ iterator: Iterator) { self.iterator = iterator }
    func next() async throws -> String? { try await iterator.next() }
}

#if !canImport(Darwin)
// The buffered shim has no transport task after acquisition. A private reader
// task makes explicit body cancellation wake its AsyncThrowingStream iterator,
// including cancellation before that task is installed. No queue/parser added.
private final class BufferedResponseLineReader: @unchecked Sendable {
    private let iterator: ResponseLineIterator<AsyncThrowingStream<String, Error>.Iterator>
    private let lock = NSLock()
    private var cancelled = false
    private var task: Task<String?, Error>?

    init(_ iterator: AsyncThrowingStream<String, Error>.Iterator) {
        self.iterator = ResponseLineIterator(iterator)
    }

    func next() async throws -> String? {
        let iterator = self.iterator
        let reader = Task { try Task.checkCancellation(); return try await iterator.next() }
        install(reader)
        defer { clear() }
        return try await reader.value
    }

    private func install(_ reader: Task<String?, Error>) {
        lock.lock()
        task = reader
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { reader.cancel() }
    }

    private func clear() {
        lock.lock()
        task = nil
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let reader = task
        lock.unlock()
        reader?.cancel()
    }
}
#endif
