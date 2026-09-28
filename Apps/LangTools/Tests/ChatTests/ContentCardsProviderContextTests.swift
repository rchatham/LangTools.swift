//
//  ContentCardsProviderContextTests.swift
//  ChatTests
//

import Dispatch
import Foundation
import OpenAI
import Anthropic
import Ollama
import ChatUI
import XCTest
@testable import Chat

/// Focused tests for the content-cards provider context (finding #8).
///
/// `Message.text` must stay the terse optional visible summary for card
/// messages, while outgoing provider payloads (OpenAI, Anthropic, Ollama, and
/// the account proxy) replay the summary plus deterministic, pretty-printed
/// sorted-key card details and metadata. Non-card provider context must exactly
/// preserve `Message.text` semantics, and tool-call replay structure
/// (counts / order / roles / tool fields) must be unchanged.
final class ContentCardsProviderContextTests: XCTestCase {

    // MARK: - Fixtures

    /// Raw card payload with deliberately unsorted keys. `JSONEncoder` writes
    /// keys in declaration order, so this mirrors what `ContentCardRegistry`
    /// actually persists.
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

    private func completedToolCall(name: String = "calculate", id: String = "call-1", result: String = "2") -> ChatToolCall {
        ChatToolCall(id: id, name: name, arguments: #"{"expression":"1+1"}"#, status: .success, result: result)
    }

    // MARK: - Deterministic formatting

    func testProviderContextRendersDeterministicStructuredFormat() {
        let context = cardsContent().providerContext

        // Summary header with type/count metadata.
        XCTAssertTrue(context.hasPrefix("Found 2 events\n\nContent cards (cardType: calendarEvent, count: 2):"))

        // Both cards are present with their identifying fields.
        XCTAssertTrue(context.contains("Team sync"))
        XCTAssertTrue(context.contains("Launch"))
        XCTAssertTrue(context.contains("2026-06-01T09:00:00Z"))
        XCTAssertTrue(context.contains("2026-06-02T01:00:00Z"))

        // Keys are sorted (endDate precedes startDate despite declaration
        // order) so provider output is stable across persistence.
        guard let endRange = context.range(of: "\"endDate\""),
              let startRange = context.range(of: "\"startDate\"") else {
            return XCTFail("expected sorted endDate/startDate keys in provider context")
        }
        XCTAssertTrue(endRange.lowerBound < startRange.lowerBound, "expected sorted card keys")

        // Rendering is deterministic: identical on every invocation.
        XCTAssertEqual(cardsContent().providerContext, cardsContent(cardsJSON: self.cardsJSON).providerContext)
    }

    func testPrettyJSONCacheEnforcesCostLimitWithLRUEviction() {
        let entryCost = "key-1".utf8.count + "value-1".utf8.count
        let cache = ContentCardsJSONCache(costLimit: entryCost * 2)
        cache.insert("value-1", forKey: "key-1")
        cache.insert("value-2", forKey: "key-2")

        XCTAssertEqual(cache.value(forKey: "key-1"), "value-1")
        cache.insert("value-3", forKey: "key-3")

        XCTAssertTrue(cache.contains("key-1"))
        XCTAssertFalse(cache.contains("key-2"))
        XCTAssertTrue(cache.contains("key-3"))
        XCTAssertEqual(
            cache.snapshot,
            .init(entryCount: 2, totalCost: entryCost * 2, costLimit: entryCost * 2)
        )

        let oversized = ContentCardsJSONCache(costLimit: entryCost - 1)
        oversized.insert("value-1", forKey: "key-1")
        XCTAssertEqual(oversized.snapshot.entryCount, 0)
        XCTAssertEqual(oversized.snapshot.totalCost, 0)
    }

    func testPrettyJSONCacheSupportsConcurrentReadsAndWritesWithinLimit() {
        let cache = ContentCardsJSONCache(costLimit: 1_024)
        DispatchQueue.concurrentPerform(iterations: 1_000) { index in
            let key = "key-\(index % 32)"
            cache.insert("value-\(index % 32)", forKey: key)
            _ = cache.value(forKey: key)
        }

        let snapshot = cache.snapshot
        XCTAssertEqual(snapshot.entryCount, 32)
        XCTAssertLessThanOrEqual(snapshot.totalCost, snapshot.costLimit)
        for index in 0..<32 {
            XCTAssertEqual(cache.value(forKey: "key-\(index)"), "value-\(index)")
        }
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

    // MARK: - Provider conversions (no tool calls)

    func testOpenAIConversionSendsProviderContext() {
        let message = cardsMessage()
        let msgs = [message].toOpenAIMessages()

        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs[0].role, .assistant)
        XCTAssertNil(msgs[0].tool_calls)
        XCTAssertEqual(msgs[0].content.string, message.providerContext)
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
        XCTAssertNil(msgs[0].tool_calls)
        XCTAssertEqual(msgs[0].content.text, message.providerContext)
    }

    // MARK: - Tool-call replay compatibility

    func testOllamaRetainedToolPayloadIncludesProviderContextWithoutChangingToolFields() {
        let cardsToolMessage = Message(role: .assistant, contentType: .contentCards(cardsContent()), toolCalls: [completedToolCall()])
        let textToolMessage = Message(role: .assistant, contentType: .string("checking"), toolCalls: [completedToolCall()])

        let cardsMsgs = [cardsToolMessage].toOllamaMessages()
        let textMsgs = [textToolMessage].toOllamaMessages()

        // Counts, order, roles, and tool fields are unchanged vs. text replay.
        XCTAssertEqual(cardsMsgs.count, textMsgs.count)
        XCTAssertEqual(cardsMsgs.count, 2)
        XCTAssertEqual(cardsMsgs[0].role, .assistant)
        XCTAssertEqual(cardsMsgs[1].role, .tool)
        XCTAssertEqual(cardsMsgs[0].tool_calls?.count, 1)
        XCTAssertEqual(cardsMsgs[0].tool_calls?[0].name, "calculate")
        XCTAssertEqual(cardsMsgs[0].tool_calls?[0].function.arguments, ["expression": "1+1"])
        XCTAssertEqual(cardsMsgs[1].content.text, "2")

        // The retained-tool assistant payload now carries full provider context…
        XCTAssertEqual(cardsMsgs[0].content.text, cardsToolMessage.providerContext)
        // …while plain-text replay semantics are untouched.
        XCTAssertEqual(textMsgs[0].content.text, "checking")
    }

    func testOpenAIToolReplayCompatibilityForContentCards() {
        let cardsToolMessage = Message(role: .assistant, contentType: .contentCards(cardsContent()), toolCalls: [completedToolCall()])
        let textToolMessage = Message(role: .assistant, contentType: .string("Let me check."), toolCalls: [completedToolCall()])

        let cardsMsgs = [cardsToolMessage].toOpenAIMessages()
        let textMsgs = [textToolMessage].toOpenAIMessages()

        // Structure identical to the existing replay: assistant tool-call
        // message followed by tool results — counts, order, roles, and tool
        // fields unchanged.
        XCTAssertEqual(cardsMsgs.count, textMsgs.count)
        XCTAssertEqual(cardsMsgs.count, 2)
        XCTAssertEqual(cardsMsgs.map(\.role), [.assistant, .tool])
        XCTAssertEqual(cardsMsgs[0].tool_calls?.count, 1)
        XCTAssertEqual(cardsMsgs[0].tool_calls?[0].id, "call-1")
        XCTAssertEqual(cardsMsgs[0].tool_calls?[0].function.name, "calculate")
        XCTAssertEqual(cardsMsgs[0].tool_calls?[0].function.arguments, #"{"expression":"1+1"}"#)
        XCTAssertEqual(cardsMsgs[0].content.string, cardsToolMessage.providerContext)
        XCTAssertNil(textMsgs[0].content.string)
        XCTAssertEqual(cardsMsgs[1].tool_call_id, "call-1")
    }

    func testAnthropicToolReplayCompatibilityForContentCards() {
        let cardsToolMessage = Message(role: .assistant, contentType: .contentCards(cardsContent()), toolCalls: [completedToolCall()])
        let textToolMessage = Message(role: .assistant, contentType: .string("checking"), toolCalls: [completedToolCall()])

        let cardsMsgs = [cardsToolMessage].toAnthropicMessages()
        let textMsgs = [textToolMessage].toAnthropicMessages()

        XCTAssertEqual(cardsMsgs.count, textMsgs.count)
        XCTAssertEqual(cardsMsgs.count, 2)
        XCTAssertEqual(cardsMsgs.map(\.role), [.assistant, .user])
        XCTAssertEqual(cardsMsgs[0].content.string, cardsToolMessage.providerContext)
        XCTAssertNil(textMsgs[0].content.string)
        XCTAssertEqual(cardsMsgs[0].tool_selection?.count, 1)
        XCTAssertEqual(cardsMsgs[0].tool_selection?[0].id, "call-1")
        XCTAssertEqual(cardsMsgs[0].tool_selection?[0].name, "calculate")
    }

    // MARK: - Malformed payload + tool-call replay

    func testMalformedCardsJSONDoesNotBreakToolCallReplay() {
        // A card message whose stored payload is not valid JSON must still
        // replay through every provider path: the labeled fallback text is
        // carried alongside retained tool calls without breaking message
        // construction.
        let malformed = cardsContent(cardsJSON: "{not valid json")
        let message = Message(
            role: .assistant,
            contentType: .contentCards(malformed),
            toolCalls: [completedToolCall()]
        )

        let openAIMessages = [message].toOpenAIMessages()
        XCTAssertEqual(openAIMessages.count, 2)
        XCTAssertEqual(openAIMessages[0].role, .assistant)
        XCTAssertEqual(openAIMessages[0].content.string, message.providerContext)
        XCTAssertTrue(openAIMessages[0].content.string?.contains("Card details unavailable") ?? false)
        XCTAssertEqual(openAIMessages[0].tool_calls?.count, 1)
        XCTAssertEqual(openAIMessages[1].role, .tool)

        let anthropicMessages = [message].toAnthropicMessages()
        XCTAssertEqual(anthropicMessages.count, 2)
        XCTAssertEqual(anthropicMessages[0].role, .assistant)
        guard let blocks = anthropicMessages[0].content.array else {
            return XCTFail("Expected assistant array content for malformed card + tool calls")
        }
        XCTAssertEqual(blocks.count, 2)
        switch blocks[0] {
        case .text(let textBlock):
            XCTAssertEqual(textBlock.text, message.providerContext ?? "")
            XCTAssertTrue(textBlock.text.contains("Card details unavailable"))
        default:
            XCTFail("Expected fallback text block first, got \(blocks[0])")
        }
        switch blocks[1] {
        case .toolUse(let toolUse):
            XCTAssertEqual(toolUse.id, "call-1")
        default:
            XCTFail("Expected trailing toolUse block, got \(blocks[1])")
        }
        XCTAssertEqual(anthropicMessages[1].role, .user)

        let ollamaMessages = [message].toOllamaMessages()
        XCTAssertEqual(ollamaMessages.count, 2)
        XCTAssertEqual(ollamaMessages[0].content.text, message.providerContext ?? "")
        XCTAssertEqual(ollamaMessages[0].tool_calls?.count, 1)
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

    // MARK: - Account proxy transport (covers NetworkClient agentContext payloads)

    func testAccountProxyTransportSendsProviderContext() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ContentCardsProxyURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        var capturedBody: Data?
        ContentCardsProxyURLProtocol.requestHandler = { request in
            capturedBody = try ContentCardsProxyURLProtocol.requestBody(request)
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"content":"ok"}"#.utf8))
        }
        defer { ContentCardsProxyURLProtocol.requestHandler = nil }
        let transport = AccountProxyTransport(
            configuration: AccountBackendConfiguration(
                codexHelperBaseURL: URL(string: "http://127.0.0.1:9999")!,
                codexHelperToken: "helper-token"
            ),
            urlSession: urlSession
        )
        let session = AccountSession(
            provider: .openAI,
            accountIdentifier: "openai-user",
            accessToken: CodexSessionMarker.value,
            accessibleModelIDs: ["gpt-5.5"]
        )
        let cardsMessage = cardsMessage()

        _ = try await transport.performChatCompletionRequest(
            messages: [Message(text: "Hello", role: .user), cardsMessage],
            model: .codex(.gpt5_5),
            session: session,
            tools: nil,
            toolChoice: nil
        )

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(capturedBody)) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        // Non-card messages keep exact text semantics through the proxy.
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        XCTAssertEqual(messages[0]["content"] as? String, "Hello")
        // Card messages send summary + deterministic details + metadata.
        XCTAssertEqual(messages[1]["role"] as? String, "assistant")
        XCTAssertEqual(messages[1]["content"] as? String, cardsMessage.providerContext)
    }
}

private final class ContentCardsProxyURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.requestHandler)
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func requestBody(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
            if count == 0 { break }
            body.append(buffer, count: count)
        }
        return body
    }
}
