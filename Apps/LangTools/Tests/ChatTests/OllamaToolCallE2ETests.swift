//
//  OllamaToolCallE2ETests.swift
//  ChatTests
//
//  End-to-end tool-call test against a local Ollama server. Renders the resulting
//  ChatToolCall cards (collapsed + expanded) to PNGs for visual review.
//  Skips automatically if Ollama is not reachable.
//

import Agents
import Foundation
import LangTools
import OpenAI
import Ollama
import ToolKit
import ChatUI
import SwiftUI
import XCTest
@testable import Chat
@testable import ChatUI

#if canImport(AppKit)
import AppKit
#endif

@MainActor
final class OllamaToolCallE2ETests: XCTestCase {

    private enum ScreenshotError: Error, Equatable {
        case imageRenderingFailed(name: String)
        case tiffConversionFailed(name: String)
        case bitmapRepresentationFailed(name: String)
        case pngConversionFailed(name: String)
    }

    private let outputDir = "/tmp/chatui-toolcall-e2e"
    private let ollamaURL = URL(string: "http://localhost:11434")!

    private func ollamaReachable() async -> Bool {
        await withCheckedContinuation { cont in
            var req = URLRequest(url: ollamaURL.appendingPathComponent("api/tags"))
            req.timeoutInterval = 2
            URLSession.shared.dataTask(with: req) { _, resp, _ in
                cont.resume(returning: (resp as? HTTPURLResponse)?.statusCode == 200)
            }.resume()
        }
    }

    private func render(_ view: some View, name: String, width: CGFloat = 440) throws {
        let host = view.frame(width: width, alignment: .leading).padding(16).background(Color.white)
        let renderer = ImageRenderer(content: host)
        renderer.scale = 2
        #if canImport(AppKit)
        let image = try requireScreenshotValue(
            renderer.nsImage,
            error: .imageRenderingFailed(name: name)
        )
        let tiff = try requireScreenshotValue(
            image.tiffRepresentation,
            error: .tiffConversionFailed(name: name)
        )
        let representation = try requireScreenshotValue(
            NSBitmapImageRep(data: tiff),
            error: .bitmapRepresentationFailed(name: name)
        )
        let png = try requireScreenshotValue(
            representation.representation(using: .png, properties: [:]),
            error: .pngConversionFailed(name: name)
        )
        try png.write(to: URL(fileURLWithPath: "\(outputDir)/\(name).png"))
        print("📸 e2e wrote \(outputDir)/\(name).png")
        #else
        throw XCTSkip("PNG screenshot rendering requires AppKit")
        #endif
    }

    private func requireScreenshotValue<Value>(
        _ value: Value?,
        error: ScreenshotError
    ) throws -> Value {
        guard let value else {
            throw error
        }
        return value
    }

    func testOllamaToolCallRendersCollapsedAndExpanded() async throws {
        let reachable = await ollamaReachable()
        try XCTSkipUnless(reachable, "Ollama not reachable at \(ollamaURL.absoluteString)")
        try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

        let ollama = Ollama()
        guard let model = Ollama.Model(rawValue: "llama3.1") else {
            throw XCTSkip("llama3.1 model not available")
        }

        // Built-in tools with real callbacks (OpenAI.Tool is Ollama.ChatRequest.Tool).
        let tools: [OpenAI.Tool] = BuiltInTools.configurations().map { $0.toTool() }

        // Accumulate tool events onto a Chat Message via the real applyToolEvent path.
        let message = Message(role: .assistant, contentType: .null)
        let request = Ollama.ChatRequest(
            model: model,
            messages: [Ollama.Message(role: .user, content: "What is 25 * 4? You must use the calculate tool to compute the answer.")],
            stream: true,
            tools: tools,
            toolEventHandler: { event in message.applyToolEvent(event) }
        )

        // Stream to completion; LangTools runs the tool callback and fires events.
        for try await _ in ollama.stream(request: request) {}

        XCTAssertFalse(message.toolCalls.isEmpty, "Expected the model to call at least one tool")
        let call = message.toolCalls[0]
        XCTAssertEqual(call.kind, .tool)

        try render(ToolCallView(toolCall: call), name: "ollama-tool-collapsed")
        try render(ToolCallView(toolCall: call, isExpanded: true), name: "ollama-tool-expanded")
    }

