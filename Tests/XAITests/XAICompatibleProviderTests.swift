//
//  XAICompatibleProviderTests.swift
//  XAITests
//

import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LangTools
import OpenAI
import OpenAICompatible
import XAI

final class XAICompatibleProviderTests: XCTestCase {
    func testTypedModelsStillRouteUntagged() throws {
        var toolchain = LangToolchain()
        toolchain.register(OpenAI(apiKey: "openai"))
        toolchain.register(XAI(apiKey: "key"))
        let typed = try XCTUnwrap(XAI.chatRequest(model: XAI.Model.grok41FastReasoning, messages: [], tools: nil, responseSchema: nil, toolEventHandler: { _ in }) as? OpenAI.ChatCompletionRequest)

        XCTAssertNil(typed.model.providerID)
        XCTAssertEqual(try toolchain.prepare(request: typed).url?.host, "api.x.ai")
    }

    func testOtherModelIDsRouteAsTaggedCompatibleModels() throws {
        var toolchain = LangToolchain()
        toolchain.register(OpenAI(apiKey: "openai"))
        toolchain.register(XAI(apiKey: "key"))
        let model: OpenAICompatibleModel<XAI> = "grok-5-preview"
        let request = try XCTUnwrap(XAI.chatRequest(model: model, messages: [], tools: nil, responseSchema: nil, toolEventHandler: { _ in }) as? OpenAI.ChatCompletionRequest)

        XCTAssertTrue(request.model.belongs(to: XAI.providerID))
        XCTAssertEqual(try toolchain.prepare(request: request).url?.path, "/v1/chat/completions")
        XCTAssertFalse(OpenAI.requestValidators.contains { $0(request) })
    }

    func testKnownModelsMirrorTheModelEnum() {
        XCTAssertEqual(XAI.knownModels.map(\.rawValue), XAI.Model.allCases.map(\.rawValue))
    }
}
