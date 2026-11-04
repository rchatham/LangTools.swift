import Agents
import Foundation
import LangTools
import OpenAI
import ToolKit
import XCTest
@testable import Chat

@MainActor
final class ToolRoutingTests: XCTestCase {
    private let tools = ["calendarAgent", "reminderAgent", "researchAgent"].map {
        Tool(name: $0, description: "\($0) description", tool_schema: .init())
    }

    private func makeService(router: ScriptedRouter?, network: NetworkClientProtocol = UnusedNetworkClient()) throws -> MessageService {
        let suiteName = "ToolRoutingTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let service = MessageService(networkClient: network, toolSettings: ToolSettings(defaults: defaults))
        service.toolRouter = router
        return service
    }

    private func userMessage(_ text: String) -> Message {
        Message(role: .user, contentType: .string(text))
    }

    private func names(_ tools: [Tool]?) -> [String]? {
        tools?.map(\.name)
    }

    private func scores(_ probabilities: [String: Double]) -> Result<ToolRoutingDecision, any Error> {
        .success(ToolRoutingDecision(toolProbabilities: probabilities))
    }

    func testAClearChoiceSendsOnlyThatTool() async throws {
        let router = ScriptedRouter(scores(["calendarAgent": 0.9, "reminderAgent": 0.05, "researchAgent": 0.01]))
        let service = try makeService(router: router)
        let message = userMessage("What's on my calendar?")

        let result = try await service.routedTools(tools, for: message, in: [message])

        XCTAssertEqual(names(result), ["calendarAgent"])
        let call = await router.lastCall
        XCTAssertEqual(call?.message, "What's on my calendar?")
        XCTAssertEqual(call?.options.map(\.name), ["calendarAgent", "reminderAgent", "researchAgent"])
        XCTAssertEqual(call?.options.first?.description, "calendarAgent description")
    }

    /// A user's "hi" scored low everywhere, yet reached web search when an uncertain
    /// top choice fell back to every tool.
    func testAGreetingSendsNoToolsEvenWhenTheRouterIsUnsure() async throws {
        let service = try makeService(router: ScriptedRouter(scores(["calendarAgent": 0.13, "reminderAgent": 0.19, "researchAgent": 0.009])))
        let message = userMessage("hi")

        let result = try await service.routedTools(tools, for: message, in: [message])

        XCTAssertNil(result)
        XCTAssertEqual(service.toolRoutes[message.uuid]?.route, .noTool)
    }

    func testAnUnsureChoiceSendsEveryPlausibleToolMostLikelyFirst() async throws {
        let service = try makeService(router: ScriptedRouter(scores(["calendarAgent": 0.3, "reminderAgent": 0.6, "researchAgent": 0.01])))
        let message = userMessage("Remind me to call mom tonight")

        let result = try await service.routedTools(tools, for: message, in: [message])

        XCTAssertEqual(names(result), ["reminderAgent", "calendarAgent"])
    }

    func testProbabilityAtTheMinimumIsKept() {
        let options = [ToolRoutingOption(name: "calendarAgent", description: "")]
        let outcome = ToolRoutingPolicy.outcome(
            for: ToolRoutingDecision(toolProbabilities: ["calendarAgent": 0.2]),
            offered: options,
            minimumProbability: 0.2
        )
        XCTAssertEqual(outcome.route, .tools([.init(name: "calendarAgent", probability: 0.2)]))
    }

    func testScoresForToolsThatWereNotOfferedAreIgnored() async throws {
        let service = try makeService(router: ScriptedRouter(scores(["calendarAgent": 0.6, "madeUp": 0.99])))
        let message = userMessage("Hello")

        let result = try await service.routedTools(tools, for: message, in: [message])

        XCTAssertEqual(names(result), ["calendarAgent"])
    }

    func testScoringNoOfferedToolCountsAsARouterFailure() async throws {
        let service = try makeService(router: ScriptedRouter(scores(["madeUp": 0.99])))
        let message = userMessage("Hello")

        let result = try await service.routedTools(tools, for: message, in: [message])

        XCTAssertEqual(names(result), ["calendarAgent", "reminderAgent", "researchAgent"])
        guard case .routerFailed = service.toolRoutes[message.uuid]?.route else {
            return XCTFail("Expected a router failure.")
        }
    }

