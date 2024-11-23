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

    public func perform<Request: LangToolsRequest>(request: Request) async throws -> Request.Response {
        guard let langTool = langTools[request.url.host()!], langTool.canHandleRequest(request) else { throw LangToolchainError.toolchainCannotHandleRequest }
        return try await langTool.perform(request: request)
    }

    public func stream<Request: LangToolsStreamableRequest>(request: Request) throws -> AsyncThrowingStream<any LangToolsStreamableResponse, Error> {
        guard let langTool = langTools[request.url.host()!], langTool.canHandleRequest(request) else { throw LangToolchainError.toolchainCannotHandleRequest }
        return langTool.stream(request: request).mapAsyncThrowingStream { $0 }
    }
}
