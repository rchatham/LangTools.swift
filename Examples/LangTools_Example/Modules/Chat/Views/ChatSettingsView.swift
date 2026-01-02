//
//  ChatSettingsView.swift
//

import SwiftUI

public struct ChatSettingsView: View {
    @ObservedObject public var viewModel: ViewModel
    @State private var isEditingSystemMessage = false
    @State private var showingOllamaSettings = false
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedTab: SettingsTab = .general

    enum SettingsTab: String, CaseIterable, Identifiable {
        case general = "General"
        case systemPrompt = "System Prompt"
        case advanced = "Advanced"
        case localModels = "Local Models"
        case tools = "Tools"

        var id: String { self.rawValue }

        var icon: String {
            switch self {
            case .general: return "gear"
            case .systemPrompt: return "text.bubble"
            case .advanced: return "slider.horizontal.3"
            case .localModels: return "cpu"
            case .tools: return "hammer.fill"
            }
        }
    }

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

    // macOS-specific layout
    private var macOSLayout: some View {
        HStack(spacing: 0) {
            // Sidebar
            VStack {
                List {
                    ForEach(SettingsTab.allCases) { tab in
                        Button(action: {
                            selectedTab = tab
                        }) {
                            HStack {
                                Image(systemName: tab.icon)
                                    .frame(width: 24)
                                Text(tab.rawValue)
                                Spacer()
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .padding(.vertical, 4)
                        .background(selectedTab == tab ? (colorScheme == .dark ? Color.gray.opacity(0.3) : Color.blue.opacity(0.1)) : Color.clear)
                        .cornerRadius(6)
                    }
                }
                .listStyle(PlainListStyle())

                Spacer()
            }
            .frame(width: 200)
            .padding(.vertical)
            #if os(macOS)
            .background(colorScheme == .dark ? Color(.controlBackgroundColor).opacity(0.5) : Color(.windowBackgroundColor).opacity(0.5))
            #endif

            // Divider
            Divider()

            // Content area
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
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

                    Spacer()

                    Divider()

                    actionsSection
                        .padding(.vertical, 8)
                }
                .padding(30)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            #if os(macOS)
            .background(colorScheme == .dark ? Color(.windowBackgroundColor) : Color(.textBackgroundColor))
            #endif
        }
        .frame(minWidth: 700, minHeight: 500)
        .onAppear { viewModel.loadSettings() }
        .onDisappear {
            viewModel.saveSettings()
            viewModel.saveToolSettings()
        }
        .sheet(isPresented: $isEditingSystemMessage) {
            SystemMessageEditor(systemMessage: $viewModel.systemMessage)
        }
        #if !os(watchOS) && !os(tvOS)
        .sheet(isPresented: $showingOllamaSettings) {
            OllamaSettingsView()
        }
        #endif
        .enterAPIKeyAlert(isPresented: $viewModel.enterApiKey, apiKey: $viewModel.apiKeyInputText)
    }

    // iOS/iPadOS layout (unchanged)
    private var mobileLayout: some View {
        Form {
            Section(header: Text("Active Model")) {
                #if !os(watchOS)
                // Force refresh when OllamaService updates its models
                // Note: OllamaService might not be available on all platforms
                #endif

                Picker("Chat Models", selection: $viewModel.model) {
                    ForEach(Model.chatModels, id: \.self) { model in
                        Text(model.rawValue).tag(model)
                    }
                }
                .pickerStyle(.menu)
            }

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

            #if !os(watchOS) && !os(tvOS)
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
            #endif

            Button("Save Settings") { viewModel.saveSettings() }
            Button("Update API Key") { viewModel.enterApiKey = true }
            Button("Clear messages", role: .destructive) { viewModel.clearMessages() }

            Section(header: Text("AI Tools")) {
                Toggle("Enable AI Tools", isOn: $viewModel.toolSettings.toolsEnabled)
                    .toggleStyle(SwitchToggleStyle())

                if viewModel.toolSettings.toolsEnabled {
                    Toggle("Calendar", isOn: $viewModel.toolSettings.calendarToolEnabled)
                    Toggle("Reminders", isOn: $viewModel.toolSettings.remindersToolEnabled)
                    Toggle("Research", isOn: $viewModel.toolSettings.researchToolEnabled)
                    Toggle("Maps", isOn: $viewModel.toolSettings.mapsToolEnabled)
                    Toggle("Contacts", isOn: $viewModel.toolSettings.contactsToolEnabled)
                    Toggle("Weather", isOn: $viewModel.toolSettings.weatherToolEnabled)
                    Toggle("Files", isOn: $viewModel.toolSettings.filesToolEnabled)
                } else {
                    Text("Enable AI Tools to configure individual tools")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Button("Reset Tool Settings") {
                    viewModel.toolSettings.resetToDefaults()
                }
            }

            Section(header: Text("Display")) {
                Toggle("Rich Content Cards", isOn: $viewModel.toolSettings.richContentEnabled)
                Text("Display weather, contacts, and events as visual cards below messages")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(header: Text("Voice Input")) {
                Toggle("Enable Voice Input", isOn: $viewModel.toolSettings.voiceInputEnabled)
                    .toggleStyle(SwitchToggleStyle())

                if viewModel.toolSettings.voiceInputEnabled {
                    Picker("Speech Provider", selection: $viewModel.toolSettings.sttProvider) {
                        ForEach(STTProvider.allCases, id: \.self) { provider in
                            Text(provider.rawValue).tag(provider)
                        }
                    }
                    .onChange(of: viewModel.toolSettings.sttProvider) { _, newValue in
                        // Trigger preload when WhisperKit is selected
                        if newValue == .whisperKit {
                            viewModel.preloadWhisperKit()
                        }
                    }

                    // Show WhisperKit-specific options
                    if viewModel.toolSettings.sttProvider == .whisperKit {
                        HStack {
                            if viewModel.whisperKitIsLoading {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(viewModel.whisperKitStatusDescription)
                                .font(.caption)
                                .foregroundColor(viewModel.whisperKitIsLoading ? .secondary : .green)
                        }

                        Picker("Model Size", selection: $viewModel.toolSettings.whisperKitModelSize) {
                            ForEach(WhisperKitModelSize.allCases, id: \.self) { modelSize in
                                Text(modelSize.displayName).tag(modelSize)
                            }
                        }
                        .onChange(of: viewModel.toolSettings.whisperKitModelSize) { _, _ in
                            viewModel.preloadWhisperKit()
                        }

                        Text("Larger models are more accurate but slower")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Text("Apple Speech: On-device, private\nOpenAI Whisper: Cloud, high accuracy\nWhisperKit: On-device ML")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Toggle("Replace send button", isOn: $viewModel.toolSettings.voiceButtonReplaceSend)

                    Text("Show microphone in place of send button when empty")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Picker("Language", selection: $viewModel.toolSettings.sttLanguage) {
                        Text("Auto-detect").tag("auto")
                        Text("English").tag("en")
                        Text("Spanish").tag("es")
                        Text("French").tag("fr")
                        Text("German").tag("de")
                        Text("Italian").tag("it")
                        Text("Portuguese").tag("pt")
                        Text("Chinese").tag("zh")
                        Text("Japanese").tag("ja")
                        Text("Korean").tag("ko")
                        Text("Arabic").tag("ar")
                        Text("Russian").tag("ru")
                        Text("Hindi").tag("hi")
                    }

                    Text("Select the language you'll be speaking")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Toggle("Auto-stop on silence", isOn: $viewModel.toolSettings.autoStopOnSilence)

                    if viewModel.toolSettings.autoStopOnSilence {
                        Picker("Silence timeout", selection: $viewModel.toolSettings.silenceTimeoutSeconds) {
                            Text("1 second").tag(1.0)
                            Text("1.5 seconds").tag(1.5)
                            Text("2 seconds").tag(2.0)
                            Text("3 seconds").tag(3.0)
                            Text("5 seconds").tag(5.0)
                        }

                        Text("Stop recording after this duration of silence")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Toggle("Real-time transcription", isOn: $viewModel.toolSettings.streamingTranscriptionEnabled)

                    Text("Show transcribed text as you speak")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if viewModel.toolSettings.streamingTranscriptionEnabled &&
                       viewModel.toolSettings.sttProvider == .openAIWhisper {

                        Toggle("Simulated streaming", isOn: $viewModel.toolSettings.enableOpenAISimulatedStreaming)

                        if viewModel.toolSettings.enableOpenAISimulatedStreaming {
                            Picker("Update interval", selection: $viewModel.toolSettings.streamingChunkIntervalSeconds) {
                                Text("2 seconds").tag(2.0)
                                Text("3 seconds").tag(3.0)
                                Text("5 seconds").tag(5.0)
                            }

                            Text("More frequent updates = more API calls")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }
                }
            }
        }
        .navigationTitle("Settings")
        .onAppear { viewModel.loadSettings() }
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
        .enterAPIKeyAlert(isPresented: $viewModel.enterApiKey, apiKey: $viewModel.apiKeyInputText)
    }

    // MARK: - macOS Detail Views

    private var generalSettingsView: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Model Selection")
                .font(.title2)
                .fontWeight(.semibold)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text("Active Model")
                    .font(.headline)

                #if !os(watchOS) && !os(tvOS)
                // Force refresh when OllamaService updates its models
                // Note: OllamaService might not be available on all platforms
                #endif

                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        Picker("", selection: $viewModel.model) {
                            ForEach(Model.chatModels, id: \.self) { model in
                                Text(model.rawValue).tag(model)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 400)

                        Divider()

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Model Info")
                                .font(.headline)
                                .foregroundColor(.secondary)

                            Text(modelDescription(for: viewModel.model))
                                .font(.body)
                        }
                    }
                    .padding(8)
                }

                Button("Update API Key") { viewModel.enterApiKey = true }
                .buttonStyle(.bordered)
                .padding(.top, 8)
            }

            Divider()
                .padding(.vertical, 8)

            // Voice Input Section
            Text("Voice Input")
                .font(.title2)
                .fontWeight(.semibold)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Voice Input", isOn: $viewModel.toolSettings.voiceInputEnabled)
                            .toggleStyle(SwitchToggleStyle())
                            .padding(.vertical, 4)

                        Text("Enable the microphone button to dictate messages using speech-to-text.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if viewModel.toolSettings.voiceInputEnabled {
                            Divider()

                            Text("Speech Provider")
                                .font(.headline)

                            Picker("", selection: $viewModel.toolSettings.sttProvider) {
                                ForEach(STTProvider.allCases, id: \.self) { provider in
                                    Text(provider.rawValue).tag(provider)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 400)
                            .onChange(of: viewModel.toolSettings.sttProvider) { _, newValue in
                                if newValue == .whisperKit {
                                    viewModel.preloadWhisperKit()
                                }
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                providerDescription(for: viewModel.toolSettings.sttProvider)

                                // Show WhisperKit-specific options
                                if viewModel.toolSettings.sttProvider == .whisperKit {
                                    HStack(spacing: 8) {
                                        if viewModel.whisperKitIsLoading {
                                            ProgressView()
                                                .controlSize(.small)
                                        }
                                        Text(viewModel.whisperKitStatusDescription)
                                            .foregroundColor(viewModel.whisperKitIsLoading ? .secondary : .green)
                                    }
                                    .padding(.top, 4)

                                    Divider()
                                        .padding(.vertical, 4)

                                    Text("Model Size")
                                        .font(.headline)
                                        .foregroundColor(.primary)

                                    Picker("", selection: $viewModel.toolSettings.whisperKitModelSize) {
                                        ForEach(WhisperKitModelSize.allCases, id: \.self) { modelSize in
                                            Text(modelSize.displayName).tag(modelSize)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .frame(maxWidth: 200)
                                    .onChange(of: viewModel.toolSettings.whisperKitModelSize) { _, _ in
                                        // Reload WhisperKit with new model
                                        viewModel.preloadWhisperKit()
                                    }

                                    Text("Larger models are more accurate but slower and use more memory.")
                                        .foregroundColor(.secondary)
                                }
                            }
                            .font(.caption)
                            .foregroundColor(.secondary)

                            Divider()

                            Toggle("Replace send button", isOn: $viewModel.toolSettings.voiceButtonReplaceSend)
                                .toggleStyle(SwitchToggleStyle())

                            Text("Show microphone button in place of send button when text field is empty")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Divider()

                            Text("Language")
                                .font(.headline)

                            Picker("", selection: $viewModel.toolSettings.sttLanguage) {
                                Text("Auto-detect").tag("auto")
                                Divider()
                                Text("English").tag("en")
                                Text("Spanish").tag("es")
                                Text("French").tag("fr")
                                Text("German").tag("de")
                                Text("Italian").tag("it")
                                Text("Portuguese").tag("pt")
                                Text("Chinese").tag("zh")
                                Text("Japanese").tag("ja")
                                Text("Korean").tag("ko")
                                Text("Arabic").tag("ar")
                                Text("Russian").tag("ru")
                                Text("Hindi").tag("hi")
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: 200)

                            Text("Select the language you'll be speaking. Auto-detect works best for most cases.")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Divider()

                            Text("Auto-Stop on Silence")
                                .font(.headline)

                            Toggle("Enable auto-stop", isOn: $viewModel.toolSettings.autoStopOnSilence)
                                .toggleStyle(SwitchToggleStyle())

                            if viewModel.toolSettings.autoStopOnSilence {
                                HStack {
                                    Text("Silence timeout:")
                                    Picker("", selection: $viewModel.toolSettings.silenceTimeoutSeconds) {
                                        Text("1 second").tag(1.0)
                                        Text("1.5 seconds").tag(1.5)
                                        Text("2 seconds").tag(2.0)
                                        Text("3 seconds").tag(3.0)
                                        Text("5 seconds").tag(5.0)
                                    }
                                    .pickerStyle(.menu)
                                    .frame(maxWidth: 150)
                                }
                            }

                            Text("Automatically stop recording when no speech is detected for the specified duration.")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Divider()

                            Text("Real-time Transcription")
                                .font(.headline)

                            Toggle("Show partial results", isOn: $viewModel.toolSettings.streamingTranscriptionEnabled)
                                .toggleStyle(SwitchToggleStyle())

                            Text("Display transcribed text as you speak, before recording is complete.")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            if viewModel.toolSettings.streamingTranscriptionEnabled &&
                               viewModel.toolSettings.sttProvider == .openAIWhisper {

                                Toggle("Simulated streaming", isOn: $viewModel.toolSettings.enableOpenAISimulatedStreaming)
                                    .toggleStyle(SwitchToggleStyle())

                                if viewModel.toolSettings.enableOpenAISimulatedStreaming {
                                    HStack {
                                        Text("Update interval:")
                                        Picker("", selection: $viewModel.toolSettings.streamingChunkIntervalSeconds) {
                                            Text("2 seconds").tag(2.0)
                                            Text("3 seconds").tag(3.0)
                                            Text("5 seconds").tag(5.0)
                                        }
                                        .pickerStyle(.menu)
                                        .frame(maxWidth: 150)
                                    }

                                    HStack(spacing: 4) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundColor(.orange)
                                        Text("More frequent updates = more API calls and costs")
                                            .foregroundColor(.orange)
                                    }
                                    .font(.caption)
                                }

                                Text("OpenAI's API doesn't support native streaming. Simulated streaming sends audio chunks periodically for partial results.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(8)
                }
            }
        }
    }

    private var systemPromptSettingsView: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("System Prompt")
                .font(.title2)
                .fontWeight(.semibold)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text("Instructions for the AI")
                    .font(.headline)

                Text("The system prompt provides instructions to the AI that guide its behavior. This message sets the context for how the AI should respond.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 8)

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Current System Prompt")
                            .font(.headline)
                            .foregroundColor(.secondary)

                        ScrollView {
                            Text(viewModel.systemMessage)
                                .font(.system(.body, design: .monospaced))
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                    #if os(macOS)
                                        .fill(colorScheme == .dark ? Color(.textBackgroundColor) : Color(.controlBackgroundColor))
                                    #endif
                                )
                        }
                        .frame(height: 200)
                    }
                    .padding(8)
                }

                HStack(spacing: 16) {
                    Button(action: {
                        viewModel.systemMessage = "You are a helpful AI assistant."
                    }) {
                        Text("Reset to Default")
                    }

                    Button(action: {
                        isEditingSystemMessage = true
                    }) {
                        Label("Edit System Prompt", systemImage: "pencil")
                    }
                    .keyboardShortcut("e", modifiers: [.command])
                    .buttonStyle(.borderedProminent)
                }
                .padding(.top, 8)
            }
        }
    }

