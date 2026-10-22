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
        let typed = try XCTUnwrap(Gemini.chatRequest(model: Gemini.Model.gemini25Flash, messages: [], tools: nil, responseSchema: nil, toolEventHandler: { _ in }) as? OpenAI.ChatCompletionRequest)

        XCTAssertNil(typed.model.providerID)
        XCTAssertEqual(try toolchain.prepare(request: typed).url?.host, "generativelanguage.googleapis.com")
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
