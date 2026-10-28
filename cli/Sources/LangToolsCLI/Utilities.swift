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
}
