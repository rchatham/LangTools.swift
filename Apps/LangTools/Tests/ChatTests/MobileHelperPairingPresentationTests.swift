#if os(macOS)
import AppKit
import Chat
import HelperLink
import SwiftUI
import XCTest

/// Hosts the production modifier, not a replica or an ImageRenderer of its parent.
/// The legacy title is exercised with injection; the no-argument/.shared wiring is
/// intentionally not invoked. Confirmation is never pressed or called.
@MainActor
final class MobileHelperPairingPresentationTests: XCTestCase {
    func testDefaultTitleConfirmationSheetAndCancel() async throws {
        try await verifyConfirmation(scheme: "langtools-example-auth",
            title: "Connect LangToolsHelper", artifact: "langtools-default-confirmation")
    }

    func testCustomTitleConfirmationSheetAndCancel() async throws {
        try await verifyConfirmation(scheme: "botsworth",
            title: "Connect Botsworth Helper", artifact: "botsworth-custom-confirmation")
    }

    func testInvalidLinkPresentsFailureWithoutPairing() async throws {
        let fixture = try Fixture(scheme: "botsworth")
        defer { fixture.close() }
        try await waitUntil("host window visible") { fixture.window.isVisible }
        fixture.coordinator.handle(try XCTUnwrap(URL(string: "botsworth://helper/pair?invalid=1")))
        try await waitUntil("production failure alert attached") { fixture.window.attachedSheet?.isVisible == true }
        let sheet = try XCTUnwrap(fixture.window.attachedSheet)
        try await waitUntil("failure alert text rendered") {
            Self.elements(in: sheet).contains { $0.text == "Helper Pairing Failed" }
        }
        XCTAssertNil(fixture.coordinator.pendingPairing)
        XCTAssertNotNil(fixture.coordinator.errorMessage)
        XCTAssertFalse(fixture.coordinator.isPairing)
        XCTAssertEqual(fixture.selections, 0)
        XCTAssertEqual(fixture.configuration.snapshot(), fixture.initialSnapshot)
        let elements = Self.elements(in: sheet)
        XCTAssertTrue(elements.contains { $0.text?.contains("Invalid helper pairing QR") == true })
        XCTAssertFalse(elements.contains { $0.identifier == "mobile-helper-confirm" })
        try capture(sheet: sheet, artifact: "botsworth-invalid-link", elements: elements)
        fixture.coordinator.dismissError()
        try await waitUntil("failure alert dismissed") { fixture.window.attachedSheet == nil }
    }

