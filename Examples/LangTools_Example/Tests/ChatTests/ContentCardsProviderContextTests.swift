//
//  ContentCardsProviderContextTests.swift
//  ChatTests
//

import Foundation
import OpenAI
import Anthropic
import Ollama
import XCTest
@testable import Chat

/// Focused tests for the content-cards provider context.
///
/// `Message.text` must stay the terse optional visible summary for card
/// messages, while outgoing provider payloads (OpenAI, Anthropic, and Ollama —
/// including the direct agent path, which converts history through the same
/// helpers) replay the summary plus deterministic, pretty-printed sorted-key
/// card details and metadata. Non-card provider context must exactly preserve
/// `Message.text` semantics.
final class ContentCardsProviderContextTests: XCTestCase {

    // MARK: - Fixtures

    /// Raw card payload with deliberately unsorted keys. `JSONEncoder` writes
    /// keys in declaration order, so this mirrors what the app actually
    /// persists in `ContentCardsContent.cardsJSON`.
    private let cardsJSON = #"[{"title":"Team sync","startDate":"2026-06-01T09:00:00Z","endDate":"2026-06-01T09:30:00Z","isAllDay":false,"notes":null},{"title":"Launch","startDate":"2026-06-02T00:00:00Z","endDate":"2026-06-02T01:00:00Z","isAllDay":true}]"#

    private func cardsContent(
        message: String? = "Found 2 events",
        cardsJSON: String? = nil,
        cardType: String = "calendarEvent",
        cardCount: Int = 2
    ) -> ContentCardsContent {
        ContentCardsContent(
            cardType: cardType,
            message: message,
            cardsJSON: cardsJSON ?? self.cardsJSON,
            cardCount: cardCount
        )
    }

    private func cardsMessage(content: ContentCardsContent? = nil) -> Message {
        Message.contentCards(content ?? cardsContent())
    }

    // MARK: - Deterministic formatting

    func testProviderContextRendersExactDeterministicFormat() {
        let expected = """
            Found 2 events

            Content cards (cardType: calendarEvent, count: 2):
            [
              {
                "endDate" : "2026-06-01T09:30:00Z",
                "isAllDay" : false,
                "notes" : null,
                "startDate" : "2026-06-01T09:00:00Z",
                "title" : "Team sync"
              },
              {
                "endDate" : "2026-06-02T01:00:00Z",
                "isAllDay" : true,
                "startDate" : "2026-06-02T00:00:00Z",
                "title" : "Launch"
              }
            ]
            """
        XCTAssertEqual(cardsContent().providerContext, expected)
        // Rendering is deterministic: identical on every invocation.
        XCTAssertEqual(cardsContent().providerContext, cardsContent().providerContext)
    }

    // MARK: - Terse text unchanged

    func testMessageTextStaysTerseWhileProviderContextCarriesDetails() {
        let message = cardsMessage()

        // Visible summary stays exactly the terse card message.
        XCTAssertEqual(message.text, "Found 2 events")
        XCTAssertFalse(message.text?.contains("Team sync") ?? true)

        // Provider context carries summary, metadata, and card details.
        let context = message.providerContext
        XCTAssertNotNil(context)
        XCTAssertTrue(context?.hasPrefix("Found 2 events\n\nContent cards (cardType: calendarEvent, count: 2):") ?? false)
        XCTAssertTrue(context?.contains("Team sync") ?? false)
        XCTAssertNotEqual(message.text, message.providerContext)

        // A card message without a summary keeps `text` nil, yet the provider
        // still receives the card details and metadata.
        let noSummary = cardsMessage(content: cardsContent(message: nil))
        XCTAssertNil(noSummary.text)
        XCTAssertNotNil(noSummary.providerContext)
        XCTAssertTrue(noSummary.providerContext?.hasPrefix("Content cards (cardType: calendarEvent, count: 2):") ?? false)
    }

    // MARK: - Non-card semantics