    private var advancedSettingsView: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Advanced Parameters")
                .font(.title2)
                .fontWeight(.semibold)

            Divider()

            VStack(alignment: .leading, spacing: 24) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Max Tokens")
                            .font(.headline)

                        Text("Maximum number of tokens to generate in the response. Higher values allow for longer outputs, but may increase processing time.")
                            .font(.body)
                            .foregroundColor(.secondary)

                        HStack {
                            TextField("", value: $viewModel.maxTokens, formatter: NumberFormatter())
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .frame(width: 80)

                            Slider(value: Binding(
                                get: { Double(viewModel.maxTokens) },
                                set: { viewModel.maxTokens = Int($0) }
                            ), in: 0...4096, step: 128)
                            .frame(maxWidth: 400)

                            Text("\(viewModel.maxTokens)")
                                .monospacedDigit()
                                .frame(width: 60)
                        }
                    }
                    .padding(8)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Temperature")
                            .font(.headline)

                        Text("Controls randomness in the response. Higher values (closer to 1) produce more creative results, while lower values (closer to 0) are more focused and deterministic.")
                            .font(.body)
                            .foregroundColor(.secondary)

                        HStack {
                            TextField("", value: $viewModel.temperature, formatter: NumberFormatter())
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .frame(width: 80)

                            Slider(value: $viewModel.temperature, in: 0...1, step: 0.01)
                            .frame(maxWidth: 400)

                            Text(String(format: "%.2f", viewModel.temperature))
                                .monospacedDigit()
                                .frame(width: 60)
                        }
                    }
                    .padding(8)
                }
            }
        }
    }

    private var localModelsSettingsView: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Local Models")
                .font(.title2)
                .fontWeight(.semibold)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text("Manage Ollama Models")
                    .font(.headline)

                Text("Ollama allows you to run large language models locally on your Mac. Configure and manage your local models from here.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 8)

                #if !os(watchOS) && !os(tvOS)
                Button(action: {
                    showingOllamaSettings = true
                }) {
                    HStack {
                        Image(systemName: "cpu")
                            .frame(width: 24, height: 24)

                        Text("Configure Ollama Models")
                            .font(.body)
                    }
                    .frame(maxWidth: 300, alignment: .leading)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                        #if os(macOS)
                            .fill(colorScheme == .dark ? Color(.controlBackgroundColor) : Color.white)
                        #endif
                            .shadow(color: .black.opacity(0.1), radius: 1, x: 0, y: 1)
                    )
                }
                .buttonStyle(PlainButtonStyle())
                #else
                Text("Local models are not available on this platform.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                #endif
            }
        }
    }

    private var actionsSection: some View {
        HStack {
            Spacer()

            Button(action: {
                viewModel.saveSettings()
            }) {
                Text("Save Settings")
                    .frame(minWidth: 100)
            }
            .keyboardShortcut("s", modifiers: [.command])
            .buttonStyle(.borderedProminent)

            Button(action: {
                viewModel.clearMessages()
            }) {
                Text("Clear Messages")
                    .frame(minWidth: 100)
            }
            .buttonStyle(.bordered)
            .foregroundColor(.red)
        }
    }

    // Helper function to provide model descriptions
    private func modelDescription(for model: Model) -> String {
        switch model {
        case _ where model.rawValue.contains("gpt-3.5"):
            return "GPT-3.5 is a fast and cost-effective model suitable for most everyday tasks. It offers a good balance between capabilities and response time, with good understanding of context and general knowledge up to its training cutoff date."
        case _ where model.rawValue.contains("gpt-4o"):
            return "GPT-4o is OpenAI's latest model offering the best balance of intelligence and speed. It has enhanced reasoning capabilities and multimodal understanding while providing faster responses than traditional GPT-4."
        case _ where model.rawValue.contains("gpt-4"):
            return "GPT-4 is OpenAI's most advanced model for complex reasoning and problem-solving. It excels at tasks requiring deep understanding, nuance, and specialized knowledge, though it may be slower than other models."
        case _ where model.rawValue.contains("claude-3"):
            return "Claude 3 is Anthropic's latest model with strong reasoning capabilities, nuanced understanding, and reliable outputs. It's designed to be helpful, harmless, and honest with particular strength in long-form content."
        case _ where model.rawValue.contains("grok"):
            return "Grok is xAI's model designed to be conversational and witty while still providing accurate information. It aims to strike a balance between helpfulness and personality."
        case _ where model.rawValue.contains("gemini"):
            return "Gemini is Google's multimodal AI model with strong reasoning and multimodal capabilities. It excels at understanding and generating content across text, code, images, and other modalities."
        case _ where model.rawValue.contains("ollama"):
            return "This is a locally-hosted model running through Ollama. Performance and capabilities will depend on the specific model you've downloaded and your local hardware specifications."
        default:
            return "Selected model"
        }
    }
}

