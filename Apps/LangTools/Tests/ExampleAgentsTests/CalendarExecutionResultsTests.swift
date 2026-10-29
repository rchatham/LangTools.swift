import Agents
import Foundation
@testable import LangTools
import OpenAI
import XCTest
@testable import ExampleAgents

final class CalendarExecutionResultsTests: XCTestCase {
    private func event(_ id: String = "fixture", start: String = "2030-01-01T10:00:00.000Z", title: String = "Synthetic workshop") -> CalendarEventData {
        CalendarEventData(title: title, startDate: start, endDate: "2030-01-01T11:00:00.000Z",
                          location: "Test room", notes: "Synthetic notes", isAllDay: false,
                          calendarName: "Fixture calendar", eventIdentifier: id)
    }

    private func receive(_ payload: CalendarToolResult, in results: CalendarExecutionResults,
                         agent: String = "calendarReadAgent") throws {
        results.observe(.toolCompleted(agent: agent, result: try payload.encoded()))
    }

    func testCanonicalEncodingIncludesRequiredNullKeysAndValidatesAgainstSchema() throws {
        let item = CalendarEventData(title: "Synthetic", startDate: "2030-01-01T10:00:00Z", endDate: "2030-01-01T11:00:00Z")
        let data = try JSONEncoder().encode(CalendarAgentResponse(events: [item]))
        let decoded = try CalendarAgentResponse.validated(from: data)
        XCTAssertEqual(decoded.events, [item])
        let json = try JSON(data: data)
        XCTAssertEqual(json["message"], .null)
        XCTAssertEqual(json["events"]?[0]?["location"], .null)
        XCTAssertEqual(json["events"]?[0]?["eventIdentifier"], .null)
    }

    func testNativeEventsSurviveWrongKeysFencesAndPlainText() throws {
        let native = event()
        for final in ["Here are your events.", #"{"events":[{"title":"Invented","date":"2030-01-01","time":"Afternoon"}]}"#,
                      "```json\n{\"events\":[]}\n```"] {
            let results = CalendarExecutionResults()
            try receive(CalendarToolResult(events: [native]), in: results)
            let response = try CalendarAgentResponse(jsonString: results.finalize(final))
            XCTAssertEqual(response.events, [native])
            XCTAssertEqual(response.message, "Retrieved 1 calendar event.")
        }
    }

    func testValidButInventedModelEventsCannotOverwriteNativeValues() throws {
        let results = CalendarExecutionResults()
        try receive(CalendarToolResult(events: [event()]), in: results)
        let fabricated = String(decoding: try JSONEncoder().encode(CalendarAgentResponse(events: [event("fake", title: "Invented")])), as: UTF8.self)
        XCTAssertEqual(try CalendarAgentResponse(jsonString: results.finalize(fabricated)).events, [event()])
    }

    func testEmptyQueryIsAuthoritativeAndDifferentFromNoQuery() throws {
        let results = CalendarExecutionResults()
        XCTAssertThrowsError(try results.finalize("Here are your events."))
        try receive(CalendarToolResult(events: []), in: results)
        let response = try CalendarAgentResponse(jsonString: results.finalize("Invented events"))
        XCTAssertTrue(response.events.isEmpty)
        XCTAssertEqual(response.message, "No calendar events found.")
    }