    private func verifyConfirmation(scheme: String, title: String, artifact: String) async throws {
        let fixture = try Fixture(scheme: scheme, title: title)
        defer { fixture.close() }
        try await waitUntil("host window visible") { fixture.window.isVisible }
        // Valid envelope, but no redeemable code, real helper, certificate or listener.
        let payload = MobileHelperPairingPayload(
            endpoint: try XCTUnwrap(URL(string: "https://192.168.255.254:8086")),
            helperID: "11111111-1111-4111-8111-111111111111",
            fingerprint: String(repeating: "a", count: 64),
            code: String(repeating: "b", count: 64), name: "Synthetic Verification Mac")
        fixture.coordinator.handle(try payload.pairingURL(scheme: scheme))
        XCTAssertEqual(fixture.coordinator.pendingPairing, payload)
        try await waitUntil("production confirmation sheet attached") {
            fixture.window.attachedSheet?.isVisible == true
        }
        let sheet = try XCTUnwrap(fixture.window.attachedSheet)
        XCTAssertTrue(sheet.sheetParent === fixture.window)
        XCTAssertTrue(sheet !== fixture.window)
        try await waitUntil("sheet title and confirmation control rendered") {
            let elements = Self.elements(in: sheet)
            return elements.contains { $0.text == title }
                && elements.contains { $0.identifier == "mobile-helper-confirm" }
        }
        let elements = Self.elements(in: sheet)
        for text in [title, "Pair with Synthetic Verification Mac?", payload.endpoint.absoluteString,
                     "Requested capability: Ollama", "Pair and Use Helper", "Cancel",
                     "Allow this Mac to provide Ollama models and process your chats. Confirm only if you scanned this QR from your trusted Mac.",
                     "Encrypted connection pinned to this helper's certificate. No account, filesystem, or command access is granted."] {
            XCTAssertTrue(elements.contains { $0.text == text }, "Missing production sheet text: \(text)")
        }
        XCTAssertTrue(elements.contains { $0.identifier == "mobile-helper-confirm" && $0.role == NSAccessibility.Role.button.rawValue })
        XCTAssertFalse(fixture.coordinator.isPairing)
        XCTAssertNil(fixture.coordinator.errorMessage)
        XCTAssertEqual(fixture.selections, 0)
        XCTAssertEqual(fixture.configuration.snapshot(), fixture.initialSnapshot)
        try capture(sheet: sheet, artifact: artifact, elements: elements)

        // Exercise only the production Cancel button using in-process accessibility.
        let cancel = try XCTUnwrap(elements.first {
            $0.role == NSAccessibility.Role.button.rawValue && $0.text == "Cancel"
        }?.object)
        let press = NSSelectorFromString("accessibilityPerformPress")
        guard cancel.responds(to: press) else {
            throw PresentationError.unavailableCancelAction
        }
        _ = cancel.perform(press)
        try await waitUntil("Cancel dismisses the actual sheet") {
            fixture.coordinator.pendingPairing == nil && fixture.window.attachedSheet == nil
        }
        XCTAssertFalse(fixture.coordinator.isPairing)
        XCTAssertEqual(fixture.selections, 0)
        XCTAssertEqual(fixture.configuration.snapshot(), fixture.initialSnapshot)
        XCTAssertNil(fixture.defaults.string(forKey: "ollamaSelectedMobileHelperID"))
    }

    private func waitUntil(_ description: String, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for \(description); an actual AppKit sheet is required")
                throw PresentationError.timeout(description)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        // Let AppKit finish sheet animation/layout before inspecting or capturing.
        try await Task.sleep(nanoseconds: 300_000_000)
    }

    private struct Element {
        let object: NSObject
        let role: String?
        let text: String?
        let identifier: String?
    }

