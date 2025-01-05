//
//  Utilities.swift
//  LangTools_Example
//
//  Created by Reid Chatham on 11/21/24.
//

infix operator ?=: AssignmentPrecedence
func ?=<T>(_ lhs: inout T, _ rhs: T?) {
    if let rhs { lhs = rhs }
}

func ?=<T>(_ lhs: inout T?, _ rhs: T?) {
    if let rhs { lhs = rhs }
}

extension AsyncThrowingStream {
    func mapAsyncThrowingStream<T>(_ map: @escaping (Element) -> T) -> AsyncThrowingStream<T, Error> {
        var iterator = self.makeAsyncIterator()
        return AsyncThrowingStream<T, Error>(unfolding: { try await iterator.next().flatMap { map($0) } })
    }

    func compactMapAsyncThrowingStream<T>(_ compactMap: @escaping (Element) -> T?) -> AsyncThrowingStream<T, Error> {
        return AsyncThrowingStream<T, Error> { continuation in
            Task {
                do {
                    for try await value in self {
                        if let mapped = compactMap(value) {
                            continuation.yield(mapped)
                        }
                    }
                } catch { continuation.finish(throwing: error) }
                continuation.finish()
            }
        }
    }
}
