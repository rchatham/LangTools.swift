//
//  LangToolchain.swift
//  App
//
//  Created by Reid Chatham on 11/17/24.
//

import Foundation
import LangTools


public struct LangToolchain {
    public init(langTools: [String : any LangTools] = [:]) {
        self.langTools = langTools
    }

    public mutating func register<LangTool: LangTools>(_ langTools: LangTool) {
        self.langTools[String(describing: LangTool.self)] = langTools
    }

    public func langTool<LangTool: LangTools>(_ type: LangTool.Type) -> LangTool? {
        langTools[String(describing: type.self)] as? LangTool
    }

    private var langTools: [String:(any LangTools)] = [:]

    public func perform<Request: LangToolsRequest>(request: Request) async throws -> Request.Response {
        guard let langTool = langTools.values.first(where: { $0.canHandleRequest(request) }) else { throw LangToolchainError.toolchainCannotHandleRequest }
        return try await langTool.perform(request: request)
    }

    public func stream<Request: LangToolsStreamableRequest>(request: Request) -> AsyncThrowingStream<Request.Response, Error> {
        guard let langTool = langTools.values.first(where: { $0.canHandleRequest(request) }) else {
            return AsyncSingleErrorStream(error: LangToolchainError.toolchainCannotHandleRequest) }
        return langTool.stream(request: request)
    }

    public func stream<Request: LangToolsStreamableRequest>(request: Request) throws -> AsyncThrowingStream<any LangToolsStreamableResponse, Error> {
        guard let langTool = langTools.values.first(where: { $0.canHandleRequest(request) }) else {
            throw LangToolchainError.toolchainCannotHandleRequest }
        return langTool.stream(request: request).mapAsyncThrowingStream { $0 }
    }
}

public enum LangToolchainError: String, Error {
    case toolchainCannotHandleRequest
}
