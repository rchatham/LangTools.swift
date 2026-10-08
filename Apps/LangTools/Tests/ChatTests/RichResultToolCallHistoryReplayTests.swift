import Agents
import Anthropic
import ChatUI
import Foundation
import LangTools
import Ollama
import OpenAI
import SwiftUI
import XCTest
@testable import Chat

private struct ReplayCard: StructuredOutput {
    let title: String
    static var jsonSchema: JSONSchema {
        .object(properties: ["title": .string(description: "Title")], required: ["title"])
    }
}

private struct ReplayWrapper: Decodable {
    let summary: String
    let items: [ReplayCard]
}

final class RichResultToolCallHistoryReplayTests: XCTestCase {
    private let raw = #"{"summary":"Visible calendar summary","items":[{"title":"Legitimate decoded event"}],"raw_only_wrapper":"RAW_ONLY_SENTINEL"}"#
    private let targets: [APIService] = [.openAI, .anthropic, .ollama]

    private func richMessage(origin: APIService?) -> Message {
        let display = ChatToolCall.DisplayContent(
            type: "calendar-fixture", json: #"[{"title":"Legitimate decoded event"}]"#,
            summary: "Visible calendar summary", itemCount: 1
        )
        let call = ChatToolCall(
            id: "rich-call-1", name: "calendar_fixture", kind: .agent,
            arguments: #"{"query":"today"}"#, status: .success, result: raw,
            details: "Completed calendar lookup", displayContent: display
        )
        let message = Message(
            role: .assistant, toolCalls: [call], providerToolResults: [call.id: raw],
            providerToolResultServices: origin.map { [call.id: $0] } ?? [:],
            responseToMessageID: UUID()
        )
        message.wasResponseStopped = true
        return message
    }

    /// Encodes the final provider request, not merely the intermediate Message
    /// dictionaries. These requests are never sent to a provider.
    private func encodedRequest(_ messages: [Message], target: APIService) throws -> String {
        let data: Data
        switch target {
        case .openAI:
            let request = try OpenAI.chatRequest(
                model: OpenAI.Model.gpt4o, messages: messages.toOpenAIMessages(),
                tools: nil, responseSchema: nil, toolEventHandler: { _ in }
            )
            data = try JSONEncoder().encode(XCTUnwrap(request as? OpenAI.ChatCompletionRequest))
        case .anthropic:
            let request = try Anthropic.chatRequest(
                model: Anthropic.Model.claude46Sonnet, messages: messages.toAnthropicMessages(),
                tools: nil, responseSchema: nil, toolEventHandler: { _ in }
            )
            data = try JSONEncoder().encode(XCTUnwrap(request as? Anthropic.MessageRequest))
        case .ollama:
            let request = try Ollama.chatRequest(
                model: XCTUnwrap(OllamaModel(rawValue: "llama3.2")), messages: messages.toOllamaMessages(),
                tools: nil, responseSchema: nil, toolEventHandler: { _ in }
            )
            data = try JSONEncoder().encode(XCTUnwrap(request as? Ollama.ChatRequest))
        default:
            throw XCTSkip("Fixture only supports OpenAI, Anthropic and Ollama")
        }
        return String(decoding: data, as: UTF8.self)
    }

    func testEncodedRequestsWithholdForeignRawFallbackWithoutMutatingLocalPayload() throws {
        for target in targets {
            let origin: APIService = target == .ollama ? .openAI : .ollama
            let original = richMessage(origin: origin)
            let originalData = try JSONEncoder().encode(original)
            // Exercise the persisted rich representation, including duplicated raw result.
            let reloaded = try JSONDecoder().decode(Message.self, from: originalData)
            let filtered = reloaded.replayFiltered(targetService: target, allowCrossProvider: false)
            XCTAssertFalse(filtered === reloaded)
            XCTAssertNil(filtered.providerToolResults["rich-call-1"])
            XCTAssertNil(filtered.providerToolResultServices["rich-call-1"])
            XCTAssertNil(filtered.toolCalls[0].result)
            var expectedCall = reloaded.toolCalls[0]
            expectedCall.result = nil
            XCTAssertEqual(filtered.toolCalls[0], expectedCall, "Keep identity, inputs, status, details and typed display")
            XCTAssertEqual(filtered.uuid, reloaded.uuid)
            XCTAssertEqual(filtered.contentType, reloaded.contentType)
            XCTAssertEqual(filtered.responseToMessageID, reloaded.responseToMessageID)
            XCTAssertEqual(filtered.wasResponseStopped, reloaded.wasResponseStopped)
            XCTAssertEqual(reloaded.toolCalls[0].result, raw, "Local raw disclosure must remain intact")
            XCTAssertEqual(reloaded.providerToolResults["rich-call-1"], raw)
            XCTAssertEqual(reloaded.toolCalls[0].displayContent, original.toolCalls[0].displayContent)

            let body = try encodedRequest([filtered], target: target)
            XCTAssertFalse(body.contains("RAW_ONLY_SENTINEL"), "\(target) final body must exclude the raw-only field")
            XCTAssertFalse(body.contains("raw_only_wrapper"))
            XCTAssertTrue(body.contains("calendar_fixture"), "Retain the invocation")
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
            let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
            XCTAssertEqual(messages.count, 2, "Withholding raw content must retain both invocation and result messages")
            switch target {
            case .openAI:
                let calls = try XCTUnwrap(messages[0]["tool_calls"] as? [[String: Any]])
                XCTAssertEqual(calls.first?["id"] as? String, "rich-call-1")
                XCTAssertEqual(messages[1]["tool_call_id"] as? String, "rich-call-1")
                XCTAssertEqual(messages[1]["content"] as? String, "")
            case .anthropic:
                let uses = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
                let results = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
                XCTAssertEqual(uses.first?["id"] as? String, "rich-call-1")
                XCTAssertEqual(results.first?["tool_use_id"] as? String, "rich-call-1")
            case .ollama:
                XCTAssertEqual(messages[1]["role"] as? String, "tool")
                XCTAssertEqual(messages[1]["content"] as? String, "")
            default: XCTFail("Unexpected fixture provider")
            }
        }
    }