    func testNonCardProviderContextExactlyPreservesTextSemantics() {
        let nullMessage = Message(role: .assistant, contentType: .null)
        XCTAssertNil(nullMessage.providerContext)
        XCTAssertEqual(nullMessage.providerContext, nullMessage.text)

        let stringMessage = Message(text: "plain", role: .user)
        XCTAssertEqual(stringMessage.providerContext, "plain")
        XCTAssertEqual(stringMessage.providerContext, stringMessage.text)

        let arrayMessage = Message(role: .user, contentType: .array(["one", "two"]))
        XCTAssertEqual(arrayMessage.providerContext, "one\ntwo")
        XCTAssertEqual(arrayMessage.providerContext, arrayMessage.text)

        let eventMessage = Message.agentEvent(type: .toolCalled, agentName: "calendarAgent", details: "using tool: listEvents")
        XCTAssertEqual(eventMessage.providerContext, "🛠️ Agent 'calendarAgent' using tool: listEvents")
        XCTAssertEqual(eventMessage.providerContext, eventMessage.text)
    }

    // MARK: - Provider conversions (direct chat and agent history replay)

    func testOpenAIConversionSendsProviderContext() {
        let message = cardsMessage()
        let msgs = [message].toOpenAIMessages()

        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs[0].role, .assistant)
        XCTAssertEqual(msgs[0].content.string, message.providerContext)
        XCTAssertEqual(msgs[0].content.string?.contains("Team sync") ?? false, true)
    }

    func testAnthropicConversionSendsProviderContext() {
        let message = cardsMessage()
        let msgs = [message].toAnthropicMessages()

        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs[0].role, .assistant)
        XCTAssertEqual(msgs[0].content.string, message.providerContext)
    }

    func testOllamaConversionSendsProviderContext() {
        let message = cardsMessage()
        let msgs = [message].toOllamaMessages()

        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs[0].role, .assistant)
        XCTAssertEqual(msgs[0].content.text, message.providerContext)
    }

    func testAnthropicSystemMessageUsesProviderContext() {
        let systemCard = Message(role: .system, contentType: .contentCards(cardsContent()))
        let systemText = Message(text: "plain system", role: .system)

        let systemMessage = [systemCard, systemText].createAnthropicSystemMessage()

        XCTAssertNotNil(systemMessage)
        XCTAssertTrue(systemMessage?.contains("Content cards (cardType: calendarEvent, count: 2):") ?? false)
        XCTAssertTrue(systemMessage?.contains("Team sync") ?? false)
        XCTAssertTrue(systemMessage?.contains("plain system") ?? false)
    }

    // MARK: - Codable reload

    func testCodableRoundTripPreservesProviderContext() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        // Whole-second date so the deferredToDate double round trip is exact.
        let original = Message(
            role: .assistant,
            contentType: .contentCards(cardsContent()),
            createdAt: Date(timeIntervalSince1970: 1_780_000_000)
        )

        let data = try encoder.encode(original)
        let reloaded = try decoder.decode(Message.self, from: data)

        XCTAssertEqual(reloaded.contentType, original.contentType)
        XCTAssertEqual(reloaded.providerContext, original.providerContext)
        XCTAssertEqual(reloaded.text, original.text)

        // A second encode/decode cycle reloads the same provider context again,
        // proving the representation is stable across repeated persistence.
        let reloadedAgain = try decoder.decode(Message.self, from: try encoder.encode(reloaded))
        XCTAssertEqual(reloadedAgain.providerContext, original.providerContext)
    }

    // MARK: - Malformed JSON fallback

    func testMalformedCardsJSONUsesClearFallback() {
        let malformed = cardsContent(cardsJSON: "{not valid json")
        let context = malformed.providerContext

        // Clear, labeled fallback — no crash, no pretty JSON.
        XCTAssertTrue(context.contains("Found 2 events"))
        XCTAssertTrue(context.contains("Card details unavailable: the stored cards payload is not valid JSON. Raw payload:"))
        XCTAssertTrue(context.contains("{not valid json"))
        XCTAssertFalse(context.contains("Team sync"))

        // The terse visible summary is unaffected by the malformed payload.
        XCTAssertEqual(Message.contentCards(malformed).text, "Found 2 events")

        // An empty payload also falls back safely.
        let empty = cardsContent(cardsJSON: "")
        XCTAssertTrue(empty.providerContext.contains("Card details unavailable"))
    }
}