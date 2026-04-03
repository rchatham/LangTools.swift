import Foundation
import LangTools
import OpenAI

#if canImport(Combine)
import Combine
#endif

#if canImport(SwiftUI)
import SwiftUI
#endif

#if !canImport(Combine)
// Minimal compat shim for non-Apple platforms (e.g. Linux / ChatCLI).
// Kept internal to avoid conflicting with any consumer that conditionally
// imports Combine — the types are only needed to satisfy the ToolManager
// class definition and are not part of the public API on non-Combine platforms.
internal protocol ObservableObject: AnyObject {}

@propertyWrapper
internal struct Published<Value> {
    internal var wrappedValue: Value
    /// projectedValue stub — no change notifications on non-Combine platforms.
    internal var projectedValue: Value { wrappedValue }
    internal init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
#endif

// MARK: - UserDefaults keys (namespaced to avoid collisions)
private enum Keys {
    static let toolsEnabled        = "ToolKit.toolsEnabled"
    static let toolEnabledStates   = "ToolKit.toolEnabledStates"
    static let toolSettingsInit    = "ToolKit.toolSettingsInitialized"
}

/// Manages tool configurations and their enabled/disabled states.
///
/// All mutations must happen on the main thread (@MainActor). The singleton is
/// safe to read from any thread, but mutations (register, subscript set, etc.)
/// should be performed on the main actor.
@MainActor
public class ToolManager: ObservableObject {

    // MARK: - Singleton

    /// Shared singleton backed by UserDefaults.standard.
    public static let shared = ToolManager()

    // MARK: - State

    #if canImport(Combine)
    @Published private var toolConfigurations: [String: ToolConfiguration] = [:]

    /// Master switch. Setting this does NOT erase individual tool states —
    /// `isToolEnabled(id:)` and `filteredTools()` already gate on this flag.
    @Published public var toolsEnabled: Bool {
        didSet { _persistAllSettings() }
    }

    /// Per-tool enabled states.
    /// Use `_setStates(_:)` for bulk mutations — it performs a single persist.
    @Published private var toolEnabledStates: [String: Bool] = [:] {
        didSet { _persistAllSettings() }
    }
    #else
    private var toolConfigurations: [String: ToolConfiguration] = [:]

    public var toolsEnabled: Bool {
        didSet { _persistAllSettings() }
    }

    private var toolEnabledStates: [String: Bool] = [:] {
        didSet { _persistAllSettings() }
    }
    #endif

    // MARK: - UserDefaults

    private let defaults: UserDefaults

    // MARK: - Init

    /// Singleton initializer using UserDefaults.standard.
    private convenience init() {
        self.init(defaults: .standard)
    }

    /// Designated initializer — injectable for testing.
    public init(defaults: UserDefaults) {
        self.defaults = defaults

        // Use object(forKey:) so that absence → true (not the Bool default of false).
        self.toolsEnabled = defaults.object(forKey: Keys.toolsEnabled) as? Bool ?? true

        if let data = defaults.data(forKey: Keys.toolEnabledStates),
           let states = try? JSONDecoder().decode([String: Bool].self, from: data) {
            self.toolEnabledStates = states
        }

        if !defaults.bool(forKey: Keys.toolSettingsInit) {
            defaults.set(true, forKey: Keys.toolsEnabled)
            defaults.set(true, forKey: Keys.toolSettingsInit)
            self.toolsEnabled = true
        }
    }

    // MARK: - Registration

    /// Register a single tool configuration (one UserDefaults write).
    public func register(_ configuration: ToolConfiguration) {
        register([configuration])
    }

    /// Register multiple tool configurations in a single batch (one UserDefaults write).
    public func register(_ configurations: [ToolConfiguration]) {
        var updatedStates = toolEnabledStates
        for config in configurations {
            toolConfigurations[config.id] = config
            if updatedStates[config.id] == nil {
                updatedStates[config.id] = true
            }
        }
        // Assign once so toolEnabledStates.didSet fires only one _persistAllSettings().
        _setStates(updatedStates)
    }

    // MARK: - Querying