    func testEncodedRequestsRetainRawForSameOriginSharingOnAndLegacyOrigins() throws {
        for target in targets {
            let foreign: APIService = target == .ollama ? .openAI : .ollama
            for (origin, sharing) in [(Optional(target), false), (Optional(foreign), true), (nil, false)] {
                let original = richMessage(origin: origin)
                let filtered = original.replayFiltered(targetService: target, allowCrossProvider: sharing)
                XCTAssertTrue(filtered === original)
                let body = try encodedRequest([filtered], target: target)
                XCTAssertTrue(body.contains("RAW_ONLY_SENTINEL"), "\(target) must preserve permitted/legacy raw results")
                XCTAssertTrue(body.contains("raw_only_wrapper"))
                XCTAssertEqual(original.toolCalls[0].result, raw)
            }
        }
    }

    func testMixedOriginsClearOnlyMatchingRawFallbackIncludingNestedCalls() {
        let original = richMessage(origin: .ollama)
        let kept = ChatToolCall(id: "local", name: "local_tool", status: .success, result: "local-result")
        let nested = ChatToolCall(id: "nested-foreign", name: "nested_tool", status: .success, result: raw)
        let legacy = ChatToolCall(id: "legacy", name: "legacy_tool", status: .success, result: raw)
        original.toolCalls[0].children = [nested]
        original.toolCalls += [kept, legacy]
        original.providerToolResults[kept.id] = "local-result"
        original.providerToolResultServices[kept.id] = .openAI
        original.providerToolResults[nested.id] = raw
        original.providerToolResultServices[nested.id] = .ollama
        original.providerToolResults[legacy.id] = raw

        let filtered = original.replayFiltered(targetService: .openAI, allowCrossProvider: false)
        XCTAssertNil(filtered.toolCalls[0].result)
        XCTAssertNil(filtered.toolCalls[0].children[0].result)
        XCTAssertEqual(filtered.toolCalls[1], kept)
        XCTAssertEqual(filtered.toolCalls[2], legacy)
        XCTAssertEqual(filtered.providerToolResults, [kept.id: "local-result", legacy.id: raw])
        XCTAssertEqual(original.toolCalls[0].children[0], nested)
    }

    @MainActor
    private func registerReplayTool() -> String {
        let name = "calendar_fixture_" + UUID().uuidString
        ContentCardRegistry.shared.register(tool: name, cardType: UUID().uuidString, as: ReplayCard.self,
                          decode: { json in
                              guard let wrapper = try? JSONDecoder().decode(ReplayWrapper.self, from: Data(json.utf8)) else { return nil }
                              return (message: wrapper.summary, items: wrapper.items)
                          }, render: { items in ForEach(items.indices, id: \.self) { Text(items[$0].title) } })
        return name
    }

