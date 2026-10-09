import Chat
import ChatUI
import Foundation
import LangTools
import SwiftUI
import XCTest
#if os(macOS)
import AppKit
import Vision
#endif

private struct RenderedSummaryCard: StructuredOutput {
    let title: String
    static var jsonSchema: JSONSchema {
        .object(properties: ["title": .string(description: "Title")], required: ["title"])
    }
}

#if os(macOS)
/// Native accessibility/text coverage for the registry itself. Full Botsworth
/// invocation-row screenshots are covered by the host's integration tests.
@MainActor
final class RenderedContentCardRegistryTests: XCTestCase {
    private let summary = "Calendar lookup finished: one event tomorrow."
    private let title = "Planning meeting at 10:00 AM"

    private func registeredDisplay(kind: ChatToolCall.Kind = .agent) -> ChatToolCall.DisplayContent {
        let registry = ContentCardRegistry.shared
        let type = "summary-fixture-" + UUID().uuidString
        let render: @Sendable ([RenderedSummaryCard]) -> AnyView = { items in
            AnyView(ForEach(items.indices, id: \.self) { index in
                Text(items[index].title)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            })
        }
        if kind == .agent {
            registry.register(agent: type, cardType: type, as: RenderedSummaryCard.self, render: render)
        } else {
            registry.register(tool: type, cardType: type, as: RenderedSummaryCard.self, render: render)
        }
        return ChatToolCall.DisplayContent(
            type: type, json: #"[{"title":"Planning meeting at 10:00 AM"}]"#,
            summary: summary, itemCount: 1
        )
    }

    private struct TextNode {
        let text: String
        let frame: NSRect
    }

    private func textNodes(from root: NSView) -> [TextNode] {
        var visited = Set<ObjectIdentifier>()
        var nodes: [TextNode] = []
        func visit(_ element: Any) {
            let object: AnyObject
            let role: NSAccessibility.Role?
            let label: String?
            let value: Any?
            let frame: NSRect
            let children: [Any]
            if let view = element as? NSView {
                object = view
                role = view.accessibilityRole()
                label = view.accessibilityLabel()
                value = view.accessibilityValue()
                frame = view.accessibilityFrame()
                children = view.accessibilityChildren() ?? view.subviews
            } else if let element = element as? NSAccessibilityElement {
                object = element
                role = element.accessibilityRole()
                label = element.accessibilityLabel()
                value = element.accessibilityValue()
                frame = element.accessibilityFrame()
                children = element.accessibilityChildren() ?? []
            } else { return }
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            if role == .staticText {
                let text = (value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? label ?? ""
                nodes.append(TextNode(text: text, frame: frame))
            }
            children.forEach(visit)
        }
        visit(root)
        return nodes
    }

    /// SwiftPM's offscreen host may not expose SwiftUI accessibility nodes.
    /// In that case, assert actual rendered text using local Vision OCR instead
    /// of skipping the visibility check or asserting only the payload model.
    private func renderedTextNodes(from host: NSView) throws -> [TextNode] {
        let accessible = textNodes(from: host)
        if !accessible.isEmpty { return accessible }
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = try XCTUnwrap(bitmap.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        print("SwiftUI accessibility nodes unavailable; verifying native rendered text with local Vision OCR")
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let box = observation.boundingBox
            return TextNode(text: text, frame: NSRect(x: box.minX, y: box.minY, width: box.width, height: box.height))
        }
    }

    private func withRenderedView<V: View>(
        _ view: V, width: CGFloat = 375, inspect: (NSHostingView<AnyView>, [TextNode]) throws -> Void
    ) throws {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: AnyView(view.padding(16).frame(width: width).background(Color(nsColor: .windowBackgroundColor))))
        hosting.appearance = NSAppearance(named: .aqua)
        let size = NSSize(width: width, height: max(hosting.fittingSize.height, 120))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        hosting.layoutSubtreeIfNeeded()
        try inspect(hosting, renderedTextNodes(from: hosting))
    }