struct SystemMessageEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Binding var systemMessage: String
    @State private var editedMessage: String = ""

    var body: some View {
        #if os(macOS)
        macOSEditor
        #else
        mobileEditor
        #endif
    }

    private var macOSEditor: some View {
        VStack(spacing: 20) {
            Text("Edit System Message")
                .font(.title2)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("The system message provides instructions to the AI that guide its behavior.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            TextEditor(text: $editedMessage)
                .font(.body)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.gray.opacity(0.3), lineWidth: 1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.blue.opacity(0.5), lineWidth: editedMessage != systemMessage ? 2 : 0)
                )
                .frame(minHeight: 250)

            HStack(spacing: 16) {
                HStack {
                    Text("Helpful defaults:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button(action: {
                        editedMessage = "You are a helpful AI assistant."
                    }) {
                        Text("General")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)

                    Button(action: {
                        editedMessage = "You are a software development assistant skilled in SwiftUI, Swift, and iOS development. Provide concise, practical code examples and explanations."
                    }) {
                        Text("Developer")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])

                Button("Save") {
                    systemMessage = editedMessage
                    dismiss()
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .buttonStyle(.borderedProminent)
                .disabled(editedMessage == systemMessage)
            }
        }
        .padding(24)
        .frame(minWidth: 600, minHeight: 400)
        #if os(macOS)
        .background(colorScheme == .dark ? Color(.windowBackgroundColor) : Color(.textBackgroundColor))
        #endif
        .onAppear {
            editedMessage = systemMessage
        }
    }

    private var mobileEditor: some View {
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
            .navigationBarItems(leading: Button("Cancel") {
                dismiss()
            }, trailing: Button("Save") {
                systemMessage = editedMessage
                dismiss()
            })
            #else
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
            #endif
            .onAppear {
                editedMessage = systemMessage
            }
        }
    }
}

