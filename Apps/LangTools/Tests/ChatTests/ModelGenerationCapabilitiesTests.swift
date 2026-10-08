import Anthropic
import Gemini
import Ollama
import OpenAI
import XAI
import XCTest
@testable import Chat

final class ModelGenerationCapabilitiesTests: XCTestCase {
    private let legacyOpenAI: Set<String> = [
        "gpt-3.5-turbo", "gpt-3.5-turbo-0301", "gpt-3.5-turbo-1106",
        "gpt-3.5-turbo-16k", "gpt-4", "gpt-4-turbo", "gpt-4-0613",
        "gpt-4-1106-preview", "gpt-4-vision-preview", "gpt-4-32k-0613",
        "gpt-4o-2024-05-13",
    ]
    private let modern4oOpenAI: Set<String> = [
        "gpt-4o", "gpt-4o-mini", "gpt-4o-2024-08-06", "gpt-4o-2024-11-20",
        "gpt-4o-mini-2024-07-18",
    ]
    private let gpt41OpenAI: Set<String> = [
        "gpt-4.1", "gpt-4.1-mini", "gpt-4.1-nano",
    ]
    private let reasoningOpenAI: [String: Int] = [
        "o1": 100_000, "o1-mini": 65_536, "o1-preview": 32_768,
        "o3": 100_000, "o3-pro": 100_000, "o3-mini": 100_000, "o4-mini": 100_000,
        "gpt-5": 128_000, "gpt-5-mini": 128_000, "gpt-5-nano": 128_000,
        "gpt-5-pro": 272_000, "gpt-5.1": 128_000, "gpt-5.2": 128_000,
        "gpt-5.2-pro": 128_000, "gpt-5.3": 32_768, "gpt-5.4": 128_000,
        "gpt-5.4-pro": 128_000, "gpt-5.4-mini": 128_000, "gpt-5.4-nano": 128_000,
        "gpt-5.5": 128_000, "gpt-5.5-pro": 128_000,
    ]
    private let anthropicBounds: [String: Int] = [
        "claude-opus-4-6": 128_000, "claude-opus-4-6-20260205": 128_000,
        "claude-sonnet-4-6": 128_000, "claude-sonnet-4-6-20260217": 128_000,
        "claude-opus-4-5-20251101": 64_000, "claude-sonnet-4-5-latest": 64_000,
        "claude-sonnet-4-5-20250929": 64_000, "claude-haiku-4-5-latest": 64_000,
        "claude-haiku-4-5-20251001": 64_000,
    ]
    private let geminiBounds: [String: Int] = [
        "gemini-3-pro-preview": 65_536, "gemini-3-flash-preview": 65_536,
        "gemini-2.5-flash": 65_536, "gemini-2.5-flash-lite": 65_536,
        "gemini-2.5-pro": 65_536,
        "gemini-2.0-flash": 8_192, "gemini-2.0-flash-lite": 8_192,
    ]
    private let supportedXAI: Set<String> = [
        "grok-4-1-fast-reasoning", "grok-4-1-fast-non-reasoning",
        "grok-4-fast-reasoning", "grok-4-fast-non-reasoning", "grok-4-0709",
        "grok-3", "grok-3-mini", "grok-code-fast-1", "grok-2-vision-1212",
        "grok-2-1212", "grok-beta",
    ]

    func testAccountRoutesSupportNeitherOverrideAndExplainWhy() throws {
        let anthropic = try XCTUnwrap(Anthropic.Model.allCases.first)
        for model in [Model.codex(.gpt5_5), .claudeCode(anthropic)] {
            let capabilities = model.generationCapabilities
            XCTAssertFalse(capabilities.supportsAnyOverride)
            XCTAssertNil(capabilities.maximumOutputTokenBound)
            XCTAssertEqual(
                capabilities.unsupportedReason,
                "Account-backed transport does not support advanced generation parameters."
            )
        }
    }

