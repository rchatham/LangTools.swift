//
//  LangToolsService.swift
//  LangTools_Example
//
//  Created by Reid Chatham on 11/16/24.
//

import Foundation
import LangTools

enum LangToolchainError: String, Error {
    case toolchainCannotHandleRequest
}

struct LangToolchain {

    public mutating func register<LangTool: LangTools>(_ langTools: LangTool) {
        self.langTools[LangTool.url.host()!] = langTools
    }

    private var langTools: [String:(any LangTools)] = [:]

    public func perform<ChatRequest: LangToolsChatRequest>(request: ChatRequest) async throws -> ChatRequest.ChatResponse {
        guard let langTool = langTools[ChatRequest.url.host()!], langTool.canHandleRequest(request) else { throw LangToolchainError.toolchainCannotHandleRequest }
        return try await langTool.perform(request: request)
    }

    public func stream<ChatRequest: LangToolsStreamableChatRequest>(request: ChatRequest) throws -> AsyncThrowingStream<any LangToolsChatResponse, Error> {
        guard let langTool = langTools[ChatRequest.url.host()!], langTool.canHandleRequest(request) else { throw LangToolchainError.toolchainCannotHandleRequest }
        return langTool.stream(request: request).mapAsyncThrowingStream { $0 }
    }
}


extension AsyncThrowingStream {
    func mapAsyncThrowingStream<T, E>(_ map: @escaping (Element) -> T) -> AsyncThrowingStream<T, E> where E == Error {
        var iterator = self.makeAsyncIterator()
        return AsyncThrowingStream<T, E>(unfolding: { try await iterator.next().flatMap { map($0) } })
    }
}