    @MainActor
    func testHistoryOnTerminalResultsKeepLocalRawButFilterFinalRequests() async throws {
        let previous = ToolSettings.shared.keepsToolCallsInHistory
        ToolSettings.shared.keepsToolCallsInHistory = true
        defer { ToolSettings.shared.keepsToolCallsInHistory = previous }

        let client = ReplayTerminalNetworkStub(name: registerReplayTool(), raw: raw)
        let service = MessageService(networkClient: client)
        service.resultContentParser = ContentCardRegistry.shared.resultContentParser
        try await service.send(message: "Look up the calendar")
        let original = try XCTUnwrap(service.messages.first { !$0.toolCalls.isEmpty })
        let call = try XCTUnwrap(original.toolCalls.first)
        XCTAssertEqual(call.status, .success)
        XCTAssertEqual(call.result, raw)
        XCTAssertNotNil(call.displayContent)
        XCTAssertEqual(original.providerToolResults[call.id], raw)
        let origin = try XCTUnwrap(original.providerToolResultServices[call.id])
        let reloaded = try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(original))
        for target in targets {
            for sharing in [false, true] {
                let filtered = reloaded.replayFiltered(targetService: target, allowCrossProvider: sharing)
                let body = try encodedRequest([filtered], target: target)
                XCTAssertEqual(body.contains("RAW_ONLY_SENTINEL"), sharing || target == origin)
                XCTAssertEqual(body.contains("raw_only_wrapper"), sharing || target == origin)
                XCTAssertEqual(original.toolCalls[0], call, "Outbound filtering must not alter local disclosure/display")
            }
        }
    }

    @MainActor
    func testHistoryOffTerminalSanitizationReplaysDecodedCardsNotRawWrapper() async throws {
        let previous = ToolSettings.shared.keepsToolCallsInHistory
        ToolSettings.shared.keepsToolCallsInHistory = false
        defer { ToolSettings.shared.keepsToolCallsInHistory = previous }

        let client = ReplayTerminalNetworkStub(name: registerReplayTool(), raw: raw)
        let service = MessageService(networkClient: client)
        service.resultContentParser = ContentCardRegistry.shared.resultContentParser
        try await service.send(message: "Look up the calendar")

        let cards = service.messages.filter { if case .contentCards = $0.contentType { return true }; return false }
        XCTAssertEqual(cards.count, 1, "History-off must preserve exactly one legitimate decoded card")
        XCTAssertTrue(service.messages.allSatisfy { $0.toolCalls.isEmpty && $0.providerToolResults.isEmpty && $0.providerToolResultServices.isEmpty }, "Terminal cleanup removes the raw history representation")
        try await service.send(message: "Use the visible event as context")
        let nextRequest = try XCTUnwrap(client.requests.last)
        for target in targets {
            let messages = nextRequest.replayFiltered(targetService: target, allowCrossProvider: false)
            let body = try encodedRequest(messages, target: target)
            XCTAssertTrue(body.contains("Visible calendar summary"))
            XCTAssertTrue(body.contains("Legitimate decoded event"), "Visible card details intentionally remain provider context")
            XCTAssertFalse(body.contains("RAW_ONLY_SENTINEL"))
            XCTAssertFalse(body.contains("raw_only_wrapper"))
        }
    }
}

private struct ReplaySelection: LangToolsToolSelection {
    let id: String?
    let name: String?
    let arguments: String

    init(name: String) {
        id = "provider-call-1"
        self.name = name
        arguments = "{}"
    }
}

private struct ReplayResult: LangToolsToolSelectionResult {
    let tool_selection_id: String
    let result: String
    let is_error: Bool

    init(tool_selection_id: String, result: String, is_error: Bool = false) {
        self.tool_selection_id = tool_selection_id
        self.result = result
        self.is_error = is_error
    }
}

private final class ReplayTerminalNetworkStub: NetworkClientProtocol {
    static let shared: NetworkClientProtocol = ReplayTerminalNetworkStub(name: "fixture", raw: "{}")
    let name: String
    let raw: String
    var requests: [[Message]] = []

    init(name: String, raw: String) { self.name = name; self.raw = raw }

    func performChatCompletionRequest(messages: [Message], model: Model, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) async throws -> Message {
        throw NetworkClient.NetworkError.incompatibleRequest
    }

    func streamChatCompletionRequest(messages: [Message], model: Model, stream: Bool, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> AsyncThrowingStream<String, Error> {
        requests.append(messages)
        if requests.count == 1 {
            toolEventHandler(.toolCalled(ReplaySelection(name: name)))
            toolEventHandler(.toolCompleted(ReplayResult(tool_selection_id: "provider-call-1", result: raw)))
        }
        return AsyncThrowingStream { continuation in
            continuation.yield("Done.")
            continuation.finish()
        }
    }

    func playAudio(for text: String) async throws {}
    func agentContext(messages: [Message], model: Model, eventHandler: @escaping (AgentEvent) -> Void) throws -> AgentContext { throw NetworkClient.NetworkError.incompatibleRequest }
    func updateApiKey(_ apiKey: String, for llm: APIService) throws {}
    func removeApiKey(for llm: APIService) throws {}
    func connectAccount(_ provider: AccountLoginProvider) async throws {}
    func disconnectAccount(_ provider: AccountLoginProvider) async throws {}
}
