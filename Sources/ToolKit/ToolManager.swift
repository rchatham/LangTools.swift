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
// Minimal compat shim for non-Apple platforms (e.g. Linux / ChatCLI)
public protocol ObservableObject: AnyObject {}

@propertyWrapper
public struct Published<Value> {
    public var wrappedValue: Value
    public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
#endif

/// Manages tool configurations and their enabled/disabled states.
public class ToolManager: ObservableObject {

    // MARK: - Singleton

    /// Shared singleton backed by UserDefaults.standard.
    public static let shared = ToolManager()

    // MARK: - State

    #if canImport(Combine)
    @Published private var toolConfigurations: [String: ToolConfiguration] = [:]
    @Published public var toolsEnabled: Bool {
        didSet {
            if !toolsEnabled {
                for toolID in toolEnabledStates.keys {
                    toolEnabledStates[toolID] = false
                }
            }
            saveSettings()
        }
    }
    @Published private var toolEnabledStates: [String: Bool] = [:] {
        didSet { saveSettings() }
    }
    #else
    private var toolConfigurations: [String: ToolConfiguration] = [:]
    public var toolsEnabled: Bool {
        didSet {
            if !toolsEnabled {
                for toolID in toolEnabledStates.keys {
                    toolEnabledStates[toolID] = false
                }
            }
            saveSettings()
        }
    }
    private var toolEnabledStates: [String: Bool] = [:] {
        didSet { saveSettings() }
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
        self.toolsEnabled = defaults.bool(forKey: "toolsEnabled")

        if let data = defaults.data(forKey: "toolEnabledStates"),
           let states = try? JSONDecoder().decode([String: Bool].self, from: data) {
            self.toolEnabledStates = states
        }

        if !defaults.bool(forKey: "toolSettingsInitialized") {
            // Can't call resetToDefaults() yet — toolsEnabled setter triggers saveSettings
            // which requires self to be fully initialized. Set directly instead.
            defaults.set(true, forKey: "toolsEnabled")
            defaults.set(true, forKey: "toolSettingsInitialized")
            self.toolsEnabled = true
        }
    }

    // MARK: - Registration

    /// Register a single tool configuration.
    public func register(_ configuration: ToolConfiguration) {
        toolConfigurations[configuration.id] = configuration
        if toolEnabledStates[configuration.id] == nil {
            toolEnabledStates[configuration.id] = true
        }
    }

    /// Register multiple tool configurations.
    public func register(_ configurations: [ToolConfiguration]) {
        for config in configurations { register(config) }
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

    /// Persist current settings to UserDefaults.
    public func saveSettings() {
        defaults.set(toolsEnabled, forKey: "toolsEnabled")
        if let data = try? JSONEncoder().encode(toolEnabledStates) {
            defaults.set(data, forKey: "toolEnabledStates")
        }
    }

    /// Re-enable all registered tools and turn the master switch on.
    public func resetToDefaults() {
        toolsEnabled = true
        for id in toolConfigurations.keys {
            toolEnabledStates[id] = true
        }
        saveSettings()
    }

    // MARK: - Debug

    /// Print a summary of all registered tools and their enabled states.
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
}
