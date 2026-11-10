import Anthropic
import Foundation
import Gemini
import LangTools
import OpenAI
import XCTest
@testable import Chat

/// Recognizing a provider's "request too long" error, from the bodies
/// providers actually send.
final class ContextOverflowTests: XCTestCase {
    private func decoded<Body: Decodable>(_ type: Body.Type, _ json: String) throws -> Body {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    func testOpenAIReportsTheMessagesAgainstTheWindow() throws {
        let body = try decoded(OpenAIErrorResponse.self, """
        {"error": {"message": "This model's maximum context length is 128000 tokens. However, your messages resulted in 130512 tokens. Please reduce the length of the messages.", "type": "invalid_request_error", "param": "messages", "code": "context_length_exceeded"}}
        """)
        let error = LangToolsError.responseUnsuccessful(statusCode: 400, body)

        XCTAssertEqual(ContextOverflow(error: error), ContextOverflow(requestedTokens: 130_512, maximumTokens: 128_000))
    }

    func testOpenAIsOlderWordingCountsOnlyTheMessages() throws {
        let body = try decoded(OpenAIErrorResponse.self, """
        {"error": {"message": "This model's maximum context length is 8192 tokens. However, you requested 8500 tokens (7500 in the messages, 1000 in the completion). Please reduce the length of the messages or completion.", "type": "invalid_request_error", "param": "messages", "code": "context_length_exceeded"}}
        """)

        XCTAssertEqual(
            ContextOverflow(error: LangToolsError.apiError(body)),
            ContextOverflow(requestedTokens: 7_500, maximumTokens: 8_192),
            "The completion's share is the reply reserve, not history"
        )
    }

    func testAnOverflowWithoutNumbersIsRecognizedByItsCode() throws {
        let body = try decoded(OpenAIErrorResponse.self, """
        {"error": {"message": "Your input exceeds the context window of this model. Please adjust your input and try again.", "type": "invalid_request_error", "param": "input", "code": "context_length_exceeded"}}
        """)

        XCTAssertEqual(ContextOverflow(error: LangToolsError.apiError(body)), ContextOverflow())
    }

    func testAnthropic() throws {
        let body = try decoded(AnthropicErrorResponse.self, """
        {"type": "error", "error": {"type": "invalid_request_error", "message": "prompt is too long: 208310 tokens > 200000 maximum"}}
        """)
        let error = LangToolsError.responseUnsuccessful(statusCode: 400, body)

        XCTAssertEqual(ContextOverflow(error: error), ContextOverflow(requestedTokens: 208_310, maximumTokens: 200_000))
    }

    func testGemini() throws {
        let body = try decoded(GeminiErrorResponse.self, """
        {"error": {"code": 400, "message": "The input token count (1200000) exceeds the maximum number of tokens allowed (1048576).", "status": "INVALID_ARGUMENT"}}
        """)
        let error = LangToolsError.responseUnsuccessful(statusCode: 400, body)

        XCTAssertEqual(ContextOverflow(error: error), ContextOverflow(requestedTokens: 1_200_000, maximumTokens: 1_048_576))
    }

    func testOpenAICompatibleProviders() {
        let xAI = LangToolsError.responseUnsuccessful(
            statusCode: 400,
            ProviderMessageError(message: "This model's maximum prompt length is 131,072 but the request contains 140,123 tokens.")
        )
        XCTAssertEqual(ContextOverflow(error: xAI), ContextOverflow(requestedTokens: 140_123, maximumTokens: 131_072))

        let mistral = LangToolsError.apiError(
            ProviderMessageError(message: "Prompt contains 40000 tokens and 0 draft tokens, too large for model with 32768 maximum context length")
        )
        XCTAssertEqual(ContextOverflow(error: mistral), ContextOverflow(requestedTokens: 40_000, maximumTokens: 32_768))
    }

    func testWordingInAnErrorsDescriptionIsEnough() {
        // An account proxy passes the provider's message through as text.
        let proxied = NetworkClient.NetworkError.accountProxyTransportFailed("prompt is too long: 210000 tokens > 200000 maximum")
        XCTAssertEqual(ContextOverflow(error: proxied), ContextOverflow(requestedTokens: 210_000, maximumTokens: 200_000))
    }

    func testOtherErrorsAreNotOverflows() throws {
        let rateLimit = LangToolsError.responseUnsuccessful(
            statusCode: 429,
            ProviderMessageError(message: "Rate limit reached for gpt-4o on tokens per min (TPM): Limit 30000, Used 25000, Requested 9000.")
        )
        let payloadTooLarge = try decoded(AnthropicErrorResponse.self, """
        {"type": "error", "error": {"type": "request_too_large", "message": "Request exceeds the maximum allowed number of bytes."}}
        """)

        XCTAssertNil(ContextOverflow(error: rateLimit), "A per-minute token limit is not the context window")
        XCTAssertNil(ContextOverflow(error: LangToolsError.responseUnsuccessful(statusCode: 413, payloadTooLarge)))
        XCTAssertNil(ContextOverflow(error: LangToolsError.responseUnsuccessful(statusCode: 401, nil)))
        XCTAssertNil(ContextOverflow(error: CancellationError()))
        XCTAssertNil(ContextOverflow(error: URLError(.timedOut)))
    }
}
