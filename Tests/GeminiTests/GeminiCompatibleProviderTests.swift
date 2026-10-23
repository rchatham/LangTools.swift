//
//  GeminiCompatibleProviderTests.swift
//  GeminiTests
//

import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LangTools
import OpenAI
import OpenAICompatible
import Gemini

final class GeminiCompatibleProviderTests: XCTestCase {
    func testTypedModelsStillRouteUntagged() throws {
        var toolchain = LangToolchain()
        toolchain.register(OpenAI(apiKey: "openai"))
        toolchain.register(Gemini(apiKey: "key"))
        let typed = OpenAI.ChatCompletionRequest(model: Gemini.Model.gemini3Flash, messages: [.init(role: .user, content: "Hi")])
        let native = try XCTUnwrap(Gemini.chatRequest(model: Gemini.Model.gemini3Flash, messages: [], tools: nil, responseSchema: nil, toolEventHandler: { _ in }) as? Gemini.GenerateContentRequest)

        XCTAssertNil(typed.model.providerID)
        XCTAssertEqual(try toolchain.prepare(request: typed).url?.path, "/v1beta/openai/chat/completions")
        XCTAssertEqual(try toolchain.prepare(request: native).url?.path, "/v1beta/models/gemini-3-flash:generateContent")
    }

    func testOtherModelIDsRouteAsTaggedCompatibleModels() throws {
        var toolchain = LangToolchain()
        toolchain.register(OpenAI(apiKey: "openai"))
        toolchain.register(Gemini(apiKey: "key"))
        let model: OpenAICompatibleModel<Gemini> = "gemini-4-preview"
        let request = try XCTUnwrap(Gemini.chatRequest(model: model, messages: [], tools: nil, responseSchema: nil, toolEventHandler: { _ in }) as? OpenAI.ChatCompletionRequest)

        XCTAssertTrue(request.model.belongs(to: Gemini.providerID))
        XCTAssertEqual(try toolchain.prepare(request: request).url?.path, "/v1beta/openai/chat/completions")
        XCTAssertFalse(OpenAI.requestValidators.contains { $0(request) })
    }

    func testKnownModelsMirrorTheModelEnum() {
        XCTAssertEqual(Gemini.knownModels.map(\.rawValue), Gemini.Model.allCases.map(\.rawValue))
    }
}