    func testOpenAIModelsAreExhaustivelyClassified() {
        let ordinaryOpenAI = legacyOpenAI.union(modern4oOpenAI).union(gpt41OpenAI)
        XCTAssertTrue(ordinaryOpenAI.isDisjoint(with: Set(reasoningOpenAI.keys)))

        for providerModel in OpenAI.Model.allCases {
            let capabilities = Model.openAI(providerModel).generationCapabilities
            if legacyOpenAI.contains(providerModel.rawValue) {
                assertOrdinary(capabilities, bound: 4_096, modelID: providerModel.rawValue)
            } else if modern4oOpenAI.contains(providerModel.rawValue) {
                assertOrdinary(capabilities, bound: 16_384, modelID: providerModel.rawValue)
            } else if gpt41OpenAI.contains(providerModel.rawValue) {
                assertOrdinary(capabilities, bound: 32_768, modelID: providerModel.rawValue)
            } else if let bound = reasoningOpenAI[providerModel.rawValue] {
                XCTAssertEqual(capabilities.maximumOutputField, .openAIMaxCompletionTokens, providerModel.rawValue)
                XCTAssertEqual(capabilities.maximumOutputTokenBound, bound, providerModel.rawValue)
                XCTAssertFalse(capabilities.supportsTemperature, providerModel.rawValue)
                XCTAssertTrue(capabilities.supportsTopP, providerModel.rawValue)
                XCTAssertFalse(capabilities.supportsFrequencyPenalty, providerModel.rawValue)
                XCTAssertFalse(capabilities.supportsPresencePenalty, providerModel.rawValue)
                XCTAssertFalse(capabilities.supportsTopK, providerModel.rawValue)
                XCTAssertFalse(capabilities.supportsSeed, providerModel.rawValue)
                XCTAssertTrue(capabilities.supportsStop, providerModel.rawValue)
            } else {
                XCTAssertFalse(capabilities.supportsAnyOverride, providerModel.rawValue)
                XCTAssertNil(capabilities.maximumOutputTokenBound, providerModel.rawValue)
            }
        }

        let allModelIDs = Set(OpenAI.Model.allCases.map(\.rawValue))
        XCTAssertEqual(allModelIDs.intersection(ordinaryOpenAI), ordinaryOpenAI)
        XCTAssertEqual(allModelIDs.intersection(reasoningOpenAI.keys), Set(reasoningOpenAI.keys))
    }

    func testInstructModelFailsClosed() {
        assertUnsupportedOpenAI("gpt-3.5-turbo-instruct", reasonContains: "completion-only")
    }

    func testCodexSparkModelFailsClosed() {
        assertUnsupportedOpenAI("gpt-5.3-codex-spark", reasonContains: "Codex-only")
    }

    func testUnknownOpenAIModelFailsClosed() {
        assertUnsupportedOpenAI("future-chat-model")
    }

    func testChatGPT4oLatestFailsClosedBecauseAliasIsMutable() {
        assertUnsupportedOpenAI("chatgpt-4o-latest", reasonContains: "mutable")
    }

    func testRepresentativeOpenAIBounds() {
        assertOrdinary(openAICapabilities("gpt-3.5-turbo"), bound: 4_096, modelID: "gpt-3.5-turbo")
        assertOrdinary(openAICapabilities("gpt-4"), bound: 4_096, modelID: "gpt-4")
        assertOrdinary(openAICapabilities("gpt-4o-2024-05-13"), bound: 4_096, modelID: "gpt-4o-2024-05-13")
        assertOrdinary(openAICapabilities("gpt-4o-2024-11-20"), bound: 16_384, modelID: "gpt-4o-2024-11-20")
        assertOrdinary(openAICapabilities("gpt-4o-mini"), bound: 16_384, modelID: "gpt-4o-mini")
        assertOrdinary(openAICapabilities("gpt-4.1"), bound: 32_768, modelID: "gpt-4.1")

        for (modelID, bound) in [
            "o1": 100_000, "o1-mini": 65_536, "o1-preview": 32_768,
            "o3": 100_000, "o3-pro": 100_000, "o3-mini": 100_000, "o4-mini": 100_000,
            "gpt-5": 128_000, "gpt-5-pro": 272_000, "gpt-5.5-pro": 128_000,
        ] {
            let capabilities = openAICapabilities(modelID)
            XCTAssertEqual(capabilities.maximumOutputField, .openAIMaxCompletionTokens, modelID)
            XCTAssertEqual(capabilities.maximumOutputTokenBound, bound, modelID)
            XCTAssertFalse(capabilities.supportsTemperature, modelID)
            XCTAssertTrue(capabilities.supportsTopP, modelID)
            XCTAssertFalse(capabilities.supportsFrequencyPenalty, modelID)
            XCTAssertTrue(capabilities.supportsStop, modelID)
        }
    }