    private static func elements(in window: NSWindow) -> [Element] {
        var visited = Set<ObjectIdentifier>()
        func visit(_ object: NSObject) -> [Element] {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return [] }
            var result: [Element] = []
            func attribute(_ name: String) -> Any? {
                let selector = NSSelectorFromString(name)
                guard object.responds(to: selector) else { return nil }
                return object.perform(selector)?.takeUnretainedValue()
            }
            result.append(Element(object: object,
                role: attribute("accessibilityRole") as? String,
                text: attribute("accessibilityLabel") as? String ?? attribute("accessibilityValue") as? String,
                identifier: attribute("accessibilityIdentifier") as? String))
            for child in attribute("accessibilityChildren") as? [NSObject] ?? [] {
                result += visit(child)
            }
            if let view = object as? NSView {
                for child in view.subviews { result += visit(child) }
            }
            return result
        }
        window.contentView?.layoutSubtreeIfNeeded()
        var result = visit(window)
        if let content = window.contentView { result += visit(content) }
        return result
    }

    /// Opt-in, in-process view bitmap capture: no screen recording API, permission
    /// changes, global screenshots, or parent-only renders masquerading as a sheet.
    private func capture(sheet: NSWindow, artifact: String, elements: [Element]) throws {
        guard let path = ProcessInfo.processInfo.environment["MOBILE_HELPER_PRESENTATION_ARTIFACTS"],
              !path.isEmpty else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard directory.path == "/tmp/botsworth-phase1/presentation" else {
            throw PresentationError.invalidArtifactDirectory
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertTrue(sheet.isVisible)
        XCTAssertNotNil(sheet.sheetParent)
        let view = try XCTUnwrap(sheet.contentView)
        view.layoutSubtreeIfNeeded()
        func displaySubtree(_ view: NSView) {
            view.needsDisplay = true
            view.display()
            for child in view.subviews { displaySubtree(child) }
        }
        sheet.displayIfNeeded()
        displaySubtree(view)
        CATransaction.flush()
        let layer = try XCTUnwrap(view.layer)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width * 2), pixelsHigh: Int(view.bounds.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext)
        context.scaleBy(x: 2, y: 2)
        sheet.effectiveAppearance.performAsCurrentDrawingAppearance {
            // AppKit's material background is compositor-backed; use the actual
            // window background color beneath the captured production layers.
            context.setFillColor(sheet.backgroundColor.cgColor)
            context.fill(view.bounds)
        }
        if layer.isGeometryFlipped {
            context.translateBy(x: 0, y: view.bounds.height)
            context.scaleBy(x: 1, y: -1)
        }
        layer.render(in: context)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent(artifact + ".png"), options: .atomic)
        let text = elements.map { "\($0.role ?? "-") | \($0.identifier ?? "-") | \($0.text ?? "-")" }.joined(separator: "\n")
        try text.write(to: directory.appendingPathComponent(artifact + ".txt"), atomically: true, encoding: .utf8)
        print("Production attached-sheet bitmap: \(directory.path)/\(artifact).png (\(bitmap.pixelsWide)x\(bitmap.pixelsHigh))")
    }

    private enum PresentationError: Error {
        case timeout(String)
        case invalidArtifactDirectory
        case unexpectedStoredSelection
        case unavailableCancelAction
    }

    @MainActor
    private final class Fixture {
        let suite = "MobileHelperPairingPresentationTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let configuration: OllamaEndpointConfiguration
        let initialSnapshot: OllamaEndpointConfiguration.Snapshot
        let coordinator: MobileHelperPairingCoordinator
        let window: NSWindow
        var selections: Int { selectionCount.value }
        private let selectionCount: SelectionCount

        init(scheme: String, title: String = "Connect Botsworth Helper") throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            // A fresh suite has no selected helper, so this public constructor only
            // constructs its store: it never queries, writes or deletes Keychain.
            guard defaults.string(forKey: "ollamaSelectedMobileHelperID") == nil else {
                // Fail before construction, rather than risk a Keychain read if
                // an inherited defaults domain unexpectedly provides a selection.
                throw PresentationError.unexpectedStoredSelection
            }
            configuration = try OllamaEndpointConfiguration(userDefaults: defaults,
                keychainService: suite + ".inert-keychain")
            initialSnapshot = configuration.snapshot()
            let count = SelectionCount()
            selectionCount = count
            coordinator = try MobileHelperPairingCoordinator(configuration: configuration,
                scheme: scheme, didSelect: { count.value += 1 })
            NSApplication.shared.finishLaunching()
            // Match the existing ChatUI test harness: enable SwiftUI's lazy AX
            // hierarchy in this process only. This neither requests nor bypasses
            // Accessibility/Screen Recording permissions and accesses no other app.
            let selector = NSSelectorFromString("accessibilitySetEnhancedUserInterfaceAttribute:")
            if NSApplication.shared.responds(to: selector) {
                _ = NSApplication.shared.perform(selector, with: NSNumber(value: true))
            }
            let host = NSHostingView(rootView: Text("Pairing presentation verification")
                .frame(width: 680, height: 520)
                .mobileHelperPairingPresentation(coordinator: coordinator, brandingTitle: title))
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.title = "Isolated pairing presentation verification"
            window.contentView = host
            window.center()
            window.makeKeyAndOrderFront(nil)
        }

        func close() {
            coordinator.cancel()
            coordinator.dismissError()
            if let sheet = window.attachedSheet {
                window.endSheet(sheet)
                sheet.orderOut(nil)
            }
            window.orderOut(nil)
            window.contentView = nil
            window.close()
            defaults.removePersistentDomain(forName: suite)
        }
    }

    @MainActor
    private final class SelectionCount {
        var value = 0
    }
}
#endif
