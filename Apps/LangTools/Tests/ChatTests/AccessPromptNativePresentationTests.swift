#if os(macOS)
import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import Chat

/// Actual production modifier only: no Settings, ViewModel, auth client or transport.
@MainActor
final class AccessPromptNativePresentationTests: XCTestCase {
    func testOwnedConsentLightLifecycle() async throws { try await lifecycle(appearance: .aqua) }
    func testOwnedConsentDarkLifecycle() async throws { try await lifecycle(appearance: .darkAqua) }

    private func lifecycle(appearance: NSAppearance.Name) async throws {
        let fixture = try AccessPromptFixture()
        let calls = AccessPromptCalls()
        let initialModelReads = fixture.model.reads
        let context = fixture.context(calls: calls)
        XCTAssertNil(fixture.presentation.preferredDestination)
        XCTAssertEqual(fixture.model.reads, initialModelReads)
        let keyReads = fixture.keys.reads
        let credentialOperations = fixture.credentials.operations
        NSApplication.shared.finishLaunching()
        let selector = NSSelectorFromString("accessibilitySetEnhancedUserInterfaceAttribute:")
        if NSApplication.shared.responds(to: selector) {
            _ = NSApplication.shared.perform(selector, with: NSNumber(value: true))
        }
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.appearance = NSAppearance(named: appearance)
        host.contentView = NSHostingView(rootView: EmptyView()
            .manageAccessPrompts(accessPrompts: context, priority: 10)
            .frame(width: 600, height: 400))
        defer {
            fixture.presentation.dismiss()
            if let sheet = host.attachedSheet { host.endSheet(sheet); sheet.orderOut(nil) }
            host.contentView = nil
            host.orderOut(nil)
            host.close()
        }
        host.makeKeyAndOrderFront(nil)
        try await until("initial registration and nil-destination render") {
            fixture.presentation.presentationOwner != nil && fixture.model.reads > initialModelReads
        }
        // Ollama has no destination: exercise BOTH nil-destination model fallbacks.
        fixture.model.value = try XCTUnwrap(Model(rawValue: "ollama/llama3.2"))
        fixture.presentation.present()
        try await until("Ollama dialog") { host.attachedSheet != nil }
        let ollamaSheet = try XCTUnwrap(host.attachedSheet)
        try await until("Ollama fallback content") { self.labels(ollamaSheet).contains("Ollama Access") }
        fixture.presentation.dismiss()
        try await until("Ollama dismiss") { host.attachedSheet == nil }

        // Preferred destination overrides the still-selected Ollama model.
        fixture.presentation.present(preferredDestination: .openAI)
        try await until("owned consent attached") { host.attachedSheet?.isVisible == true }
        let sheet = try XCTUnwrap(host.attachedSheet)
        XCTAssertTrue(sheet.sheetParent === host)
        try await until("OpenAI consent rendered") { self.labels(sheet).contains("OpenAI Access") }
        try capture(sheet, appearance: appearance)
        let beforeDismiss = fixture.model.reads
        fixture.presentation.dismiss()
        try await until("dismiss and post-dismiss nil-destination render") {
            host.attachedSheet == nil && fixture.model.reads > beforeDismiss
        }
        XCTAssertNil(fixture.presentation.preferredDestination)
        host.contentView = nil
        try await until("unregister") { fixture.presentation.presentationOwner == nil }
        XCTAssertEqual(fixture.model.writes, 0)
        XCTAssertTrue(calls.actions.isEmpty)
        XCTAssertEqual(fixture.keys.reads, keyReads)
        XCTAssertTrue(fixture.keys.values.isEmpty)
        XCTAssertTrue(fixture.secrets.values.isEmpty)
        XCTAssertEqual(fixture.credentials.operations, credentialOperations)
    }

    private func until(_ label: String, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate() {
            guard Date() < deadline else { XCTFail("Timed out: \(label)"); throw Failure.timeout(label) }
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
    }

    private func labels(_ window: NSWindow) -> [String] {
        var visited = Set<ObjectIdentifier>()
        func visit(_ object: NSObject) -> [String] {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return [] }
            func attribute(_ name: String) -> Any? {
                let selector = NSSelectorFromString(name)
                return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() : nil
            }
            var result = [attribute("accessibilityLabel") as? String, attribute("accessibilityValue") as? String].compactMap { $0 }
            for child in attribute("accessibilityChildren") as? [NSObject] ?? [] { result += visit(child) }
            if let view = object as? NSView { for child in view.subviews { result += visit(child) } }
            return result
        }
        window.contentView?.layoutSubtreeIfNeeded()
        return visit(window) + (window.contentView.map { visit($0) } ?? [])
    }

    private func capture(_ window: NSWindow, appearance: NSAppearance.Name) throws {
        guard let path = ProcessInfo.processInfo.environment["ACCESS_PROMPT_ARTIFACTS"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        func display(_ view: NSView) {
            view.needsDisplay = true; view.display()
            for child in view.subviews { display(child) }
        }
        window.displayIfNeeded(); display(view); CATransaction.flush()
        // Capture AppKit's actual view drawing, not synthesized consent content.
        // Retain and report defective native output rather than substituting proof.
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: bitmap)
        }
        let name = "owned-access-" + (appearance == .darkAqua ? "dark" : "light")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
        let metadata = "Actual SDK EmptyView.manageAccessPrompts; macOS only; memory binding/coordinators/keys/secrets; no transport/login factories.\nrequested=\(appearance.rawValue); actual=\(window.effectiveAppearance.name.rawValue); viewport=\(view.bounds.size); pixels=\(bitmap.pixelsWide)x\(bitmap.pixelsHigh); attached=\(window.sheetParent != nil)\n"
        try (metadata + labels(window).joined(separator: "\n")).write(to: directory.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
    }

    private enum Failure: Error { case timeout(String) }
}
#endif
