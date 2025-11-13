import SwiftUI
import OpenAI
import LangTools

// Extension to add Tools tab to ChatSettingsView
extension ChatSettingsView.SettingsTab {
    static var tools: Self { .init(rawValue: "Tools")! }
    
    // Update the allCases to include our new tab
    static var allCases: [ChatSettingsView.SettingsTab] {
        [.general, .systemPrompt, .advanced, .localModels, .tools]
    }
    
    // Add icon for tools tab
    var icon: String {
        switch self {
        case .general: return "gear"
        case .systemPrompt: return "text.bubble"
        case .advanced: return "slider.horizontal.3"
        case .localModels: return "cpu"
        case .tools: return "hammer.fill"
        default: return "gear" // Fallback
        }
    }
}

// Extension to add the tools settings view to ChatSettingsView
extension ChatSettingsView {
    var toolsSettingsView: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("AI Tools")
                .font(.title2)
                .fontWeight(.semibold)
            
            Divider()
            
            VStack(alignment: .leading, spacing: 12) {
                Text("Configure Tools")
                    .font(.headline)
                
                Text("Control which tools the AI assistant can use. Disable tools you don't need or enable only the ones you want.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 8)
                
                // Master switch for all tools
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Enable AI Tools", isOn: $viewModel.toolManager.toolsEnabled)
                            .toggleStyle(SwitchToggleStyle())
                            .padding(.vertical, 4)
                        
                        Text("When disabled, the AI will not use any tools to perform actions.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(8)
                }
                
                // Dynamic tool toggles based on available tools
                if viewModel.toolManager.toolsEnabled {
                    GroupBox {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                ForEach(Array(viewModel.toolManager.allToolConfigurations().enumerated()), id: \.element.id) { index, config in
                                    if index > 0 {
                                        Divider()
                                    }
                                    
                                    toolToggleRow(
                                        config: config,
                                        isOn: viewModel.toolManager.binding(for: config.id)
                                    )
                                }
                            }
                            .padding(8)
                        }
                        .frame(maxHeight: 300)
                    }
                } else {
                    Text("Enable AI Tools to configure individual tools")
                        .foregroundColor(.secondary)
                        .font(.callout)
                        .padding(.vertical, 8)
                }
                
                // Reset button
                Button(action: {
                    viewModel.toolManager.resetToDefaults()
                }) {
                    Text("Reset to Default Settings")
                }
                .buttonStyle(.bordered)
                .padding(.top, 8)
            }
        }
    }
    
    // Helper function to create a tool toggle row
    private func toolToggleRow(
        config: ToolConfiguration,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: config.iconName)
                .foregroundColor(.blue)
                .frame(width: 24, height: 24)
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(config.displayName)
                        .font(.headline)
                    
                    if config.isAgent {
                        Text("Agent")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.2))
                            .foregroundColor(.blue)
                            .cornerRadius(4)
                    }
                }
                
                Text(config.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Toggle("", isOn: isOn)
                .labelsHidden()
        }
    }
}

// Extension to add tool functionality to the ViewModel
extension ChatSettingsView.ViewModel {
    // Access to the tool manager
    var toolManager: ToolManager {
        return ToolManager.shared
    }
    
    // Update loadSettings to also load tool settings
    func loadToolSettings() {
        // No-op as ToolManager loads itself on init,
        // but keeping this method for consistency and future extensibility
    }
    
    // Update saveSettings to also save tool settings
    func saveToolSettings() {
        toolManager.saveSettings()
    }
}