extension ChatSettingsView {
    @MainActor public class ViewModel: ObservableObject {
        @Published var enterApiKey = false
        @Published var model: Model = UserDefaults.model {
            didSet { UserDefaults.model = model }
        }
        @Published var maxTokens = UserDefaults.maxTokens
        @Published var temperature = UserDefaults.temperature
        @Published var systemMessage = UserDefaults.systemMessage
        @Published var apiKeyInputText: String = ""
        @Published var toolSettings = ToolSettings.shared

        let clearMessages: () -> Void

        /// Callback to trigger WhisperKit preload (set by app)
        public var onPreloadWhisperKit: (() -> Void)?

        /// Callback to get WhisperKit loading state (set by app)
        public var getWhisperKitState: (() -> (isLoading: Bool, description: String))?

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

        func saveToolSettings() {
            toolSettings.saveSettings()
        }

        /// Trigger WhisperKit preload
        func preloadWhisperKit() {
            onPreloadWhisperKit?()
        }

        /// Whether WhisperKit is currently loading
        var whisperKitIsLoading: Bool {
            getWhisperKitState?().isLoading ?? false
        }

        /// WhisperKit status description
        var whisperKitStatusDescription: String {
            getWhisperKitState?().description ?? "Not initialized"
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
                        Toggle("Enable AI Tools", isOn: $viewModel.toolSettings.toolsEnabled)
                            .toggleStyle(SwitchToggleStyle())
                            .padding(.vertical, 4)

                        Text("When disabled, the AI will not use any tools to perform actions.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(8)
                }

                // Individual tool toggles
                if viewModel.toolSettings.toolsEnabled {
                    GroupBox {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                toolToggleRow(
                                    title: "Calendar",
                                    description: "Create, read, update, or delete calendar events",
                                    icon: "calendar",
                                    isOn: $viewModel.toolSettings.calendarToolEnabled
                                )

                                Divider()

                                toolToggleRow(
                                    title: "Reminders",
                                    description: "Create, read, update, or complete reminders",
                                    icon: "list.bullet.clipboard",
                                    isOn: $viewModel.toolSettings.remindersToolEnabled
                                )

                                Divider()

                                toolToggleRow(
                                    title: "Research",
                                    description: "Perform web research on topics using internet sources",
                                    icon: "magnifyingglass",
                                    isOn: $viewModel.toolSettings.researchToolEnabled
                                )

                                Divider()

                                toolToggleRow(
                                    title: "Maps",
                                    description: "Location search, directions, and travel time estimates",
                                    icon: "map",
                                    isOn: $viewModel.toolSettings.mapsToolEnabled
                                )

                                Divider()

                                toolToggleRow(
                                    title: "Contacts",
                                    description: "Create, search, update, or delete contacts",
                                    icon: "person.crop.circle",
                                    isOn: $viewModel.toolSettings.contactsToolEnabled
                                )

                                Divider()

                                toolToggleRow(
                                    title: "Weather",
                                    description: "Get current weather information for locations",
                                    icon: "cloud.sun.fill",
                                    isOn: $viewModel.toolSettings.weatherToolEnabled
                                )

                                #if DEBUG
                                Divider()

                                toolToggleRow(
                                    title: "Files",
                                    description: "Manage files and directories on your device",
                                    icon: "folder",
                                    isOn: $viewModel.toolSettings.filesToolEnabled
                                )
                                #endif
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

                // Rich Content Cards toggle (independent of tools master switch)
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Rich Content Cards", isOn: $viewModel.toolSettings.richContentEnabled)
                            .toggleStyle(SwitchToggleStyle())
                            .padding(.vertical, 4)

                        Text("Display weather, contacts, and events as visual cards below messages instead of plain text.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(8)
                }

                // Reset button
                Button(action: {
                    viewModel.toolSettings.resetToDefaults()
                }) {
                    Text("Reset to Default Settings")
                }
                .buttonStyle(.bordered)
                .padding(.top, 8)
            }
        }
    }

    private func providerDescription(for provider: STTProvider) -> some View {
        switch provider {
        case .appleSpeech:
            return Text("On-device processing. Private and fast, no API key required. Works offline with supported languages.")
        case .openAIWhisper:
            return Text("Cloud-based processing. High accuracy across many languages. Requires OpenAI API key.")
        case .whisperKit:
            return Text("On-device ML inference. High accuracy, works offline. Downloads model on first use.")
        }
    }

    // Helper function to create a tool toggle row
    private func toolToggleRow(
        title: String,
        description: String,
        icon: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.blue)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)

                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Toggle("", isOn: isOn)
                .labelsHidden()
        }
    }
}