    func testRouterFailureSendsEveryToolAndRecordsTheReason() async throws {
        let service = try makeService(router: ScriptedRouter(.failure(RouterFailure())))
        let message = userMessage("Hello")

        let result = try await service.routedTools(tools, for: message, in: [message])

        XCTAssertEqual(names(result), ["calendarAgent", "reminderAgent", "researchAgent"])
        XCTAssertEqual(service.toolRoutes[message.uuid]?.route, .routerFailed("router offline"))
    }

    func testRouterCancellationPropagates() async throws {
        let service = try makeService(router: ScriptedRouter(.failure(CancellationError())))
        let message = userMessage("Hello")

        do {
            _ = try await service.routedTools(tools, for: message, in: [message])
            XCTFail("Expected cancellation to propagate.")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertNil(service.toolRoutes[message.uuid])
    }

    func testAReplyKeepsThePreviousTurnsTools() async throws {
        let service = try makeService(router: ScriptedRouter(sequence: [
            ["calendarAgent": 0.9, "reminderAgent": 0.01, "researchAgent": 0.01],
            ["calendarAgent": 0.04, "reminderAgent": 0.01, "researchAgent": 0.01],
        ]))
        let first = userMessage("Book lunch on Friday")
        let reply = userMessage("ok go ahead")

        _ = try await service.routedTools(tools, for: first, in: [first])
        let result = try await service.routedTools(tools, for: reply, in: [first, reply])

        XCTAssertEqual(names(result), ["calendarAgent"])
        XCTAssertEqual(service.toolRoutes[reply.uuid]?.route, .followUp(scored: [], kept: ["calendarAgent"]))
    }

    /// A user asked about the weather right after a calendar turn and the model only
    /// received the calendar, because follow-ups used to skip the router.
    func testANewRequestAfterARoutedTurnGetsItsOwnToolFirst() async throws {
        let service = try makeService(router: ScriptedRouter(sequence: [
            ["calendarAgent": 0.9, "reminderAgent": 0.01, "researchAgent": 0.01],
            ["calendarAgent": 0.0, "reminderAgent": 0.0, "researchAgent": 1.0],
        ]))
        let first = userMessage("Show my calendar")
        let weather = userMessage("what is the weather in pacifica")

        _ = try await service.routedTools(tools, for: first, in: [first])
        let result = try await service.routedTools(tools, for: weather, in: [first, weather])

        XCTAssertEqual(names(result), ["researchAgent", "calendarAgent"])
    }

    func testAFollowUpIsNotListedTwiceWhenItScoresTheKeptTool() async throws {
        let service = try makeService(router: ScriptedRouter(sequence: [
            ["calendarAgent": 0.9, "reminderAgent": 0.01, "researchAgent": 0.01],
            ["calendarAgent": 0.91, "reminderAgent": 0.02, "researchAgent": 0.0],
        ]))
        let first = userMessage("Book lunch")
        let reply = userMessage("at 3pm")

        _ = try await service.routedTools(tools, for: first, in: [first])
        let result = try await service.routedTools(tools, for: reply, in: [first, reply])

        XCTAssertEqual(names(result), ["calendarAgent"])
    }

    func testCertainNoToolDropsKeptTools() async throws {
        let service = try makeService(router: ScriptedRouter(sequence: [
            ["calendarAgent": 0.9, "reminderAgent": 0.01, "researchAgent": 0.01],
            ["calendarAgent": 0.001, "reminderAgent": 0.001, "researchAgent": 0.001],
        ]))
        let first = userMessage("Show my calendar")
        let joke = userMessage("tell me a joke")

        _ = try await service.routedTools(tools, for: first, in: [first])
        let result = try await service.routedTools(tools, for: joke, in: [first, joke])

        XCTAssertNil(result)
        XCTAssertEqual(service.toolRoutes[joke.uuid]?.route, .noTool)
    }

    func testKeptToolsExpireAfterOneTurn() async throws {
        let service = try makeService(router: ScriptedRouter(sequence: [
            ["calendarAgent": 0.9, "reminderAgent": 0.01, "researchAgent": 0.01],
            ["calendarAgent": 0.04, "reminderAgent": 0.01, "researchAgent": 0.01],
            ["calendarAgent": 0.04, "reminderAgent": 0.01, "researchAgent": 0.01],
        ]))
        let first = userMessage("Book lunch")
        let reply = userMessage("ok go ahead")
        let next = userMessage("good call")

        _ = try await service.routedTools(tools, for: first, in: [first])
        _ = try await service.routedTools(tools, for: reply, in: [first, reply])
        let result = try await service.routedTools(tools, for: next, in: [first, reply, next])

        XCTAssertNil(result)
    }

    func testAToolChosenOnAFollowUpCarriesForward() async throws {
        let service = try makeService(router: ScriptedRouter(sequence: [
            ["calendarAgent": 0.9, "reminderAgent": 0.01, "researchAgent": 0.01],
            ["calendarAgent": 0.0, "reminderAgent": 0.0, "researchAgent": 1.0],
            ["calendarAgent": 0.04, "reminderAgent": 0.01, "researchAgent": 0.01],
        ]))
        let first = userMessage("Show my calendar")
        let weather = userMessage("what is the weather in pacifica")
        let reply = userMessage("ok go ahead")

        _ = try await service.routedTools(tools, for: first, in: [first])
        _ = try await service.routedTools(tools, for: weather, in: [first, weather])
        let result = try await service.routedTools(tools, for: reply, in: [first, weather, reply])

        XCTAssertEqual(names(result), ["researchAgent"])
    }

    func testRouterFailureOnAFollowUpSendsEveryTool() async throws {
        let router = ScriptedRouter(sequence: [["calendarAgent": 0.9, "reminderAgent": 0.01, "researchAgent": 0.01]], thenFailing: RouterFailure())
        let service = try makeService(router: router)
        let first = userMessage("Show my calendar")
        let reply = userMessage("ok go ahead")

        _ = try await service.routedTools(tools, for: first, in: [first])
        let result = try await service.routedTools(tools, for: reply, in: [first, reply])

        XCTAssertEqual(names(result), ["calendarAgent", "reminderAgent", "researchAgent"])
    }

    func testTurnAfterNoToolIsNotAFollowUp() async throws {
        let service = try makeService(router: ScriptedRouter(scores(["calendarAgent": 0.01, "reminderAgent": 0.01, "researchAgent": 0.01])))
        let first = userMessage("hi")
        let second = userMessage("how are you?")

        _ = try await service.routedTools(tools, for: first, in: [first])
        let result = try await service.routedTools(tools, for: second, in: [first, second])

        XCTAssertNil(result)
        XCTAssertEqual(service.toolRoutes[second.uuid]?.route, .noTool)
    }

    func testNoRouterLeavesToolsUntouched() async throws {
        let service = try makeService(router: nil)
        let message = userMessage("Hello")

        let result = try await service.routedTools(tools, for: message, in: [message])

        XCTAssertEqual(names(result), ["calendarAgent", "reminderAgent", "researchAgent"])
        XCTAssertTrue(service.toolRoutes.isEmpty)
    }

    func testRouterIsNotAskedWhenThereAreNoTools() async throws {
        let router = ScriptedRouter(scores([:]))
        let service = try makeService(router: router)
        let message = userMessage("Hello")

        let nilResult = try await service.routedTools(nil, for: message, in: [message])
        let emptyResult = try await service.routedTools([], for: message, in: [message])

        XCTAssertNil(nilResult)
        XCTAssertEqual(emptyResult?.count, 0)
        let callCount = await router.callCount
        XCTAssertEqual(callCount, 0)
    }

    func testClearingMessagesForgetsRoutes() async throws {
        let service = try makeService(router: ScriptedRouter(scores(["calendarAgent": 0.01])))
        let message = userMessage("Hello")
        _ = try await service.routedTools(tools, for: message, in: [message])

        service.clearMessages()

        XCTAssertTrue(service.toolRoutes.isEmpty)
    }

    func testSendPassesOnlyTheRoutedToolToTheModel() async throws {
        let toolName = "routing_test_\(UUID().uuidString)"
        let manager = ToolManager.shared
        let wasEnabled = manager.toolsEnabled
        manager.toolsEnabled = true
        manager.register(ToolConfiguration(id: toolName, displayName: "Test", description: "Test", iconName: "gear"))
        manager[toolName] = true
        addTeardownBlock { @MainActor in manager.toolsEnabled = wasEnabled }

        let network = UnusedNetworkClient()
        let service = try makeService(router: ScriptedRouter(scores([toolName: 0.9])), network: network)

        try await service.send(message: "Use the test tool", stream: true)

        XCTAssertEqual(network.requestedToolNames, [toolName])
        let userMessage = try XCTUnwrap(service.messages.first { $0.isUser })
        XCTAssertEqual(service.toolRoutes[userMessage.uuid]?.route, .tools([.init(name: toolName, probability: 0.9)]))
    }

    func testSummariesDescribeEachRoute() {
        let two = ToolRoutingOutcome(route: .tools([
            .init(name: "reminderAgent", probability: 0.614),
            .init(name: "calendarAgent", probability: 0.3),
        ]))
        XCTAssertEqual(two.summary, "reminderAgent 0.61, calendarAgent 0.30")
        XCTAssertEqual(ToolRoutingOutcome(route: .noTool).summary, "no tool")
        XCTAssertEqual(ToolRoutingOutcome(route: .followUp(scored: [], kept: ["calendarAgent"])).summary, "kept calendarAgent")
        XCTAssertEqual(
            ToolRoutingOutcome(route: .followUp(scored: [.init(name: "researchAgent", probability: 1)], kept: ["calendarAgent"])).summary,
            "researchAgent 1.00, kept calendarAgent"
        )
        XCTAssertEqual(ToolRoutingOutcome(route: .routerFailed("offline")).summary, "all tools, router failed: offline")
    }
}

private struct RouterFailure: LocalizedError {
    var errorDescription: String? { "router offline" }
}

private actor ScriptedRouter: LangToolsToolRouter {
    private var results: [Result<ToolRoutingDecision, any Error>]
    private(set) var callCount = 0
    private(set) var lastCall: (message: String, options: [ToolRoutingOption])?

    init(_ result: Result<ToolRoutingDecision, any Error>) {
        results = [result]
    }

    /// Answers in order, then repeats the last answer or throws `failure`.
    init(sequence: [[String: Double]], thenFailing failure: (any Error)? = nil) {
        results = sequence.map { .success(ToolRoutingDecision(toolProbabilities: $0)) }
        if let failure { results.append(.failure(failure)) }
    }

    func route(message: String, options: [ToolRoutingOption]) async throws -> ToolRoutingDecision {
        callCount += 1
        lastCall = (message, options)
        let result = results.count > 1 ? results.removeFirst() : results[0]
        return try result.get()
    }
}

private final class UnusedNetworkClient: NetworkClientProtocol {
    static let shared: NetworkClientProtocol = UnusedNetworkClient()

    /// The tools of the most recent request.
    private(set) var requestedToolNames: [String]?

    func performChatCompletionRequest(messages: [Message], model: Model, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) async throws -> Message {
        throw NetworkClient.NetworkError.incompatibleRequest
    }

    func streamChatCompletionRequest(messages: [Message], model: Model, stream: Bool, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> AsyncThrowingStream<String, Error> {
        requestedToolNames = tools?.map(\.name)
        return AsyncThrowingStream { continuation in
            continuation.yield("Done.")
            continuation.finish()
        }
    }

    func playAudio(for text: String) async throws {}
    func agentContext(messages: [Message], model: Model, eventHandler: @escaping (AgentEvent) -> Void) throws -> AgentContext {
        throw NetworkClient.NetworkError.incompatibleRequest
    }
    func updateApiKey(_ apiKey: String, for llm: APIService) throws {}
    func removeApiKey(for llm: APIService) throws {}
    func connectAccount(_ provider: AccountLoginProvider) async throws {}
    func disconnectAccount(_ provider: AccountLoginProvider) async throws {}
}