    func testNoQueryAcceptsPreviouslyValidTypedResponseButRejectsWrongFields() throws {
        let results = CalendarExecutionResults()
        let valid = String(decoding: try JSONEncoder().encode(CalendarAgentResponse(events: [event()])), as: UTF8.self)
        XCTAssertEqual(try results.finalize(valid), valid, "Preserve existing valid raw response bytes")
        XCTAssertEqual(try CalendarAgentResponse(jsonString: results.finalize(valid)).events, [event()])
        XCTAssertThrowsError(try results.finalize(#"{"events":[{"date":"2030-01-01","time":"Afternoon"}]}"#))
    }

    func testRepeatedQueriesDeduplicateOccurrencesNotRecurringSeries() throws {
        let results = CalendarExecutionResults()
        let next = event(start: "2030-01-02T10:00:00.000Z")
        try receive(CalendarToolResult(events: [event(), next]), in: results)
        try receive(CalendarToolResult(events: [event()]), in: results)
        XCTAssertEqual(try CalendarAgentResponse(jsonString: results.finalize("text")).events, [event(), next])
    }

    func testUpdateAndDeleteRemoveOnlyOriginalOccurrence() throws {
        let results = CalendarExecutionResults()
        let original = event()
        let recurring = event(start: "2030-01-02T10:00:00.000Z")
        let moved = event(start: "2030-01-01T12:00:00.000Z", title: "Moved workshop")
        try receive(CalendarToolResult(events: [original, recurring]), in: results)
        try receive(CalendarToolResult(events: [moved], replacedEvent: original), in: results, agent: "calendarWriteAgent")
        XCTAssertEqual(try CalendarAgentResponse(jsonString: results.finalize("updated")).events, [recurring, moved])
        try receive(CalendarToolResult(events: [], deletedEvent: moved), in: results, agent: "calendarWriteAgent")
        XCTAssertEqual(try CalendarAgentResponse(jsonString: results.finalize("deleted")).events, [recurring])
    }

    func testToolFailureCannotBecomeSuccessfulCardsAfterEarlierSuccess() throws {
        let results = CalendarExecutionResults()
        try receive(CalendarToolResult(events: [event()]), in: results)
        results.observe(.error(agent: "calendarWriteAgent", message: "Synthetic failure"))
        XCTAssertThrowsError(try results.finalize("Everything succeeded"))
    }

    func testMalformedNativeEnvelopeFailsAndUnrelatedAgentIsIgnored() throws {
        let results = CalendarExecutionResults()
        results.observe(.toolCompleted(agent: "weatherAgent", result: "unrelated"))
        try receive(CalendarToolResult(events: [event()]), in: results)
        XCTAssertEqual(try CalendarAgentResponse(jsonString: results.finalize("text")).events, [event()])
        results.observe(.toolCompleted(agent: "calendarReadAgent", result: "broken envelope"))
        XCTAssertThrowsError(try results.finalize("text"))
    }

    func testActualReadCallbacksEncodeAllNativeFieldsWithoutPermissions() async throws {
        let native = event()
        let queries = CalendarEventQueries(fetch: { _, _ in [native] }, upcoming: { _ in [native] }, search: { _ in [native] })
        let reader = CalendarReadAgent(queries: queries)
        let provider = CalendarFixtureProvider(finalText: "unused")
        let info = LangToolsRequestInfo(langTool: provider, model: OpenAI.Model.gpt4o, messages: [])
        for tool in try XCTUnwrap(reader.tools) {
            let args: [String: JSON] = ["start_date": .string("2030-01-01T00:00:00Z"), "end_date": .string("2030-01-02T00:00:00Z"), "query": .string("fixture")]
            let callbackResult = try await tool.callback?(info, args)
            let text = try XCTUnwrap(callbackResult)
            let payload = try JSONDecoder().decode(CalendarToolResult.self, from: Data(text.utf8))
            XCTAssertEqual(payload.events, [native], tool.name)
        }
    }

    func testExistentialExecutionUsesRealDelegateCallbacksAndFinalizesBeforeSuccess() async throws {
        for final in ["Plain summary instead of JSON", #"{"events":[{"title":"Synthetic","date":"2030-01-01","time":"Afternoon"}]}"#] {
            let native = event()
            let queries = CalendarEventQueries(fetch: { _, _ in [native] }, upcoming: { _ in [native] }, search: { _ in [native] })
            var calendar = CalendarAgent()
            calendar.delegateAgents = [CalendarReadAgent(queries: queries)]
            let agent: any Agent = calendar
            let provider = CalendarFixtureProvider(finalText: final)
            let recorded = CalendarEventRecorder()
            let context = AgentContext(langTool: provider, model: OpenAI.Model.gpt4o,
                                       messages: [OpenAI.Message(role: .user, content: "Synthetic request")],
                                       eventHandler: recorded.record)
            let result = try await agent.execute(context: context)
            XCTAssertEqual(try CalendarAgentResponse(jsonString: result).events, [native])
            let completions = recorded.events.compactMap { event -> String? in
                if case .completed("calendarAgent", let result, false) = event { return result }; return nil
            }
            XCTAssertEqual(completions, [result])
            XCTAssertEqual(provider.requestCount, 2)
        }
    }

    func testToolWrapperDispatchesCalendarFinalizer() async throws {
        let native = event()
        var calendar = CalendarAgent()
        calendar.delegateAgents = [CalendarReadAgent(queries: .init(fetch: { _, _ in [native] }, upcoming: { _ in [native] }, search: { _ in [native] }))]
        let recorder = CalendarEventRecorder()
        let tool = Tool(agent: calendar, eventHandler: recorder.record)
        let callback = try XCTUnwrap(tool.callback)
        let provider = CalendarFixtureProvider(finalText: "Plain model summary")
        let info = LangToolsRequestInfo(langTool: provider, model: OpenAI.Model.gpt4o, messages: [])
        let raw = try await callback(info, ["reason": .string("Synthetic calendar request")])
        let result = try XCTUnwrap(raw)
        XCTAssertEqual(try CalendarAgentResponse(jsonString: result).events, [native])
        XCTAssertTrue(recorder.events.contains(.completed(agent: "calendarAgent", result: result)))
    }

    func testFailureAndCancellationNeverPublishSuccessfulCalendarCompletion() async throws {
        for cancel in [false, true] {
            let native = event()
            var calendar = CalendarAgent()
            calendar.delegateAgents = [CalendarReadAgent(queries: .init(fetch: { _, _ in [native] }, upcoming: { _ in [native] }, search: { _ in [native] }))]
            let provider = CalendarFixtureProvider(finalText: "prose", failsAfterTools: !cancel, cancelsAfterTools: cancel)
            let recorder = CalendarEventRecorder()
            let context = AgentContext(langTool: provider, model: OpenAI.Model.gpt4o, messages: [], eventHandler: recorder.record)
            let task = Task { try await calendar.execute(context: context) }
            do { _ = try await task.value; XCTFail("Failure must propagate") } catch { XCTAssertTrue(error is AgentError) }
            XCTAssertFalse(recorder.events.contains { if case .completed("calendarAgent", _, false) = $0 { return true }; return false })
            XCTAssertEqual(provider.requestCount, 2, "No retry of provider/tools")
        }
    }

    func testSameAgentSequentialAndConcurrentExecutionsDoNotLeakEvents() async throws {
        let native = event()
        var calendar = CalendarAgent()
        calendar.delegateAgents = [CalendarReadAgent(queries: .init(fetch: { _, _ in [native] }, upcoming: { _ in [native] }, search: { _ in [native] }))]
        let agent: any Agent = calendar
        let makeContext: (CalendarFixtureProvider) -> AgentContext = { provider in
            AgentContext(langTool: provider, model: OpenAI.Model.gpt4o, messages: [], eventHandler: { _ in })
        }
        let first = try await agent.execute(context: makeContext(CalendarFixtureProvider(finalText: "prose")))
        XCTAssertEqual(try CalendarAgentResponse(jsonString: first).events, [native])
        do {
            _ = try await agent.execute(context: makeContext(CalendarFixtureProvider(finalText: "prose", callsTool: false)))
            XCTFail("Earlier results must not leak into a no-tool invocation")
        } catch { XCTAssertTrue(error is AgentError) }
        async let withData = agent.execute(context: makeContext(CalendarFixtureProvider(finalText: "prose")))
        async let withoutData = agent.execute(context: makeContext(CalendarFixtureProvider(finalText: #"{"events":[],"message":"No query"}"#, callsTool: false)))
        let (a, b) = try await (withData, withoutData)
        XCTAssertEqual(try CalendarAgentResponse(jsonString: a).events, [native])
        XCTAssertTrue(try CalendarAgentResponse(jsonString: b).events.isEmpty)
    }
}

/// In-process provider drives the actual Agent transfer/read-tool callbacks.
/// It deliberately ignores the final schema, like the reported Ollama responses.
final class CalendarFixtureProvider: LangTools {
    typealias Model = OpenAI.Model
    typealias ErrorResponse = OpenAI.ErrorResponse
    let finalText: String
    let callsTool: Bool
    let failsAfterTools: Bool
    let cancelsAfterTools: Bool
    private(set) var requestCount = 0
    var session: URLSession { .shared }
    static var requestValidators: [(any LangToolsRequest) -> Bool] { [{ $0 is OpenAI.ChatCompletionRequest }] }
    init(finalText: String, callsTool: Bool = true, failsAfterTools: Bool = false, cancelsAfterTools: Bool = false) {
        self.finalText = finalText; self.callsTool = callsTool
        self.failsAfterTools = failsAfterTools; self.cancelsAfterTools = cancelsAfterTools
    }
    func prepare(request: some LangToolsRequest) throws -> URLRequest { throw CalendarFixtureError.unexpectedNetwork }
    static func decodeStream<T: Decodable>(_ buffer: String) throws -> T? { throw CalendarFixtureError.unexpectedNetwork }
    func stream<Request: LangToolsStreamableRequest>(request: Request) -> AsyncThrowingStream<Request.Response, Error> {
        AsyncThrowingStream { $0.finish(throwing: CalendarFixtureError.unexpectedNetwork) }
    }
    static func chatRequest(model: any RawRepresentable, messages: [any LangToolsMessage], tools: [any LangToolsTool]?, responseSchema: JSONSchema?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> any LangToolsChatRequest {
        try OpenAI.chatRequest(model: model, messages: messages, tools: tools, responseSchema: responseSchema, toolEventHandler: toolEventHandler)
    }
    func perform<Request: LangToolsRequest>(request: Request) async throws -> Request.Response {
        requestCount += 1
        let chat = try XCTUnwrap(request as? OpenAI.ChatCompletionRequest)
        let isCalendar = chat.responseSchema != nil
        if callsTool {
            let toolName = isCalendar ? "agent_transfer" : "get_upcoming_events"
            let tool = try XCTUnwrap(chat.tools?.first(where: { $0.name == toolName }))
            let callback = try XCTUnwrap(tool.callback)
            let args: [String: JSON] = isCalendar ? ["agent_name": .string("calendarReadAgent"), "reason": .string("Synthetic query")] : [:]
            let info = LangToolsRequestInfo(langTool: self, model: OpenAI.Model.gpt4o, messages: chat.messages)
            chat.toolEventHandler?(.toolCalled(CalendarFixtureSelection(id: "fixture-\(toolName)", name: toolName, arguments: "{}")))
            let raw = try await callback(info, args)
            chat.toolEventHandler?(.toolCompleted(CalendarFixtureResult(tool_selection_id: "fixture-\(toolName)", result: raw ?? "", is_error: false)))
        }
        if isCalendar && failsAfterTools { throw CalendarFixtureError.unexpectedNetwork }
        if isCalendar && cancelsAfterTools { withUnsafeCurrentTask { $0?.cancel() } }
        let content = isCalendar ? finalText : "Delegate summarized native events in plain text."
        let response = OpenAI.ChatCompletionResponse(id: "fixture", object: "chat.completion", created: 0, model: chat.model.rawValue, system_fingerprint: nil,
            choices: [.init(index: 0, message: OpenAI.Message(role: .assistant, content: content), finish_reason: .stop, delta: nil, logprobs: nil)],
            usage: nil, service_tier: nil, choose: nil)
        return try request.update(response: JSONDecoder().decode(Request.Response.self, from: JSONEncoder().encode(response)))
    }
}

enum CalendarFixtureError: Error { case unexpectedNetwork }
private struct CalendarFixtureSelection: LangToolsToolSelection {
    let id: String?
    let name: String?
    let arguments: String
}
private struct CalendarFixtureResult: LangToolsToolSelectionResult {
    let tool_selection_id: String
    let result: String
    let is_error: Bool
    init(tool_selection_id: String, result: String, is_error: Bool) {
        self.tool_selection_id = tool_selection_id; self.result = result; self.is_error = is_error
    }
}
final class CalendarEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AgentEvent] = []
    var events: [AgentEvent] { lock.lock(); defer { lock.unlock() }; return storage }
    func record(_ event: AgentEvent) { lock.lock(); defer { lock.unlock() }; storage.append(event) }
}
