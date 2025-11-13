//
//  ChatSettingsView.swift
//
//  Created by Reid Chatham on 2/13/23.
//

import SwiftUI

public struct ChatSettingsView: View {
    @ObservedObject public var viewModel: ViewModel
    @State private var isEditingSystemMessage = false
    @State private var showingOllamaSettings = false
    #if os(macOS)
    @State private var selectedTab: SettingsTab = .general
    #endif
    
    public init(viewModel: ViewModel) {
        self.viewModel = viewModel
    }
    
    public var body: some View {
        #if os(macOS)
        macOSLayout
        #else
        mobileLayout
        #endif
    }
    
    #if os(macOS)
    private var macOSLayout: some View {
        NavigationSplitView {
            List(ChatSettingsView.SettingsTab.allCases, selection: $selectedTab) { tab in
                Label(tab.rawValue, systemImage: tab.icon)
                    .tag(tab)
            }
            .listStyle(.sidebar)
        } detail: {
            ScrollView {
                switch selectedTab {
                case .general:
                    generalSettingsView
                case .systemPrompt:
                    systemPromptSettingsView
                case .advanced:
                    advancedSettingsView
                case .localModels:
                    localModelsSettingsView
                case .tools:
                    toolsSettingsView
                }
            }
            .padding()
        }
        .frame(minWidth: 700, minHeight: 500)
        .onAppear {
            viewModel.loadSettings()
            viewModel.loadToolSettings()
        }
        .onDisappear {
            viewModel.saveSettings()
            viewModel.saveToolSettings()
        }
        .sheet(isPresented: $isEditingSystemMessage) {
            SystemMessageEditor(systemMessage: $viewModel.systemMessage)
        }
        .sheet(isPresented: $showingOllamaSettings) {
            OllamaSettingsView()
        }
    }
    #endif
    
    private var mobileLayout: some View {
        NavigationView {
            Form {
                activeModelSection
                systemMessageSection
                localModelsSection
                mobileToolsSection
                actionButtonsSection
            }
            .navigationTitle("Settings")
        }
        .onAppear {
            viewModel.loadSettings()
            viewModel.loadToolSettings()
        }
        .onDisappear {
            viewModel.saveSettings()
            viewModel.saveToolSettings()
        }
        .sheet(isPresented: $isEditingSystemMessage) {
            SystemMessageEditor(systemMessage: $viewModel.systemMessage)
        }
        .sheet(isPresented: $showingOllamaSettings) {
            OllamaSettingsView()
        }
    }
    
    private var generalSettingsView: some View {
        Form {
            activeModelSection
            systemMessageSection
            localModelsSection
            actionButtonsSection
        }
        .frame(maxWidth: .infinity)
    }
    
    private var systemPromptSettingsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("System Prompt")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("Customize the instructions that guide the AI assistant's behavior.")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            TextEditor(text: $viewModel.systemMessage)
                .font(.body)
                .frame(minHeight: 250)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.2))
                )
            
            HStack {
                Spacer()
                Button("Reset to Default") {
                    viewModel.systemMessage = "You are a helpful AI assistant."
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private var advancedSettingsView: some View {
        Form {
            Section(header: Text("Generation")) {
                Stepper(value: $viewModel.maxTokens, in: 256...8192, step: 256) {
                    Text("Max Tokens: \(viewModel.maxTokens)")
                }
                
                VStack(alignment: .leading) {
                    Text("Temperature: \(viewModel.temperature, specifier: "%.2f")")
                    Slider(value: $viewModel.temperature, in: 0...2, step: 0.01)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
    
    private var localModelsSettingsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Local Models")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("Manage Ollama local models available to the assistant.")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Button(action: {
                showingOllamaSettings = true
            }) {
                HStack {
                    Text("Manage Ollama Models")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.1))
                )
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private var activeModelSection: some View {
        Section(header: Text("Active Model")) {
            let _ = OllamaService.shared.availableModels
            
            Picker("Chat Models", selection: $viewModel.model) {
                ForEach(Model.chatModels, id: \.self) { model in
                    Text(model.rawValue).tag(model)
                }
            }
            .pickerStyle(.menu)
        }
    }
    
    private var systemMessageSection: some View {
        Section(header: Text("System Message")) {
            HStack {
                Text(viewModel.systemMessage)
                    .lineLimit(3)
                    .truncationMode(.tail)
                Spacer()
                Button("Edit") {
                    isEditingSystemMessage = true
                }
            }
        }
    }
    
    private var localModelsSection: some View {
        Section(header: Text("Local Models")) {
            Button(action: {
                showingOllamaSettings = true
            }) {
                HStack {
                    Text("Manage Ollama Models")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
        }
    }
    
    private var actionButtonsSection: some View {
        Section {
            Button("Save Settings") { viewModel.saveSettings() }
            Button("Update API Key") { viewModel.enterApiKey = true }
            Button("Clear messages", role: .destructive) {
                viewModel.clearMessages()
            }
        }
    }
    
    enum SettingsTab: String, CaseIterable, Identifiable {
        case general = "General"
        case systemPrompt = "System Prompt"
        case advanced = "Advanced"
        case localModels = "Local Models"
        case tools = "Tools"
        
        var id: String { self.rawValue }
    }
}

extension ChatSettingsView {
    @MainActor public class ViewModel: ObservableObject {
        @Published var apiKey = ""
        @Published var enterApiKey = false
        @Published var model: Model = UserDefaults.model
        @Published var maxTokens = UserDefaults.maxTokens
        @Published var temperature = UserDefaults.temperature
        @Published var deviceToken = UserDefaults.deviceToken
        @Published var systemMessage = UserDefaults.systemMessage
        
        let clearMessages: () -> Void
        
        public init(clearMessages: @escaping () -> Void) {
            self.clearMessages = clearMessages
        }
        
        func loadSettings() {
            model = UserDefaults.model
            maxTokens = UserDefaults.maxTokens
            temperature = UserDefaults.temperature
            systemMessage = UserDefaults.systemMessage
        }
        
        func saveSettings() {
            UserDefaults.model = model
            UserDefaults.maxTokens = maxTokens
            UserDefaults.temperature = temperature
            UserDefaults.systemMessage = systemMessage
        }
    }
}

struct SystemMessageEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var systemMessage: String
    @State private var editedMessage: String = ""
    
    var body: some View {
        NavigationView {
            VStack {
                TextEditor(text: $editedMessage)
                    .font(.body)
                    .padding()
                    .frame(maxHeight: .infinity)
            }
            .navigationTitle("Edit System Message")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        systemMessage = editedMessage
                        dismiss()
                    }
                }
            }
            .onAppear {
                editedMessage = systemMessage
            }
        }
    }
}