    /// All registered configurations sorted by display name.
    public func allToolConfigurations() -> [ToolConfiguration] {
        Array(toolConfigurations.values).sorted { $0.displayName < $1.displayName }
    }

    /// A specific configuration by its id.
    public func configuration(for id: String) -> ToolConfiguration? {
        toolConfigurations[id]
    }

    /// All registered tools as OpenAI.Tool objects (ignores enabled states).
    public func generateTools() -> [OpenAI.Tool] {
        allToolConfigurations().map { $0.toTool() }
    }

    /// Enabled tools as OpenAI.Tool objects, or nil when the master switch is off.
    public func filteredTools() -> [OpenAI.Tool]? {
        guard toolsEnabled else { return nil }
        return allToolConfigurations()
            .filter { isToolEnabled(id: $0.id) }
            .map { $0.toTool() }
    }

    /// Whether a specific tool is enabled (respects the master switch).
    ///
    /// Returns `false` for unregistered tool ids. This is a deliberate change from
    /// the previous `ToolSettings.isToolEnabled(name:)` which defaulted unknown
    /// tools to `true`. Defaulting to `false` is safer — it prevents silently
    /// enabling tools that were never registered — but callers should ensure all
    /// tools are registered before querying their state.
    public func isToolEnabled(id: String) -> Bool {
        guard toolsEnabled else { return false }
        return toolEnabledStates[id] ?? false
    }

    /// Get or set the enabled state of a tool by id.
    public subscript(id: String) -> Bool {
        get { toolEnabledStates[id] ?? false }
        set { toolEnabledStates[id] = newValue }
    }

    // MARK: - SwiftUI support

#if canImport(SwiftUI)
    /// A SwiftUI Binding for a tool's enabled state.
    public func binding(for id: String) -> Binding<Bool> {
        Binding<Bool>(
            get: { self[id] },
            set: { self[id] = $0 }
        )
    }
#endif

    // MARK: - Persistence

    /// Persist current settings to UserDefaults. Called automatically by didSet observers.
    public func saveSettings() {
        _persistAllSettings()
    }

    /// Re-enable all registered tools and turn the master switch on.
    ///
    /// Replaces `toolEnabledStates` with a fresh dict keyed only to currently-registered
    /// tools, discarding any stale persisted keys from tools that are no longer registered.
    /// Performs exactly two UserDefaults writes: one from `toolsEnabled.didSet` and one
    /// from `_setStates` (via `toolEnabledStates.didSet`).
    public func resetToDefaults() {
        toolsEnabled = true
        // Build a clean state dict from the current registration set only —
        // this also removes stale keys for tools that are no longer registered.
        let fresh = Dictionary(uniqueKeysWithValues: toolConfigurations.keys.map { ($0, true) })
        _setStates(fresh)
    }

    // MARK: - Debug

    /// Print a summary of all registered tools and their enabled states.
    /// Gated to debug builds to avoid polluting production console output.
    #if DEBUG
    public func logTools() {
        print("All registered tools:")
        for config in allToolConfigurations() {
            let enabled = isToolEnabled(id: config.id)
            print("- \(config.id) (\(config.displayName)): \(enabled ? "Enabled" : "Disabled")")
            print("  Description: \(config.description)")
            print("  Is Agent: \(config.isAgent ? "Yes" : "No")")
        }
        print("\nFiltered tools:")
        if let filtered = filteredTools() {
            for tool in filtered { print("- \(tool.name)") }
        } else {
            print("No filtered tools (master switch is off)")
        }
    }
    #endif

    // MARK: - Private helpers

    /// Replace `toolEnabledStates` in one assignment so `didSet` fires exactly once,
    /// triggering a single `_persistAllSettings()` call.
    private func _setStates(_ states: [String: Bool]) {
        toolEnabledStates = states
    }

    /// Single point-of-truth for all UserDefaults writes.
    private func _persistAllSettings() {
        defaults.set(toolsEnabled, forKey: Keys.toolsEnabled)
        if let data = try? JSONEncoder().encode(toolEnabledStates) {
            defaults.set(data, forKey: Keys.toolEnabledStates)
        }
    }
}