    func testAgentCardCollapsedAndExpanded() throws {
        // Real agents need platform APIs/credentials, so simulate the event-derived
        // ChatToolCall tree and render collapsed + expanded.
        try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        let agent = ChatToolCall(
            id: "a1", name: "CalendarAgent", kind: .agent, status: .success, details: "started: list today's events",
            children: [
                ChatToolCall(id: "c1", name: "list_events", kind: .tool, arguments: #"{"calendar":"primary"}"#, status: .success, result: "3 events"),
                ChatToolCall(id: "c2", name: "create_event", kind: .tool, arguments: #"{"title":"Lunch"}"#, status: .success, result: "created")
            ]
        )
        try render(ToolCallView(toolCall: agent), name: "ollama-agent-collapsed", width: 460)
        try render(ToolCallView(toolCall: agent, isExpanded: true), name: "ollama-agent-expanded", width: 460)
    }

    func testDelegationRetryScreenshots() throws {
        // Render cards assembled from the same agent lifecycle events as a real
        // delegation; only the provider responses are simulated here.
        try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        try renderRetry(secondAttemptFails: true, name: "calendar-retry-failed")
        try renderRetry(secondAttemptFails: false, name: "calendar-retry-recovered")
    }

    func testScreenshotConversionFailureThrows() {
        let expectedError = ScreenshotError.pngConversionFailed(name: "failed-screenshot")

        XCTAssertThrowsError(
            try requireScreenshotValue(nil as Data?, error: expectedError)
        ) { error in
            XCTAssertEqual(error as? ScreenshotError, expectedError)
        }
    }

    private func renderRetry(secondAttemptFails: Bool, name: String) throws {
        let service = MessageService(networkClient: ScreenshotNetworkStub())
        service.messages = [Message(role: .assistant, contentType: .null)]
        let events: [AgentEvent] = [
            .started(agent: "calendarAgent", parent: nil, task: "check upcoming events"),
            .agentTransfer(from: "calendarAgent", to: "calendarReadAgent", reason: "read upcoming events"),
            .started(agent: "calendarReadAgent", parent: "calendarAgent", task: "read upcoming events"),
            .toolCalled(agent: "calendarReadAgent", tool: "get_upcoming_events", arguments: #"{"limit":10}"#),
            .error(agent: "calendarReadAgent", message: "JSON parsing failure"),
            .completed(agent: "calendarReadAgent", result: "JSON parsing failure", is_error: true),
            .agentTransfer(from: "calendarAgent", to: "calendarReadAgent", reason: "retry with explicit dates"),
            .started(agent: "calendarReadAgent", parent: "calendarAgent", task: "retry calendar read"),
            .toolCalled(agent: "calendarReadAgent", tool: "get_events", arguments: #"{"start_date":"2026-09-22"}"#)
        ] + (secondAttemptFails ? [
            .error(agent: "calendarReadAgent", message: "JSON parsing failure"),
            .completed(agent: "calendarReadAgent", result: "JSON parsing failure", is_error: true),
            .completed(agent: "calendarAgent", result: "Unable to read events", is_error: true)
        ] : [
            .toolCompleted(agent: "calendarReadAgent", result: "1 event"),
            .completed(agent: "calendarReadAgent", result: "1 event"),
            .completed(agent: "calendarAgent", result: "Found 1 event")
        ])
        events.forEach(service.handleAgentEvent)
        service.drainAgentEvents()
        let root = try XCTUnwrap(service.messages.first?.toolCalls.first)
        XCTAssertEqual(root.children.filter { $0.name == "calendarReadAgent" }.count, 2)
        XCTAssertFalse(root.children.contains { $0.name == "agent_transfer" })
        XCTAssertFalse(root.children.contains { $0.status == .pending })
        try render(ToolCallView(toolCall: root, isExpanded: true), name: name, width: 600)
    }
}

private final class ScreenshotNetworkStub: NetworkClientProtocol {
    static let shared: NetworkClientProtocol = ScreenshotNetworkStub()

    func performChatCompletionRequest(
        messages: [Message],
        model: Model,
        tools: [Tool]?,
        toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?,
        toolEventHandler: @escaping (LangToolsToolEvent) -> Void
    ) async throws -> Message {
        throw NetworkClient.NetworkError.incompatibleRequest
    }

    func streamChatCompletionRequest(
        messages: [Message],
        model: Model,
        stream: Bool,
        tools: [Tool]?,
        toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?,
        toolEventHandler: @escaping (LangToolsToolEvent) -> Void
    ) throws -> AsyncThrowingStream<String, Error> {
        throw NetworkClient.NetworkError.incompatibleRequest
    }

    func playAudio(for text: String) async throws {}

    func agentContext(
        messages: [Message],
        model: Model,
        eventHandler: @escaping (AgentEvent) -> Void
    ) throws -> AgentContext {
        throw NetworkClient.NetworkError.incompatibleRequest
    }

    func updateApiKey(_ apiKey: String, for llm: APIService) throws {}
    func removeApiKey(for llm: APIService) throws {}
    func connectAccount(_ provider: AccountLoginProvider) async throws {}
    func disconnectAccount(_ provider: AccountLoginProvider) async throws {}
}
