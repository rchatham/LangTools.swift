//
//  Utilities.swift
//  LangTools_Example
//
//  Created by Reid Chatham on 11/21/24.
//

infix operator ?=
func ?=<T>(_ lhs: inout T, _ rhs: T?) {
    if let rhs { lhs = rhs }
}

func ?=<T>(_ lhs: inout T?, _ rhs: T?) {
    if let rhs { lhs = rhs }
}

extension AsyncThrowingStream {
    func mapAsyncThrowingStream<T, E>(_ map: @escaping (Element) -> T) -> AsyncThrowingStream<T, E> where E == Error {
        var iterator = self.makeAsyncIterator()
        return AsyncThrowingStream<T, E>(unfolding: { try await iterator.next().flatMap { map($0) } })
    }

    func compactMapAsyncThrowingStream<T, E>(_ compactMap: @escaping (Element) -> T?) -> AsyncThrowingStream<T, E> where E == Error {
        return AsyncThrowingStream<T, E> { continuation in
            Task {
                for try await value in self {
                    if let mapped = compactMap(value) {
                        continuation.yield(mapped)
                    }
                }
                continuation.finish()
            }
        }
    }
}
