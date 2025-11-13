import SwiftUI

extension ChatSettingsView {
    // Dynamic mobile tools section
    var mobileToolsSection: some View {
        Section(header: Text("AI Tools")) {
            Toggle("Enable AI Tools", isOn: $viewModel.toolManager.toolsEnabled)
                .toggleStyle(SwitchToggleStyle())
            
            if viewModel.toolManager.toolsEnabled {
                ForEach(viewModel.toolManager.allToolConfigurations(), id: \.id) { config in
                    HStack {
                        Image(systemName: config.iconName)
                            .foregroundColor(.blue)
                            .frame(width: 20)
                        
                        if config.isAgent {
                            HStack(spacing: 4) {
                                Text(config.displayName)
                                Text("Agent")
                                    .font(.caption)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color.blue.opacity(0.2))
                                    .foregroundColor(.blue)
                                    .cornerRadius(4)
                            }
                        } else {
                            Text(config.displayName)
                        }
                        
                        Spacer()
                        
                        Toggle("", isOn: viewModel.toolManager.binding(for: config.id))
                            .labelsHidden()
                    }
                }
            } else {
                Text("Enable AI Tools to configure individual tools")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Button("Reset Tool Settings") {
                viewModel.toolManager.resetToDefaults()
            }
        }
    }
}
