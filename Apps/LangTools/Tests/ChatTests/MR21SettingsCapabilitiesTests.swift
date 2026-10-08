import Agents
#if canImport(AppKit)
import AppKit
#endif
import ChatUI
import Foundation
import LangTools
import OpenAI
import SwiftUI
import ToolKit
import XCTest
@testable import Chat

@MainActor
final class MR21SettingsCapabilitiesTests: XCTestCase {
    /// Botsworth now honors both host capabilities (agent-model override and
    /// advanced generation) upstream, so its host uses the defaults. The
    /// false/false configuration remains covered as a generic opt-out host.
    private let optOutSettings = ChatSettingsView.SupportedSettings(
        agentModelOverride: false, advancedGeneration: false
    )

    func testDefaultHostKeepsSampleCapabilitiesAndOriginalInitializerSignature() {
        let preferences = MR21PreferenceSnapshot()
        defer { preferences.restore() }
        let makeView: (ChatSettingsView.ViewModel) -> ChatSettingsView = ChatSettingsView.init(viewModel:)
        let model = ChatSettingsView.ViewModel(clearMessages: {})
        let view = makeView(model)
        XCTAssertTrue(view.supportedSettings.agentModelOverride)
        XCTAssertTrue(view.supportedSettings.advancedGeneration)
        XCTAssertEqual(view.supportedSettings.generationCapabilities(for: .openAI(.gpt4o)), Model.openAI(.gpt4o).generationCapabilities)
    }

    func testOptOutHostHidesOnlyNewGenerationControlsWithoutChangingSavedValues() throws {
        let preferences = MR21PreferenceSnapshot()
        defer { preferences.restore() }
        let original = Model.openAI(.gpt4o).generationCapabilities
        let filtered = optOutSettings.generationCapabilities(for: .openAI(.gpt4o))
        XCTAssertEqual(filtered.maximumOutputField, original.maximumOutputField)
        XCTAssertEqual(filtered.maximumOutputTokenBound, original.maximumOutputTokenBound)
        XCTAssertEqual(filtered.supportsTemperature, original.supportsTemperature)
        XCTAssertEqual(filtered.contextWindowTokens, original.contextWindowTokens)
        XCTAssertFalse(filtered.supportsTopP)
        XCTAssertFalse(filtered.supportsTopK)
        XCTAssertFalse(filtered.supportsFrequencyPenalty)
        XCTAssertFalse(filtered.supportsPresencePenalty)
        XCTAssertFalse(filtered.supportsSeed)
        XCTAssertFalse(filtered.supportsStop)
        let ollama = try XCTUnwrap(Model(rawValue: "ollama/synthetic-model"))
        XCTAssertTrue(ChatSettingsView.SupportedSettings().generationCapabilities(for: ollama).supportsTopK)
        XCTAssertFalse(optOutSettings.generationCapabilities(for: ollama).supportsTopK)
        let settings = try ChatGenerationSettings(temperature: 0.4, topP: 0.8, seed: 21)
        let store = MR21GenerationStore(settings: settings)
        let model = ChatSettingsView.ViewModel(clearMessages: {}, generationSettingsStore: store)
        model.generationSettings = settings
        _ = ChatSettingsView(viewModel: model, supportedSettings: optOutSettings)
        XCTAssertEqual(model.generationSettings, settings)
        XCTAssertEqual(store.settings, settings)
        XCTAssertEqual(store.saveCount, 0)
    }

