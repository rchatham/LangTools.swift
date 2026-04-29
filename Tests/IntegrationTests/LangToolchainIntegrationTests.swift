//
//  LangToolchainIntegrationTests.swift
//  LangTools
//
//  Integration tests for the LangToolchain: provider routing,
//  cross-provider usage, and multi-provider orchestration.
//

import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LangTools
@testable import OpenAI
@testable import Anthropic
@testable import TestUtils
import PerformanceTestUtils

final class LangToolchainIntegrationTests: XCTestCase {

    var openai: OpenAI!
    var anthropic: Anthropic!
    var toolchain: LangToolchain!

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        openai = OpenAI(apiKey: "openai-key").configure(testURLSessionConfiguration: config)
        anthropic = Anthropic(apiKey: "anthropic-key").configure(testURLSessionConfiguration: config)
        toolchain = LangToolchain()
        toolchain.register(openai)
        toolchain.register(anthropic)
    }

    override func tearDown() {
        MockURLProtocol.mockNetworkHandlers.removeAll()
        URLProtocol.unregisterClass(MockURLProtocol.self)
        super.tearDown()
    }

    // MARK: - Provider Routing

    func testRoutesOpenAIRequestToOpenAI() async throws {
        MockURLProtocol.mockNetworkHandlers[OpenAI.ChatCompletionRequest.endpoint] = { _ in
            let data = PerformanceFixtures.openAIChatCompletionResponseJSON(choiceCount: 1)
            return (.success(data), 200)
        }
        let request = OpenAI.ChatCompletionRequest(
            model: .gpt4o,
            messages: [.init(role: .user, content: "Hello")]
        )
        let response = try await toolchain.perform(request: request)
        XCTAssertEqual(response.id, "chatcmpl-perf-test-1")
    }

    func testRoutesAnthropicRequestToAnthropic() async throws {
        MockURLProtocol.mockNetworkHandlers[Anthropic.MessageRequest.endpoint] = { _ in
            let data = PerformanceFixtures.anthropicMessageResponseJSON()
            return (.success(data), 200)
        }
        let request = Anthropic.MessageRequest(
            model: .claude46Sonnet,
            messages: [.init(role: .user, content: "Hello")]
        )
        let response = try await toolchain.perform(request: request)
        XCTAssertEqual(response.messageInfo?.id, "msg_perf_test_001")
    }

    // MARK: - Provider Lookup

    func testLookupOpenAIProvider() {
        let provider = toolchain.langTool(OpenAI.self)
        XCTAssertNotNil(provider)
    }

    func testLookupAnthropicProvider() {
        let provider = toolchain.langTool(Anthropic.self)
        XCTAssertNotNil(provider)
    }

    func testLookupUnregisteredProviderReturnsNil() {
        let emptyToolchain = LangToolchain()
        let provider = emptyToolchain.langTool(OpenAI.self)
        XCTAssertNil(provider)
    }

    // MARK: - Streaming Through Toolchain

    func testStreamOpenAIThroughToolchain() async throws {
        let streamData = PerformanceFixtures.openAIStreamChunksData(chunkCount: 5)
        MockURLProtocol.mockNetworkHandlers[OpenAI.ChatCompletionRequest.endpoint] = { _ in
            (.success(streamData), 200)
        }
        let request = OpenAI.ChatCompletionRequest(
            model: .gpt4o,
            messages: [.init(role: .user, content: "Hello")],
            stream: true
        )
        var count = 0
        let stream: AsyncThrowingStream<OpenAI.ChatCompletionResponse, Error> = toolchain.stream(request: request)
        for try await _ in stream {
            count += 1
        }
        XCTAssertGreaterThan(count, 0)
    }

    func testStreamAnthropicThroughToolchain() async throws {
        let streamData = PerformanceFixtures.anthropicStreamData(chunkCount: 5)
        MockURLProtocol.mockNetworkHandlers[Anthropic.MessageRequest.endpoint] = { _ in
            (.success(streamData), 200)
        }
        let request = Anthropic.MessageRequest(
            model: .claude46Sonnet,
            messages: [.init(role: .user, content: "Hello")],
            stream: true
        )
        var count = 0
        let stream: AsyncThrowingStream<Anthropic.MessageResponse, Error> = toolchain.stream(request: request)
        for try await _ in stream {
            count += 1
        }
        XCTAssertGreaterThan(count, 0)
    }

    // MARK: - Error Handling

    func testUnhandledRequestThrowsError() async throws {
        let emptyToolchain = LangToolchain()
        let request = OpenAI.ChatCompletionRequest(
            model: .gpt4o,
            messages: [.init(role: .user, content: "Hello")]
        )
        do {
            _ = try await emptyToolchain.perform(request: request)
            XCTFail("Should have thrown toolchainCannotHandleRequest")
        } catch {
            XCTAssertTrue(error is LangToolchainError)
        }
    }

    // MARK: - Cross-Provider Message Conversion

    func testOpenAIToAnthropicMessageConversion() {
        let openaiMessage = OpenAI.Message(role: .user, content: "Hello from OpenAI")
        let anthropicMessage = Anthropic.Message(openaiMessage)
        XCTAssertTrue(anthropicMessage.role.isUser)
    }

    func testAnthropicToOpenAIMessageConversion() {
        let anthropicMessage = Anthropic.Message(role: .user, content: "Hello from Anthropic")
        let openaiMessage = OpenAI.Message(anthropicMessage)
        XCTAssertTrue(openaiMessage.role.isUser)
    }

    // MARK: - Sequential Multi-Provider Flow

    func testSequentialMultiProviderFlow() async throws {
        // First, call OpenAI
        MockURLProtocol.mockNetworkHandlers[OpenAI.ChatCompletionRequest.endpoint] = { _ in
            let data = PerformanceFixtures.openAIChatCompletionResponseJSON(choiceCount: 1)
            return (.success(data), 200)
        }
        let openaiRequest = OpenAI.ChatCompletionRequest(
            model: .gpt4o,
            messages: [.init(role: .user, content: "Summarize this")]
        )
        let openaiResponse = try await toolchain.perform(request: openaiRequest)
        let openaiContent = openaiResponse.choices.first?.message?.content.string ?? ""

        // Then, call Anthropic with the OpenAI response
        MockURLProtocol.mockNetworkHandlers[Anthropic.MessageRequest.endpoint] = { _ in
            let data = PerformanceFixtures.anthropicMessageResponseJSON()
            return (.success(data), 200)
        }
        let anthropicRequest = Anthropic.MessageRequest(
            model: .claude46Sonnet,
            messages: [.init(role: .user, content: "Evaluate: \(openaiContent)")]
        )
        let anthropicResponse = try await toolchain.perform(request: anthropicRequest)
        XCTAssertNotNil(anthropicResponse.message)
    }

    // MARK: - Request Validators

    func testOpenAIValidatorAcceptsOpenAIRequest() {
        let request = OpenAI.ChatCompletionRequest(
            model: .gpt4o,
            messages: [.init(role: .user, content: "Hi")]
        )
        let canHandle = OpenAI.requestValidators.contains(where: { $0(request) })
        XCTAssertTrue(canHandle)
    }

    func testAnthropicValidatorAcceptsAnthropicRequest() {
        let request = Anthropic.MessageRequest(
            model: .claude46Sonnet,
            messages: [.init(role: .user, content: "Hi")]
        )
        let canHandle = Anthropic.requestValidators.contains(where: { $0(request) })
        XCTAssertTrue(canHandle)
    }

    func testOpenAIValidatorRejectsAnthropicRequest() {
        let request = Anthropic.MessageRequest(
            model: .claude46Sonnet,
            messages: [.init(role: .user, content: "Hi")]
        )
        let canHandle = OpenAI.requestValidators.contains(where: { $0(request) })
        XCTAssertFalse(canHandle)
    }

    func testAnthropicValidatorRejectsOpenAIRequest() {
        let request = OpenAI.ChatCompletionRequest(
            model: .gpt4o,
            messages: [.init(role: .user, content: "Hi")]
        )
        let canHandle = Anthropic.requestValidators.contains(where: { $0(request) })
        XCTAssertFalse(canHandle)
    }
}
