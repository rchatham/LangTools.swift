import Agents
import Foundation
import LangTools
import OpenAI
import SwiftUI
import XCTest
@testable import Chat
@testable import ChatUI
@testable import ExampleAgents
#if os(macOS)
import AppKit
import Vision
#endif

/// Real Calendar execution -> shared service attachment -> persistence -> app
/// renderer. CalendarEventCard.swift is a symlink to the app's actual view source.
@MainActor
final class CalendarRichResultPipelineTests: XCTestCase {
    func testMalformedModelOutputBecomesPersistedNativeCalendarCards() async throws {
        try await verifyPipeline(keepsHistory: true)
    }

    func testHistoryDisabledProducesOneStandaloneNativeCalendarCard() async throws {
        try await verifyPipeline(keepsHistory: false)
    }

    private func verifyPipeline(keepsHistory: Bool) async throws {
        let suite = "calendar-rich-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ToolSettings(defaults: defaults)
        settings.keepsToolCallsInHistory = keepsHistory
        settings.richContentEnabled = true
        let service = MessageService(networkClient: CalendarNoNetworkClient(), toolSettings: settings)
        let registry = ContentCardRegistry.shared
        let cardType = "calendar-execution-fixture-" + UUID().uuidString
        // Unique registry key avoids overwriting production registrations.
        let agentKey = "calendar-execution-fixture-" + UUID().uuidString
        registry.register(agent: agentKey, cardType: cardType, as: CalendarEventData.self,
            decode: { raw in
                guard let response = try? CalendarAgentResponse(jsonString: raw) else { return nil }
                return (response.message, response.events)
            }, render: { events in ForEach(events) { $0.cardView() } })
        service.resultContentParser = { raw, name, kind in
            guard name == "calendarAgent", kind == .agent else { return nil }
            return registry.resultContentParser(raw, agentKey, kind)
        }
        let native = CalendarEventData(title: "Synthetic planning session", startDate: "2030-01-15T10:00:00Z",
                                      endDate: "2030-01-15T11:00:00Z", location: "Fixture room",
                                      notes: "Synthetic data only", calendarName: "Test calendar", eventIdentifier: "fixture-event")
        var calendar = CalendarAgent()
        calendar.delegateAgents = [CalendarReadAgent(queries: .init(fetch: { _, _ in [native] }, upcoming: { _ in [native] }, search: { _ in [native] }))]
        let provider = CalendarFixtureProvider(finalText: #"{"events":[{"title":"Wrong model item","date":"2030-01-15","time":"Afternoon"}]}"#)
        let recorder = CalendarEventRecorder()
        let context = AgentContext(langTool: provider, model: OpenAI.Model.gpt4o, messages: [], eventHandler: recorder.record)
        let result = try await (calendar as any Agent).execute(context: context)
        for event in recorder.events { service.handleAgentEvent(event) }
        service.drainAgentEvents()
        if !keepsHistory {
            let standalone = service.messages.compactMap { message -> ContentCardsContent? in
                if case .contentCards(let content) = message.contentType { return content }
                return nil
            }
            XCTAssertEqual(standalone.count, 1)
            XCTAssertEqual(try XCTUnwrap(standalone.first).decodeCards(as: CalendarEventData.self), [native])
            XCTAssertFalse(service.messages.flatMap(\.toolCalls).contains { $0.displayContent != nil })
            return
        }
        let message = try XCTUnwrap(service.messages.first(where: { !$0.toolCalls.isEmpty }))
        let call = try XCTUnwrap(message.toolCalls.first(where: { $0.name == "calendarAgent" }))
        XCTAssertEqual(call.status, .success)
        XCTAssertEqual(call.result, result)
        let display = try XCTUnwrap(call.displayContent)
        XCTAssertEqual(display.itemCount, 1)
        XCTAssertEqual(try JSONDecoder().decode([CalendarEventData].self, from: Data(display.json.utf8)), [native])
        XCTAssertFalse(service.messages.contains { if case .contentCards = $0.contentType { return true }; return false })
        let reloaded = try JSONDecoder().decode(Chat.Message.self, from: JSONEncoder().encode(message))
        let reloadedCall = try XCTUnwrap(reloaded.toolCalls.first(where: { $0.id == call.id }))
        XCTAssertEqual(reloadedCall.displayContent, display)
        XCTAssertEqual(reloadedCall.result, result)
        #if os(macOS)
        if let output = ProcessInfo.processInfo.environment["CALENDAR_NATIVE_RESULT_ARTIFACT_DIR"] {
            for width: CGFloat in [375, 800] {
                try capture(reloadedCall, registry: registry, width: width, directory: output)
            }
        }
        #endif
    }

    #if os(macOS)
    private func capture(_ call: ChatToolCall, registry: ContentCardRegistry, width: CGFloat, directory: String) throws {
        NSApplication.shared.finishLaunching()
        let root = ToolCallView(toolCall: call, isExpanded: false, toolCallContent: { call in
            guard let display = call.displayContent else { return nil }
            return AnyView(registry.view(for: display))
        }).padding(16).frame(width: width).background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: .aqua)
        let size = NSSize(width: width, height: max(host.fittingSize.height, 240))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = try XCTUnwrap(bitmap.cgImage)
        let recognition = VNRecognizeTextRequest()
        recognition.recognitionLevel = .accurate
        recognition.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([recognition])
        let visible = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        XCTAssertTrue(visible.contains("Synthetic planning session"), visible)
        XCTAssertTrue(visible.contains("Fixture room"), visible)
        XCTAssertFalse(visible.contains("Wrong model item"), visible)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: directory).appendingPathComponent("calendar-native-result-\(Int(width)).png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
    #endif
}

private final class CalendarNoNetworkClient: NetworkClientProtocol {
    static var shared: NetworkClientProtocol { CalendarNoNetworkClient() }
    func performChatCompletionRequest(messages: [Chat.Message], model: Chat.Model, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) async throws -> Chat.Message { throw CalendarFixtureError.unexpectedNetwork }
    func streamChatCompletionRequest(messages: [Chat.Message], model: Chat.Model, stream: Bool, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> AsyncThrowingStream<String, Error> { throw CalendarFixtureError.unexpectedNetwork }
    func agentContext(messages: [Chat.Message], model: Chat.Model, eventHandler: @escaping (AgentEvent) -> Void) throws -> AgentContext { throw CalendarFixtureError.unexpectedNetwork }
    func playAudio(for text: String) async throws { throw CalendarFixtureError.unexpectedNetwork }
    func updateApiKey(_ apiKey: String, for llm: Chat.APIService) throws { throw CalendarFixtureError.unexpectedNetwork }
    func removeApiKey(for llm: Chat.APIService) throws { throw CalendarFixtureError.unexpectedNetwork }
    func connectAccount(_ provider: AccountLoginProvider) async throws { throw CalendarFixtureError.unexpectedNetwork }
    func disconnectAccount(_ provider: AccountLoginProvider) async throws { throw CalendarFixtureError.unexpectedNetwork }
}
