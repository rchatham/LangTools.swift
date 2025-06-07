//
//  Utilities.swift
//  LangTools_Example
//
//  Created by Reid Chatham on 11/21/24.
//

import Foundation

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

extension String {
    func trimingTrailingNewlines() -> String {
        return trimingTrailingCharacters(using: .newlines)
    }

    func trimingTrailingCharacters(using characterSet: CharacterSet = .whitespacesAndNewlines) -> String {
        guard let index = lastIndex(where: { !CharacterSet(charactersIn: String($0)).isSubset(of: characterSet) }) else {
            return self
        }

        return String(self[...index])
    }

    func trimingLeadingNewlines() -> String {
        return trimingLeadingCharacters(using: .newlines)
    }

    func trimingLeadingCharacters(using characterSet: CharacterSet = .whitespacesAndNewlines) -> String {
        guard let index = firstIndex(where: { !CharacterSet(charactersIn: String($0)).isSubset(of: characterSet) }) else {
            return self
        }

        return String(self[index...])
    }
}