    func testAnthropicModelsUseDocumentedModernBoundsAndConservativeLegacyBounds() {
        for providerModel in Anthropic.Model.allCases {
            let capabilities = Model.anthropic(providerModel).generationCapabilities
            XCTAssertEqual(capabilities.maximumOutputField, .anthropicMaxTokens, providerModel.rawValue)
            XCTAssertEqual(
                capabilities.maximumOutputTokenBound,
                anthropicBounds[providerModel.rawValue] ?? 4_096,
                providerModel.rawValue
            )
            XCTAssertTrue(capabilities.supportsTemperature, providerModel.rawValue)
            XCTAssertTrue(capabilities.supportsTopP, providerModel.rawValue)
            XCTAssertTrue(capabilities.supportsTopK, providerModel.rawValue)
            XCTAssertFalse(capabilities.supportsFrequencyPenalty, providerModel.rawValue)
            XCTAssertFalse(capabilities.supportsPresencePenalty, providerModel.rawValue)
            XCTAssertFalse(capabilities.supportsSeed, providerModel.rawValue)
            XCTAssertTrue(capabilities.supportsStop, providerModel.rawValue)
        }
        XCTAssertEqual(Set(Anthropic.Model.allCases.map(\.rawValue)).intersection(anthropicBounds.keys), Set(anthropicBounds.keys))
    }

    func testXAIModelsAreExhaustivelyClassifiedWithAppGuard() {
        for providerModel in XAI.Model.allCases {
            let capabilities = Model.xAI(providerModel).generationCapabilities
            if supportedXAI.contains(providerModel.rawValue) {
                XCTAssertEqual(capabilities.maximumOutputField, .openAIMaxTokens, providerModel.rawValue)
                XCTAssertEqual(capabilities.maximumOutputTokenBound, ChatGenerationSettings.tokenRange.upperBound, providerModel.rawValue)
                XCTAssertTrue(capabilities.supportsTemperature, providerModel.rawValue)
                XCTAssertTrue(capabilities.supportsTopP, providerModel.rawValue)
                XCTAssertTrue(capabilities.supportsFrequencyPenalty, providerModel.rawValue)
                XCTAssertTrue(capabilities.supportsPresencePenalty, providerModel.rawValue)
                XCTAssertFalse(capabilities.supportsTopK, providerModel.rawValue)
                XCTAssertTrue(capabilities.supportsSeed, providerModel.rawValue)
                XCTAssertTrue(capabilities.supportsStop, providerModel.rawValue)
                XCTAssertTrue(capabilities.maximumOutputWarning?.contains("not a model limit") == true, providerModel.rawValue)
            } else {
                XCTAssertFalse(capabilities.supportsAnyOverride, providerModel.rawValue)
                XCTAssertNil(capabilities.maximumOutputTokenBound, providerModel.rawValue)
            }
        }
        XCTAssertEqual(Set(XAI.Model.allCases.map(\.rawValue)).intersection(supportedXAI), supportedXAI)
    }

