//
//  OllamaToolCallE2ETests.swift
//  ChatTests
//
//  End-to-end tool-call test against a local Ollama server. Renders the resulting
//  ChatToolCall cards (collapsed + expanded) to PNGs for visual review.
//  Skips automatically if Ollama is not reachable.
//

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
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return
        }
        try png.write(to: URL(fileURLWithPath: "\(outputDir)/\(name).png"))
        print("📸 e2e wrote \(outputDir)/\(name).png")
        #endif
    }

    func testOllamaToolCallRendersCollapsedAndExpanded() async throws {
        let reachable = await ollamaReachable()
        try XCTSkipUnless(reachable, "Ollama not reachable at \(ollamaURL.absoluteString)")
        try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

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
        try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
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
}