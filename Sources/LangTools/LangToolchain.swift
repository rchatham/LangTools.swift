//
//  LangToolchain.swift
//  App
//
//  Created by Reid Chatham on 11/17/24.
//

import Foundation


public struct LangToolchain {
    public var logger: LangToolsLogger?

    public init(langTools: [String : any LangTools] = [:], logger: LangToolsLogger? = nil) {
        self.langTools = langTools
        self.logger = logger
    }

    public mutating func register<LangTool: LangTools>(_ langTools: LangTool) {
        let key = String(describing: LangTool.self)
        self.langTools[key] = langTools
        logger?.debug("LangToolchain: Registered provider '\(key)'")
        logger?.debug("Total providers: \(self.langTools.count)")
    }

    public func langTool<LangTool: LangTools>(_ type: LangTool.Type) -> LangTool? {
        langTools[String(describing: type.self)] as? LangTool
    }

    private var langTools: [String:(any LangTools)] = [:]

    public func perform<Request: LangToolsRequest>(request: Request) async throws -> Request.Response {
        logger?.debug("LangToolchain.perform() called")
        logger?.debug("Request type: \(type(of: request))")
        logger?.debug("Registered providers: \(langTools.keys.joined(separator: ", "))")
        logger?.debug("Checking which provider can handle request...")

        for (key, tool) in langTools {
            let canHandle = tool.canHandleRequest(request)
            logger?.debug("- \(key): \(canHandle ? "CAN handle" : "cannot handle")")
        }

        guard let langTool = langTools.values.first(where: { $0.canHandleRequest(request) }) else {
            logger?.warning("NO PROVIDER CAN HANDLE THIS REQUEST!")
            throw LangToolchainError.toolchainCannotHandleRequest
        }

        logger?.debug("Using provider: \(type(of: langTool))")
        return try await langTool.perform(request: request)
    }

    public func stream<Request: LangToolsStreamableRequest>(request: Request) -> AsyncThrowingStream<Request.Response, Error> {
        guard let langTool = langTools.values.first(where: { $0.canHandleRequest(request) }) else {
            return AsyncSingleErrorStream(error: LangToolchainError.toolchainCannotHandleRequest) }
        return langTool.stream(request: request)
    }

    public func stream<Request: LangToolsStreamableRequest>(request: Request) throws -> AsyncThrowingStream<any LangToolsStreamableResponse, Error> {
        logger?.debug("LangToolchain.stream() called")
        logger?.debug("Request type: \(type(of: request))")
        logger?.debug("Registered providers: \(langTools.keys.joined(separator: ", "))")
        logger?.debug("Checking which provider can handle request...")

        for (key, tool) in langTools {
            let canHandle = tool.canHandleRequest(request)
            logger?.debug("- \(key): \(canHandle ? "CAN handle" : "cannot handle")")
        }

        guard let langTool = langTools.values.first(where: { $0.canHandleRequest(request) }) else {
            logger?.warning("NO PROVIDER CAN HANDLE THIS REQUEST!")
            logger?.debug("This means no API key is configured or provider not registered")
            throw LangToolchainError.toolchainCannotHandleRequest
        }

        logger?.debug("Using provider: \(type(of: langTool))")
        return langTool.stream(request: request).mapAsyncThrowingStream { $0 }
    }
}

public enum LangToolchainError: String, Error {
    case toolchainCannotHandleRequest
}