    #if canImport(AppKit)
    func testNativeSettingsVisibilityInteractionsAndSnapshots() throws {
        NSApplication.shared.finishLaunching()
        let enhanced = NSSelectorFromString("accessibilitySetEnhancedUserInterfaceAttribute:")
        guard NSApplication.shared.responds(to: enhanced) else {
            throw XCTSkip("In-process SwiftUI accessibility hierarchy is unavailable")
        }
        _ = NSApplication.shared.perform(enhanced, with: NSNumber(value: true))
        let preferences = MR21PreferenceSnapshot()
        let oldToolsEnabled = ToolManager.shared.toolsEnabled
        let oldRich = ToolSettings.shared.richContentEnabled
        let oldHistory = ToolSettings.shared.keepsToolCallsInHistory
        let oldRetry = ToolSettings.shared.autoRetryFailedTools
        let oldTimeout = ToolSettings.shared.toolTimeoutSeconds
        let oldAgentModel = ToolSettings.shared.agentModelOverride
        defer {
            ToolManager.shared.toolsEnabled = oldToolsEnabled
            ToolSettings.shared.richContentEnabled = oldRich
            ToolSettings.shared.keepsToolCallsInHistory = oldHistory
            ToolSettings.shared.autoRetryFailedTools = oldRetry
            ToolSettings.shared.toolTimeoutSeconds = oldTimeout
            ToolSettings.shared.agentModelOverride = oldAgentModel
            preferences.restore()
        }
        // A deterministic catalog avoids direct-provider access prompts, Keychain
        // writes and live model discovery. Host support is independent of catalog.
        UserDefaults.model = .openAI(.gpt4o)
        ToolManager.shared.toolsEnabled = false
        ToolSettings.shared.richContentEnabled = true
        ToolSettings.shared.keepsToolCallsInHistory = true
        ToolSettings.shared.autoRetryFailedTools = false
        ToolSettings.shared.toolTimeoutSeconds = nil
        ToolSettings.shared.agentModelOverride = nil
        let output = ProcessInfo.processInfo.environment["MR21_SETTINGS_ARTIFACT_DIR"]
        for (name, support) in [("botsworth", ChatSettingsView.SupportedSettings()), ("optout", optOutSettings)] {
            for width in [700, 1000] {
                let generation = MR21GenerationStore(settings: try ChatGenerationSettings(
                    maxOutputTokens: 2_048, temperature: 0.4, topP: 0.8, seed: 21
                ))
                let model = ChatSettingsView.ViewModel(
                    clearMessages: {},
                    modelSource: ChatModelSource(state: .ready([.openAI(.gpt4o)])),
                    generationSettingsStore: generation,
                    conversationSettingsStore: MR21ConversationStore()
                )
                let root = ChatSettingsView(viewModel: model, supportedSettings: support)
                let host = NSHostingView(rootView: root)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 1000), styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = host
                window.makeKeyAndOrderFront(nil)
                defer { window.orderOut(nil) }
                settleLayout(host)

                try press(identifier: "settings.ToolsTab", in: host)
                var text = accessibleText(in: host)
                XCTAssertTrue(text.contains("Tool Execution"), text)
                XCTAssertTrue(text.contains("Max Iterations"), "Restored iteration cap control is visible in every host: \(text)")
                XCTAssertEqual(text.contains("Agent Model Override"), support.agentModelOverride, text)
                if let output { try snapshot(host, directory: output, name: "mr21-settings-\(name)-tools-\(width)") }

                try press(identifier: "settings.AdvancedTab", in: host)
                text = accessibleText(in: host)
                XCTAssertTrue(text.contains("Temperature"), text)
                XCTAssertTrue(text.contains("Max Tokens"), text)
                for label in ["Top P", "Frequency Penalty", "Presence Penalty", "Seed", "Stop Sequences"] {
                    XCTAssertEqual(text.contains(label), support.advancedGeneration, "\(label): \(text)")
                }
                if let output { try snapshot(host, directory: output, name: "mr21-settings-\(name)-advanced-\(width)") }
                try press(label: "Reset to Automatic", in: host)
                XCTAssertNil(model.generationSettings.temperature)
                XCTAssertNil(model.generationSettings.maxOutputTokens)
                if support.advancedGeneration {
                    XCTAssertEqual(model.generationSettings, .automatic)
                } else {
                    XCTAssertEqual(model.generationSettings.topP, 0.8, "Reset must preserve hidden host preferences")
                    XCTAssertEqual(model.generationSettings.seed, 21)
                }
                try press(label: "Save Settings", in: host)
                XCTAssertEqual(generation.settings, model.generationSettings)
                XCTAssertGreaterThan(generation.saveCount, 0)
                window.orderOut(nil)
                window.contentView = nil
                // Drain SwiftUI lifecycle saves before restoring shared preferences.
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
        }
    }