    func testGeminiModelsUseDocumentedBoundsAndConservativeUnverifiedBounds() {
        for providerModel in Gemini.Model.allCases {
            let capabilities = Model.gemini(providerModel).generationCapabilities
            XCTAssertEqual(capabilities.maximumOutputField, .openAIMaxTokens, providerModel.rawValue)
            XCTAssertEqual(
                capabilities.maximumOutputTokenBound,
                geminiBounds[providerModel.rawValue] ?? 4_096,
                providerModel.rawValue
            )
            XCTAssertTrue(capabilities.supportsTemperature, providerModel.rawValue)
            XCTAssertTrue(capabilities.supportsTopP, providerModel.rawValue)
            XCTAssertTrue(capabilities.supportsFrequencyPenalty, providerModel.rawValue)
            XCTAssertTrue(capabilities.supportsPresencePenalty, providerModel.rawValue)
            XCTAssertFalse(capabilities.supportsTopK, providerModel.rawValue)
            XCTAssertTrue(capabilities.supportsSeed, providerModel.rawValue)
            XCTAssertTrue(capabilities.supportsStop, providerModel.rawValue)
        }
        XCTAssertEqual(Set(Gemini.Model.allCases.map(\.rawValue)).intersection(geminiBounds.keys), Set(geminiBounds.keys))
    }

    func testArbitraryOllamaModelsUseAppCeilingWithWarning() throws {
        let providerModel = try XCTUnwrap(Ollama.Model(rawValue: "private-model:latest"))
        let capabilities = Model.ollama(providerModel).generationCapabilities
        XCTAssertEqual(capabilities.maximumOutputField, .ollamaNumPredict)
        XCTAssertEqual(capabilities.maximumOutputTokenBound, ChatGenerationSettings.tokenRange.upperBound)
        XCTAssertTrue(capabilities.supportsTemperature)
        XCTAssertTrue(capabilities.supportsTopP)
        XCTAssertTrue(capabilities.supportsFrequencyPenalty)
        XCTAssertTrue(capabilities.supportsPresencePenalty)
        XCTAssertTrue(capabilities.supportsTopK)
        XCTAssertTrue(capabilities.supportsSeed)
        XCTAssertTrue(capabilities.supportsStop)
        XCTAssertTrue(capabilities.maximumOutputWarning?.contains("app guard") == true)
        XCTAssertTrue(capabilities.maximumOutputWarning?.contains("not a model limit") == true)
    }

    private func openAICapabilities(_ modelID: String) -> ChatGenerationCapabilities {
        Model.openAI(OpenAI.Model(customModelID: modelID)).generationCapabilities
    }

    private func assertUnsupportedOpenAI(_ modelID: String, reasonContains: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let capabilities = openAICapabilities(modelID)
        XCTAssertFalse(capabilities.supportsAnyOverride, modelID, file: file, line: line)
        XCTAssertNil(capabilities.maximumOutputTokenBound, modelID, file: file, line: line)
        XCTAssertNotNil(capabilities.unsupportedReason, modelID, file: file, line: line)
        if let reasonContains {
            XCTAssertTrue(capabilities.unsupportedReason?.contains(reasonContains) == true, modelID, file: file, line: line)
        }
    }

    private func assertOrdinary(
        _ capabilities: ChatGenerationCapabilities,
        bound: Int,
        modelID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(capabilities.maximumOutputField, .openAIMaxTokens, modelID, file: file, line: line)
        XCTAssertEqual(capabilities.maximumOutputTokenBound, bound, modelID, file: file, line: line)
        XCTAssertTrue(capabilities.supportsTemperature, modelID, file: file, line: line)
        XCTAssertTrue(capabilities.supportsTopP, modelID, file: file, line: line)
        XCTAssertTrue(capabilities.supportsFrequencyPenalty, modelID, file: file, line: line)
        XCTAssertTrue(capabilities.supportsPresencePenalty, modelID, file: file, line: line)
        XCTAssertFalse(capabilities.supportsTopK, modelID, file: file, line: line)
        XCTAssertTrue(capabilities.supportsSeed, modelID, file: file, line: line)
        XCTAssertTrue(capabilities.supportsStop, modelID, file: file, line: line)
    }
}
