import Foundation
import SwiftUI
import Combine
import LangTools
import OpenAI

/// Manages tool configurations and their settings
public class ToolManager: ObservableObject {
    // Singleton instance
    public static let shared = ToolManager()
    
    // Published tool configurations
    @Published private var toolConfigurations: [String: ToolConfiguration] = [:]
    
    // Master switch to enable/disable all tools
    @Published public var toolsEnabled: Bool {
        didSet {
            // If tools are disabled, disable all individual tools
            if !toolsEnabled {
                for toolID in toolEnabledStates.keys {
                    toolEnabledStates[toolID] = false
                }
            }
            saveSettings()
        }
    }
    
    // Dictionary of tool enabled states, keyed by tool ID
    @Published private var toolEnabledStates: [String: Bool] = [:] {
        didSet {
            saveSettings()
        }
    }
    
    // Private initializer for singleton
    private init() {
        // Load master switch setting, defaulting to true
        self.toolsEnabled = UserDefaults.standard.bool(forKey: "toolsEnabled")
        
        // Load individual tool settings if they exist
        if let savedData = UserDefaults.standard.data(forKey: "toolEnabledStates"),
           let savedStates = try? JSONDecoder().decode([String: Bool].self, from: savedData) {
            self.toolEnabledStates = savedStates
        }
        
        // If no prior settings exist, initialize with defaults
        if !UserDefaults.standard.bool(forKey: "toolSettingsInitialized") {
            resetToDefaults()
            UserDefaults.standard.set(true, forKey: "toolSettingsInitialized")
        }
    }
    
    /// Register a tool configuration
    public func register(_ configuration: ToolConfiguration) {
        toolConfigurations[configuration.id] = configuration
        
        // Initialize enabled state if not already set
        if toolEnabledStates[configuration.id] == nil {
            toolEnabledStates[configuration.id] = true
        }
    }
    
    /// Register multiple tool configurations
    public func register(_ configurations: [ToolConfiguration]) {
        for config in configurations {
            register(config)
        }
    }
    
    /// Get all registered tool configurations
    public func allToolConfigurations() -> [ToolConfiguration] {
        return Array(toolConfigurations.values).sorted(by: { $0.displayName < $1.displayName })
    }
    
    /// Get a specific tool configuration by ID
    public func configuration(for id: String) -> ToolConfiguration? {
        return toolConfigurations[id]
    }
    
    /// Generate all tools as OpenAI.Tool objects
    public func generateTools() -> [OpenAI.Tool] {
        return allToolConfigurations().map { $0.toTool() }
    }
    
    /// Filter tools based on enabled settings
    public func filteredTools() -> [OpenAI.Tool]? {
        guard toolsEnabled else {
            return nil
        }
        
        return allToolConfigurations()
            .filter { isToolEnabled(id: $0.id) }
            .map { $0.toTool() }
    }
    
    /// Check if a specific tool is enabled
    public func isToolEnabled(id: String) -> Bool {
        guard toolsEnabled else { return false }
        return toolEnabledStates[id] ?? false
    }
    
    /// Get enabled state for a specific tool
    public subscript(id: String) -> Bool {
        get {
            return toolEnabledStates[id] ?? false
        }
        set {
            toolEnabledStates[id] = newValue
        }
    }
    
    /// Create a binding for a specific tool
    public func binding(for id: String) -> Binding<Bool> {
        Binding<Bool>(
            get: { self[id] },
            set: { self[id] = $0 }
        )
    }
    
    /// Save all settings to UserDefaults
    public func saveSettings() {
        UserDefaults.standard.set(toolsEnabled, forKey: "toolsEnabled")
        
        // Save tool states as JSON data
        if let data = try? JSONEncoder().encode(toolEnabledStates) {
            UserDefaults.standard.set(data, forKey: "toolEnabledStates")
        }
    }
    
    /// Reset all settings to default values
    public func resetToDefaults() {
        toolsEnabled = true
        
        // Enable all known tools
        for id in toolConfigurations.keys {
            toolEnabledStates[id] = true
        }
        
        saveSettings()
    }
    
    /// Log information about available tools (for debugging)
    public func logTools() {
        print("All registered tools:")
        for config in allToolConfigurations() {
            let isEnabled = isToolEnabled(id: config.id)
            print("- \(config.id) (\(config.displayName)): \(isEnabled ? \"Enabled\" : \"Disabled\")")
            print("  Description: \(config.description)")
            print("  Is Agent: \(config.isAgent ? \"Yes\" : \"No\")")
        }
        
        print("\nFiltered tools:")
        if let filtered = filteredTools() {
            for tool in filtered {
                print("- \(tool.name)")
            }
        } else {
            print("No filtered tools (master switch is off)")
        }
    }
}