    func testDistinctSummaryAboveAgentAndToolItemsBeforeAndAfterPersistence() throws {
        for kind in [ChatToolCall.Kind.agent, .tool] {
            let display = registeredDisplay(kind: kind)
            let message = Message(role: .assistant, toolCalls: [
                ChatToolCall(id: "summary-call", name: "calendar", kind: kind, status: .success, result: "raw", displayContent: display)
            ])
            let reloaded = try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(message))
            for payload in [display, try XCTUnwrap(reloaded.toolCalls[0].displayContent)] {
                try withRenderedView(ContentCardRegistry.shared.view(for: payload)) { _, nodes in
                    XCTAssertEqual(nodes.filter { $0.text == self.summary }.count, 1, "Summary appears once")
                    XCTAssertEqual(nodes.filter { $0.text == self.title }.count, 1)
                    let summaryNode = try XCTUnwrap(nodes.first { $0.text == self.summary })
                    let itemNode = try XCTUnwrap(nodes.first { $0.text == self.title })
                    XCTAssertGreaterThan(summaryNode.frame.midY, itemNode.frame.midY, "Summary is visually above items in AppKit screen coordinates")
                }
            }
        }
    }

    func testLegacyStandaloneDoesNotDuplicateSummary() throws {
        let display = registeredDisplay()
        let content = ContentCardsContent(cardType: display.type, message: display.summary, cardsJSON: display.json, cardCount: display.itemCount)
        let message = Message.contentCards(content)
        try withRenderedView(VStack(alignment: .leading) {
            Text(message.text ?? "")
            ContentCardRegistry.shared.view(for: content)
        }) { _, nodes in
            XCTAssertEqual(nodes.filter { $0.text == self.summary }.count, 1)
            XCTAssertEqual(nodes.filter { $0.text == self.title }.count, 1)
        }
    }

    func testEmptyDecodedItemsStillShowSummary() throws {
        var display = registeredDisplay()
        display.json = "[]"
        display.itemCount = 0
        try withRenderedView(ContentCardRegistry.shared.view(for: display)) { _, nodes in
            XCTAssertEqual(nodes.map(\.text), [self.summary])
        }
    }

    func testNilEmptyAndWhitespaceSummaryRenderOnlyItems() throws {
        let base = registeredDisplay()
        for summary in [nil, "", " \n\t"] as [String?] {
            var display = base
            display.summary = summary
            try withRenderedView(ContentCardRegistry.shared.view(for: display)) { _, nodes in
                XCTAssertEqual(nodes.map(\.text), [self.title])
            }
        }
    }

    func testUnknownAndCorruptPayloadHaveSingleGracefulFallback() throws {
        var corrupt = registeredDisplay()
        corrupt.json = "not JSON"
        let unknown = ChatToolCall.DisplayContent(type: "missing-fixture", json: "[]", summary: summary, itemCount: 0)
        for display in [corrupt, unknown] {
            try withRenderedView(ContentCardRegistry.shared.view(for: display), width: 800) { _, nodes in
                XCTAssertEqual(nodes.count, 1, "Do not add a duplicate summary above the fallback")
                let fallback = try XCTUnwrap(nodes.first).text
                XCTAssertTrue(fallback.contains(self.summary))
                XCTAssertFalse(fallback.contains(self.title))
            }
        }
        let noSummary = ChatToolCall.DisplayContent(type: "missing-fixture", json: "[]", summary: " \n", itemCount: 0)
        try withRenderedView(ContentCardRegistry.shared.view(for: noSummary)) { _, nodes in
            XCTAssertEqual(nodes.map(\.text), ["Unknown card type: missing-fixture"])
        }
    }

    func testNativeSummaryRendererArtifactsAt375And800() throws {
        // Opt-in output keeps normal unit tests from writing outside the package.
        guard let directory = ProcessInfo.processInfo.environment["RICH_RESULTS_ARTIFACT_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let display = registeredDisplay()
        let reloaded = try JSONDecoder().decode(ChatToolCall.DisplayContent.self, from: JSONEncoder().encode(display))
        for width: CGFloat in [375, 800] {
            try withRenderedView(ContentCardRegistry.shared.view(for: reloaded), width: width) { hosting, nodes in
                XCTAssertTrue(nodes.contains { $0.text == self.summary })
                XCTAssertTrue(nodes.contains { $0.text == self.title })
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let url = URL(fileURLWithPath: directory).appendingPathComponent("mr21-summary-renderer-\(Int(width)).png")
                try png.write(to: url)
                print("Saved native summary renderer: \(url.path)")
            }
        }
    }
}
#endif
