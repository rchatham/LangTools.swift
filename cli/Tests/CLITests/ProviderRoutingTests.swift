//
//  ProviderRoutingTests.swift
//  CLITests
//
//  Model parsing, routing, and key discovery for OpenRouter and the
//  OpenAI-compatible providers.
//

import XCTest
import Ollama
import OpenAI
import OpenRouter
@testable import CLI

final class ProviderRoutingTests: XCTestCase {

    // MARK: - OpenRouter

    func testModelFromArgumentAcceptsOpenRouterSlugs() {
        XCTAssertEqual(CLI.model(fromArgument: "openrouter/anthropic/claude-sonnet-4.5"), .openRouter("anthropic/claude-sonnet-4.5"))
        XCTAssertEqual(CLI.model(fromArgument: "openrouter/openai/gpt-5:free"), .openRouter("openai/gpt-5:free"))
        XCTAssertEqual(CLI.model(fromArgument: "openrouter/auto"), .openRouter(.auto), "a bare remainder is OpenRouter's own router slug")
        XCTAssertNil(CLI.model(fromArgument: "openrouter/ anthropic/claude-sonnet-4.5"), "padded slugs are rejected")
    }

    func testOpenRouterModelRawValueRoundTripsAheadOfOllamaFallback() {
        for model in [Model.openRouter("anthropic/claude-sonnet-4.5"), .openRouter(.auto), .openRouter("meta-llama/llama-3.2-3b-instruct:free")] {
            XCTAssertTrue(model.rawValue.hasPrefix("openrouter/"))
            XCTAssertEqual(Model(rawValue: model.rawValue), model, "\(model.rawValue) must not fall through to the Ollama case")
        }
        XCTAssertEqual(Model.openRouter(.auto).rawValue, "openrouter/openrouter/auto")
        XCTAssertNil(Model(rawValue: "openrouter/"))
        XCTAssertEqual(Model.openRouter("x/y").provider, .openRouter)
    }

    func testOpenRouterCapabilitiesFollowTheCatalog() {
        let previous = Model.openRouterCatalog
        defer { Model.openRouterCatalog = previous }
        Model.openRouterCatalog = [
            .init(id: "with/tools", supportedParameters: ["tools", "structured_outputs"]),
            .init(id: "without/tools", supportedParameters: ["temperature"]),
        ]

        XCTAssertEqual(Model.openRouter("with/tools").capabilities.toolReliability, .recommended)
        XCTAssertTrue(Model.openRouter("with/tools").capabilities.supportsStructuredOutput)
        XCTAssertEqual(Model.openRouter("without/tools").capabilities.toolReliability, .unavailable)
        XCTAssertFalse(Model.openRouter("without/tools").capabilities.supportsTools)
        XCTAssertTrue(Model.openRouter("unlisted/model").capabilities.supportsTools, "models missing from the catalog are assumed to support tools")
        XCTAssertEqual(Model.chatModels(for: .openRouter).count, 2)
    }

    func testMissingProviderMessageForOpenRouterModel() {
        let lines = MessageService().missingProviderMessageLines(for: .openRouter("anthropic/claude-sonnet-4.5")).joined(separator: "\n")

        XCTAssertTrue(lines.contains("'openrouter/anthropic/claude-sonnet-4.5'"))
        XCTAssertTrue(lines.contains("OPENROUTER_API_KEY"))
    }

    func testOpenRouterRequestIsTaggedForOpenRouter() {
        let request = NetworkClient.shared.request(
            messages: [Message(text: "hi", role: .user)],
            model: .openRouter("openai/gpt-4o"),
            stream: true,
            tools: nil,
            toolChoice: nil
        )

        guard let chatRequest = request as? OpenAI.ChatCompletionRequest else {
            return XCTFail("Expected OpenAI.ChatCompletionRequest for OpenRouter models")
        }
        XCTAssertEqual(chatRequest.model.id, "openai/gpt-4o")
        XCTAssertTrue(chatRequest.model.belongs(to: OpenRouter.providerID))
        XCTAssertTrue(OpenRouter.requestValidators.contains { $0(chatRequest) })
        XCTAssertFalse(OpenAI.requestValidators.contains { $0(chatRequest) })
    }

    // MARK: - OpenAI-compatible providers

    func testModelFromArgumentAcceptsCompatibleProviderPrefixes() {
        XCTAssertEqual(CLI.model(fromArgument: "groq/llama-3.3-70b-versatile"), .compatible(.groq, "llama-3.3-70b-versatile"))
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
        Model.compatibleCatalogs = [.groq: [.init(id: "with-tools", supportsTools: true), .init(id: "without-tools", supportsTools: false)]]

        XCTAssertEqual(Model.compatible(.groq, "with-tools").capabilities.toolReliability, .recommended)
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

    // MARK: - Keys

    func testEnvironmentAPIKeysIncludeOpenRouterAndCompatibleProviders() {
        let keys = CLI.apiKeysFromEnvironment([
            "OPENROUTER_API_KEY": " openrouter-key ",
            "GROQ_API_KEY": " groq-key ",
            "AI_GATEWAY_API_KEY": "vercel-key",
            "COHERE_API_KEY": "",
            "OPENAI_API_KEY": "openai-key",
        ])

        XCTAssertEqual(keys[.openRouter], "openrouter-key")
        XCTAssertEqual(keys[.groq], "groq-key")
        XCTAssertEqual(keys[.vercel], "vercel-key")
        XCTAssertNil(keys[.cohere])
        XCTAssertEqual(keys[.openAI], "openai-key")
    }
}
