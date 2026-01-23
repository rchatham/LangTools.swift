//
//  LangToolchain.swift
//  App
//
//  Created by Reid Chatham on 11/17/24.
//

import Foundation


public struct LangToolchain {
    public init(langTools: [String : any LangTools] = [:]) {
        self.langTools = langTools
    }

    public mutating func register<LangTool: LangTools>(_ langTools: LangTool) {
        let key = String(describing: LangTool.self)
        self.langTools[key] = langTools
        print("🔧 LangToolchain: Registered provider '\(key)'")
        print("   Total providers: \(self.langTools.count)")
    }

    public func langTool<LangTool: LangTools>(_ type: LangTool.Type) -> LangTool? {
        langTools[String(describing: type.self)] as? LangTool
    }

    private var langTools: [String:(any LangTools)] = [:]

    public func perform<Request: LangToolsRequest>(request: Request) async throws -> Request.Response {
        print("🔍 LangToolchain.perform() called")
        print("   Request type: \(type(of: request))")
        print("   Registered providers: \(langTools.keys.joined(separator: ", "))")
        print("   Checking which provider can handle request...")

        for (key, tool) in langTools {
            let canHandle = tool.canHandleRequest(request)
            print("   - \(key): \(canHandle ? "✅ CAN handle" : "❌ cannot handle")")
        }

        guard let langTool = langTools.values.first(where: { $0.canHandleRequest(request) }) else {
            print("   ⚠️ NO PROVIDER CAN HANDLE THIS REQUEST!")
            throw LangToolchainError.toolchainCannotHandleRequest
        }

        print("   ✅ Using provider: \(type(of: langTool))")
        return try await langTool.perform(request: request)
    }

    public func stream<Request: LangToolsStreamableRequest>(request: Request) -> AsyncThrowingStream<Request.Response, Error> {
        guard let langTool = langTools.values.first(where: { $0.canHandleRequest(request) }) else {
            return AsyncSingleErrorStream(error: LangToolchainError.toolchainCannotHandleRequest) }
        return langTool.stream(request: request)
    }

    public func stream<Request: LangToolsStreamableRequest>(request: Request) throws -> AsyncThrowingStream<any LangToolsStreamableResponse, Error> {
        print("🌊 LangToolchain.stream() called")
        print("   Request type: \(type(of: request))")
        print("   Registered providers: \(langTools.keys.joined(separator: ", "))")
        print("   Checking which provider can handle request...")

        for (key, tool) in langTools {
            let canHandle = tool.canHandleRequest(request)
            print("   - \(key): \(canHandle ? "✅ CAN handle" : "❌ cannot handle")")
        }

        guard let langTool = langTools.values.first(where: { $0.canHandleRequest(request) }) else {
            print("   ⚠️ NO PROVIDER CAN HANDLE THIS REQUEST!")
            print("   This means no API key is configured or provider not registered")
            throw LangToolchainError.toolchainCannotHandleRequest
        }

        print("   ✅ Using provider: \(type(of: langTool))")
        return langTool.stream(request: request).mapAsyncThrowingStream { $0 }
    }
}

public enum LangToolchainError: String, Error {
    case toolchainCannotHandleRequest
}
