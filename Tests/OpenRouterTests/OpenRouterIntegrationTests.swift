//
//  OpenRouterIntegrationTests.swift
//  OpenRouterTests
//
//  Live, billed requests against OpenRouter. Skipped unless
//  LANGTOOLS_RUN_OPENROUTER_TESTS=1 and OPENROUTER_API_KEY are set.
//

import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LangTools
import OpenAI
@testable import OpenRouter

final class OpenRouterIntegrationTests: XCTestCase {
    private static let defaultModel = "openai/gpt-4o-mini"

    private func liveClient() throws -> (OpenRouter, URLSession) {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LANGTOOLS_RUN_OPENROUTER_TESTS"] == "1" else {
            throw XCTSkip("Set LANGTOOLS_RUN_OPENROUTER_TESTS=1 to run the live OpenRouter smoke test")
        }
        guard let apiKey = environment["OPENROUTER_API_KEY"], !apiKey.isEmpty else {
            // Enabled without a key is a misconfiguration, not a skip.
            throw LangToolsError.invalidArgument("OPENROUTER_API_KEY is required when live OpenRouter tests are enabled")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 120
        let session = URLSession(configuration: configuration)
        return (OpenRouter(apiKey: apiKey, appTitle: "LangTools.swift CI", session: session), session)
    }

    func testLiveChat() async throws {
        let (openRouter, session) = try liveClient()
        defer { session.invalidateAndCancel() }
        let model = try XCTUnwrap(testModel(from: ProcessInfo.processInfo.environment), "OPENROUTER_TEST_MODEL must not be empty")

        let response = try await openRouter.perform(request: OpenAI.ChatCompletionRequest(
            model: model, messages: [.init(role: .user, content: "Reply with exactly: pong")], max_tokens: 16))

        let text = response.choices.first?.message?.content.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        XCTAssertFalse(text.isEmpty)
    }

    func testLiveModelCatalog() async throws {
        let (openRouter, session) = try liveClient()
        defer { session.invalidateAndCancel() }

        let models = try await openRouter.listModels()

        XCTAssertFalse(models.isEmpty)
        XCTAssertTrue(models.contains { $0.supportsTools == true })
    }

    func testModelOverrideIsTrimmedAndEmptyIsRejected() {
        XCTAssertEqual(testModel(from: [:])?.rawValue, Self.defaultModel)
        XCTAssertEqual(testModel(from: ["OPENROUTER_TEST_MODEL": " anthropic/claude-haiku-4.5 "])?.rawValue, "anthropic/claude-haiku-4.5")
        XCTAssertNil(testModel(from: ["OPENROUTER_TEST_MODEL": " \n\t "]))
    }

    private func testModel(from environment: [String: String]) -> OpenRouterModel? {
        OpenRouterModel(rawValue: (environment["OPENROUTER_TEST_MODEL"] ?? Self.defaultModel).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
