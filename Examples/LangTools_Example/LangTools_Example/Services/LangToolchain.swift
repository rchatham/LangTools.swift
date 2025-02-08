//
//  LangToolsService.swift
//  LangTools_Example
//
//  Created by Reid Chatham on 11/16/24.
//

import Foundation
import LangTools
import Agents

enum LangToolchainError: String, Error {
    case toolchainCannotHandleRequest
}

struct LangToolchain {
    public mutating func register<LangTool: LangTools>(_ langTool: LangTool) {
        self.langTools[String(describing: LangTool.self)] = langTool
    }

    public func langTool<LangTool: LangTools>(_ type: LangTool.Type) -> LangTool? {
        langTools[String(describing: type.self)] as? LangTool
    }

    private var langTools: [String:(any LangTools)] = [:]

    public func perform<Request: LangToolsRequest>(request: Request) async throws -> Request.Response {
        for langTool in langTools.values where langTool.canHandleRequest(request) {
            return try await langTool.perform(request: request)
        }
        throw LangToolchainError.toolchainCannotHandleRequest
    }

    public func stream<Request: LangToolsStreamableRequest>(request: Request) throws -> AsyncThrowingStream<any LangToolsStreamableResponse, Error> {
        for langTool in langTools.values where langTool.canHandleRequest(request) {
            return langTool.stream(request: request).mapAsyncThrowingStream { $0 }
        }
        throw LangToolchainError.toolchainCannotHandleRequest
    }

    public func execute(agent: any Agent, with context: AgentContext) async throws -> String {
        return try await agent.execute(context: context)
    }
}
