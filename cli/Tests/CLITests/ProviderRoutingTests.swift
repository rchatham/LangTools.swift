//
//  ProviderRoutingTests.swift
//  CLITests
//
//  Model parsing, routing, and key discovery for the OpenAI-compatible providers.
//

import XCTest
import Ollama
import Gemini
import Cohere
import OpenAI
import OpenAICompatible
@testable import CLI

final class ProviderRoutingTests: XCTestCase {

    // MARK: - OpenAI-compatible providers

    func testModelFromArgumentAcceptsCompatibleProviderPrefixes() {
        XCTAssertEqual(CLI.model(fromArgument: "groq/llama-3.3-70b-versatile"), .compatible(.groq, "llama-3.3-70b-versatile"))
        XCTAssertEqual(CLI.model(fromArgument: "openrouter/openai/gpt-5:free"), .compatible(.openrouter, "openai/gpt-5:free"))
        XCTAssertEqual(CLI.model(fromArgument: "vercel/anthropic/claude-sonnet-4.5"), .compatible(.vercel, "anthropic/claude-sonnet-4.5"))
        XCTAssertEqual(CLI.model(fromArgument: "Fireworks/accounts/fireworks/models/deepseek-v3"), .compatible(.fireworks, "accounts/fireworks/models/deepseek-v3"))
        XCTAssertNil(CLI.model(fromArgument: "groq/ llama"), "padded IDs are rejected")
    }

    func testCompatibleModelRawValuesRoundTripAheadOfOllamaFallback() {
        for provider in CompatibleProvider.allCases {
            let model = Model.compatible(provider, provider.knownModelIDs[0])
            XCTAssertEqual(Model(rawValue: model.rawValue), model, "\(model.rawValue) must not fall through to the Ollama case")
            XCTAssertEqual(model.provider, provider.category)
            XCTAssertEqual(CompatibleProvider(category: provider.category), provider)
            XCTAssertEqual(CompatibleProvider(apiService: provider.apiService), provider)
        }
        XCTAssertNil(Model(rawValue: "groq/"))
        XCTAssertEqual(Model(rawValue: "mistral"), .ollama(Ollama.Model(rawValue: "mistral")!), "an unprefixed name stays an Ollama model")
    }

    func testCompatibleCapabilitiesFollowTheCatalog() {
        let previous = Model.compatibleCatalogs
        defer { Model.compatibleCatalogs = previous }
        Model.compatibleCatalogs = [.groq: [.init(id: "with-tools", supportsTools: true, metadata: ["supported_parameters": ["structured_outputs"]]), .init(id: "without-tools", supportsTools: false)]]

        XCTAssertEqual(Model.compatible(.groq, "with-tools").capabilities.toolReliability, .recommended)
        XCTAssertTrue(Model.compatible(.groq, "with-tools").capabilities.supportsStructuredOutput)
        XCTAssertFalse(Model.compatible(.groq, "without-tools").capabilities.supportsStructuredOutput)
        XCTAssertEqual(Model.compatible(.groq, "without-tools").capabilities.toolReliability, .unavailable)
        XCTAssertTrue(Model.compatible(.groq, "unlisted").capabilities.supportsTools)
        XCTAssertEqual(Model.chatModels(for: .groq).count, 2)
        XCTAssertTrue(Model.chatModels(for: .mistral).isEmpty)
    }

    func testMissingProviderMessageForCompatibleModel() {
        let lines = MessageService().missingProviderMessageLines(for: .compatible(.groq, "llama-3.3-70b-versatile")).joined(separator: "\n")

        XCTAssertTrue(lines.contains("'groq/llama-3.3-70b-versatile'"))
        XCTAssertTrue(lines.contains("GROQ_API_KEY"))
        XCTAssertTrue(lines.contains("Groq"))
    }

    func testCompatibleRequestIsTaggedForItsProvider() {
        let request = NetworkClient.shared.request(
            messages: [Message(text: "hi", role: .user)],
            model: .compatible(.mistral, "mistral-large-latest"),
            stream: true,
            tools: nil,
            toolChoice: nil
        )

        guard let chatRequest = request as? OpenAI.ChatCompletionRequest else {
            return XCTFail("Expected OpenAI.ChatCompletionRequest for compatible providers")
        }
        XCTAssertEqual(chatRequest.model.id, "mistral-large-latest")
        XCTAssertTrue(chatRequest.model.belongs(to: CompatibleProvider.mistral.providerID))
        XCTAssertFalse(OpenAI.requestValidators.contains { $0(chatRequest) })
    }

    func testResponsesOnlyProviderGetsATaggedResponsesRequest() {
        let request = NetworkClient.shared.request(
            messages: [Message(text: "hi", role: .user)],
            model: .compatible(.perplexity, "medium"),
            stream: true,
            tools: nil,
            toolChoice: nil
        )

        guard let responsesRequest = request as? OpenAI.ResponsesRequest else {
            return XCTFail("Expected OpenAI.ResponsesRequest for Perplexity")
        }
        XCTAssertEqual(responsesRequest.model.id, "medium")
        XCTAssertTrue(responsesRequest.model.belongs(to: CompatibleProvider.perplexity.providerID))
        XCTAssertFalse(OpenAI.requestValidators.contains { $0(responsesRequest) })
        XCTAssertFalse(CompatibleProvider.perplexity.servesChatCompletions)
        XCTAssertTrue(CompatibleProvider.cohere.servesChatCompletions)
    }

    func testGeminiAndCohereUseTheirNativeAPIs() {
        let gemini = NetworkClient.shared.request(messages: [Message(text: "hi", role: .user)], model: .gemini(.gemini3Flash), stream: true, tools: nil, toolChoice: nil)
        let cohere = NetworkClient.shared.request(messages: [Message(text: "hi", role: .user)], model: .compatible(.cohere, "command-a-03-2025"), stream: true, tools: nil, toolChoice: .required)

        XCTAssertTrue(gemini is Gemini.GenerateContentRequest)
        XCTAssertEqual((cohere as? Cohere.ChatRequest)?.tool_choice, .required)
    }

    // MARK: - Keys

    func testEnvironmentAPIKeysIncludeOpenRouterAndCompatibleProviders() {
        let keys = CLI.apiKeysFromEnvironment([
            "OPENROUTER_API_KEY": " openrouter-key ",
            "GROQ_API_KEY": " groq-key ",
            "AI_GATEWAY_API_KEY": "vercel-key",
            "COHERE_API_KEY": "",
            "OPENAI_API_KEY": "openai-key",
        ])

        XCTAssertEqual(keys[.openrouter], "openrouter-key")
        XCTAssertEqual(keys[.groq], "groq-key")
        XCTAssertEqual(keys[.vercel], "vercel-key")
        XCTAssertNil(keys[.cohere])
        XCTAssertEqual(keys[.openAI], "openai-key")
    }
}
