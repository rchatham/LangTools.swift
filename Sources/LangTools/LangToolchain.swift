//
//  LangToolchain.swift
//  App
//
//  Created by Reid Chatham on 11/17/24.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct LangToolchain {
    public var logger: LangToolsLogger?

    public init(langTools: [String: any LangTools] = [:], logger: LangToolsLogger? = nil) {
        self.langTools = langTools
        providerOrder = langTools.keys.sorted()
        self.logger = logger
    }

    public mutating func register<LangTool: LangTools>(_ langTools: LangTool) {
        let key = String(describing: LangTool.self)
        if self.langTools[key] == nil {
            providerOrder.append(key)
        }
        self.langTools[key] = langTools
        logger?.debug("LangToolchain: Registered provider '\(key)'")
        logger?.debug("Total providers: \(self.langTools.count)")
    }

    public func langTool<LangTool: LangTools>(_ type: LangTool.Type) -> LangTool? {
        langTools[String(describing: type.self)] as? LangTool
    }

    private var langTools: [String: any LangTools]
    private var providerOrder: [String]

    /// Prepares a request using the first registered provider that accepts it,
    /// without performing network I/O. Dictionary-initialized providers are
    /// checked in sorted-key order; replacing a provider retains its position.
    /// The returned request can contain provider credentials; do not log it.
    public func prepare<Request: LangToolsRequest>(request: Request) throws -> URLRequest {
        try selectProvider(for: request, operation: "prepare").prepare(request: request)
    }

    public func perform<Request: LangToolsRequest>(request: Request) async throws -> Request.Response {
        let langTool = try selectProvider(for: request, operation: "perform")
        return try await langTool.perform(request: request)
    }

    /// Preserves each intermediate response callback on the selected provider,
    /// including recursive tool completions, rather than reporting only the final response.
    public func perform<Request: LangToolsRequest>(request: Request, onResponse: @escaping (Request.Response) -> Void) async throws -> Request.Response {
        let langTool = try selectProvider(for: request, operation: "perform")
        return try await langTool.perform(request: request, onResponse: onResponse)
    }

    public func stream<Request: LangToolsStreamableRequest>(request: Request) -> AsyncThrowingStream<Request.Response, Error> {
        do {
            return try selectProvider(for: request, operation: "stream").stream(request: request)
        } catch {
            return AsyncSingleErrorStream(error: error)
        }
    }

    public func stream<Request: LangToolsStreamableRequest>(request: Request) throws -> AsyncThrowingStream<any LangToolsStreamableResponse, Error> {
        let langTool = try selectProvider(for: request, operation: "stream")
        return langTool.stream(request: request).mapAsyncThrowingStream { $0 }
    }

    private func selectProvider<Request: LangToolsRequest>(
        for request: Request,
        operation: String
    ) throws -> any LangTools {
        logger?.debug("LangToolchain.\(operation)() called")
        logger?.debug("Request type: \(type(of: request))")
        logger?.debug("Registered providers: \(providerOrder.joined(separator: ", "))")
        logger?.debug("Checking which provider can handle request...")

        for key in providerOrder {
            guard let langTool = langTools[key] else { continue }
            let canHandle = langTool.canHandleRequest(request)
            logger?.debug("- \(key): \(canHandle ? "CAN handle" : "cannot handle")")
            if canHandle {
                logger?.debug("Using provider: \(type(of: langTool))")
                return langTool
            }
        }

        logger?.warning("NO PROVIDER CAN HANDLE THIS REQUEST!")
        throw LangToolchainError.toolchainCannotHandleRequest
    }
}

public enum LangToolchainError: String, Error {
    case toolchainCannotHandleRequest
}
