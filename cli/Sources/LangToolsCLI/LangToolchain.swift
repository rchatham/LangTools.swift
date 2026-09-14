//
//  LangToolsService.swift
//  LangTools_Example
//
//  Created by Reid Chatham on 11/16/24.
//

import Foundation
import LangTools

enum LangToolchainError: String, LocalizedError {
    case toolchainCannotHandleRequest

    var errorDescription: String? {
        switch self {
        case .toolchainCannotHandleRequest:
            return "No registered provider can handle the selected model. Set an API key for the provider or choose another model with /model."
        }
    }
}

struct LangToolchain {
    public mutating func register<LangTool: LangTools>(_ langTool: LangTool) {
        self.langTools[String(describing: LangTool.self)] = langTool
    }

    private var langTools: [String: (any LangTools)] = [:]

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
}