    private func settleLayout(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        host.layoutSubtreeIfNeeded()
    }

    // SwiftUI accessibility objects expose Objective-C selectors but do not all
    // conform to NSAccessibilityProtocol. Use the same in-process seam as ChatUI.
    private func accessibilityAttribute(_ name: String, from object: NSObject) -> Any? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }

    private func accessibleNodes(in host: NSView) -> [NSObject] {
        var nodes: [NSObject] = []
        var visited = Set<ObjectIdentifier>()
        func visit(_ object: Any) {
            guard let node = object as? NSObject else { return }
            guard visited.insert(ObjectIdentifier(node)).inserted else { return }
            nodes.append(node)
            for attribute in ["accessibilityChildren", "accessibilityRows", "accessibilityVisibleChildren", "accessibilityContents"] {
                for child in accessibilityAttribute(attribute, from: node) as? [Any] ?? [] { visit(child) }
            }
            if let view = node as? NSView { for child in view.subviews { visit(child) } }
        }
        visit(host)
        return nodes
    }

    private func accessibleText(in host: NSView) -> String {
        accessibleNodes(in: host).flatMap { node in
            ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].compactMap {
                accessibilityAttribute($0, from: node) as? String
            }
        }.joined(separator: "\n")
    }

    private func press(identifier: String? = nil, label: String? = nil, in host: NSView) throws {
        let node = try XCTUnwrap(accessibleNodes(in: host).first { node in
            if let identifier { return accessibilityAttribute("accessibilityIdentifier", from: node) as? String == identifier }
            return accessibilityAttribute("accessibilityLabel", from: node) as? String == label
                || accessibilityAttribute("accessibilityTitle", from: node) as? String == label
        }, "Missing settings control: \(identifier ?? label ?? "unknown")\n\(accessibleText(in: host))")
        let selector = NSSelectorFromString("accessibilityPerformPress")
        XCTAssertTrue(node.responds(to: selector))
        _ = node.perform(selector)
        settleLayout(host)
    }

    private func snapshot(_ host: NSView, directory: String, name: String) throws {
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: url.appendingPathComponent(name).appendingPathExtension("png"))
        try accessibleText(in: host).write(to: url.appendingPathComponent(name).appendingPathExtension("txt"), atomically: true, encoding: .utf8)
    }
    #endif
}

private final class MR21GenerationStore: ChatGenerationSettingsStoring {
    var settings: ChatGenerationSettings
    var saveCount = 0
    init(settings: ChatGenerationSettings = .automatic) { self.settings = settings }
    func load() -> ChatGenerationSettings { settings }
    func save(_ settings: ChatGenerationSettings) { self.settings = settings; saveCount += 1 }
    func reset() { settings = .automatic }
}

private final class MR21ConversationStore: ChatConversationSettingsStoring {
    func load() -> ChatConversationSettings { .default }
    func save(_ settings: ChatConversationSettings) {}
    func reset() {}
}

/// Restore only changed keys from a complete snapshot, including missing keys.
/// This avoids persisting untouched global-domain defaults into the app domain.
private struct MR21PreferenceSnapshot {
    private let original = UserDefaults.standard.dictionaryRepresentation()
    func restore() {
        let defaults = UserDefaults.standard
        let current = defaults.dictionaryRepresentation()
        for key in Set(original.keys).union(current.keys) {
            let before = original[key] as? NSObject
            let after = current[key] as? NSObject
            guard before != after else { continue }
            if let value = original[key] { defaults.set(value, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
    }
}
