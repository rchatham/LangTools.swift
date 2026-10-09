//
//  ChatSettingsView.swift
//

import Combine
import OpenAI
import SwiftUI
import ToolKit

public struct ChatSettingsView: View {
    @ObservedObject public var viewModel: ViewModel
    @State private var isEditingSystemMessage = false
    @State private var showingOllamaSettings = false
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedTab: SettingsTab = .general
    @State private var selectedCustomTab: String? = nil
    @ObservedObject private var pairingCoordinator = CodexHelperPairingCoordinator.shared

    public enum SettingsTab: String, CaseIterable, Identifiable {
        case general = "General"
        case context = "Context"
        case advanced = "Advanced"
        case localModels = "Local Models"
        case tools = "Tools"

        public var id: String { self.rawValue }

        public var icon: String {
            switch self {
            case .general: return "gear"
            case .context: return "text.bubble"
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
        Group {
            #if os(macOS)
            macOSLayout
            #else
            mobileLayout
            #endif
        }
        .onReceive(pairingCoordinator.$pairedHelper.compactMap { $0 }) { helper in
            guard !viewModel.isProxyContext else { return }
            viewModel.applyHydratedHelperConfigurationIfTokenUnedited(port: helper.port)
        }
        .onChange(of: viewModel.isProxyContext) { _, isProxy in
            if isProxy {
                showingOllamaSettings = false
                if selectedTab == .localModels { selectedTab = .general }
            }
        }
    }

    /// Pairing status row for the Codex helper sections, driven by the pairing coordinator.
    private var pairingStatusRow: some View {
        HStack(spacing: 6) {
            switch pairingCoordinator.pairingStatus {
            case .verified(let port):
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Paired with helper on port \(port) ✓")
            case .paired(let port):
                Image(systemName: "checkmark.circle")
                    .foregroundColor(.secondary)
                Text("Paired with helper on port \(port)")
            case .verificationFailed(let port, let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("Pairing with helper on port \(port) failed: \(message)")
            case .notPaired:
                Image(systemName: "link")
                    .foregroundColor(.secondary)
                Text("Not paired")
            }
        }
        .font(.caption)
        .foregroundColor(.secondary)
    }

    // macOS-specific layout
    private var macOSLayout: some View {
        HStack(spacing: 0) {
            // Sidebar
            List {
                #if os(macOS)
                // Spacer for navigation bar
                Color.clear.frame(height: 40)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                #endif

                ForEach(SettingsTab.allCases.filter { !viewModel.isProxyContext || $0 != .localModels }) { tab in
                    Button(action: {
                        selectedTab = tab
                        selectedCustomTab = nil
                    }) {
                        HStack {
                            Image(systemName: tab.icon)
                                .frame(width: 24)
                            Text(tab.rawValue)
                            Spacer()
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                    .accessibilityIdentifier("settings.\(tab.rawValue)Tab")
                    .padding(.vertical, 4)
                    .background(selectedCustomTab == nil && selectedTab == tab ? (colorScheme == .dark ? Color.gray.opacity(0.3) : Color.blue.opacity(0.1)) : Color.clear)
                    .cornerRadius(6)
                }

                // Custom tabs from app (e.g., Backend)
                ForEach(viewModel.customTabs) { customTab in
                    Button(action: {
                        selectedCustomTab = customTab.id
                    }) {
                        HStack {
                            Image(systemName: customTab.icon)
                                .frame(width: 24)
                            Text(customTab.name)
                            Spacer()
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                    .padding(.vertical, 4)
                    .background(selectedCustomTab == customTab.id ? (colorScheme == .dark ? Color.gray.opacity(0.3) : Color.blue.opacity(0.1)) : Color.clear)
                    .cornerRadius(6)
                }
            }
            .listStyle(PlainListStyle())
            .frame(width: 200)
            #if os(macOS)
            .background(colorScheme == .dark ? Color(.controlBackgroundColor).opacity(0.5) : Color(.windowBackgroundColor).opacity(0.5))
            #endif

            // Divider
            Divider()

            // Content area
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let customTabId = selectedCustomTab,
                       let customTab = viewModel.customTabs.first(where: { $0.id == customTabId }) {
                        customTab.content()
                    } else {
                        switch selectedTab {
                        case .general:
                            generalSettingsView
                        case .context:
                            contextSettingsView
                        case .advanced:
                            advancedSettingsView
                        case .localModels:
                            localModelsSettingsView
                        case .tools:
                            toolsSettingsView
                        }
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
        .directAccessPrompts(enabled: !viewModel.isProxyContext)
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
                    ForEach(viewModel.availableModels, id: \.self) { model in
                        Text(viewModel.modelPickerTitle(for: model)).tag(model)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("settings.modelPicker")
                .disabled(viewModel.availableModels.isEmpty)

                modelCatalogStatus
                selectedModelAvailabilityStatus
                if !viewModel.isProxyContext {
                    Text(viewModel.transportLabel(for: viewModel.model))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Available models depend on which providers you have connected. If a provider is missing, add an API key or sign in from Manage Access.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if viewModel.canManageAccess {
                Section(header: Text("Model Access")) {
                    Text("Models come from connected providers. API keys enable direct API requests, while account sign-in can unlock provider-specific access like Codex.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    ForEach(viewModel.providerAccessStates) { state in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(state.displayName)
                                Spacer()
                                Text(state.badgeTitle)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Text(state.statusDescription)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            accountTransportControls(for: state)
                            if let reason = viewModel.unavailableReason(for: state) {
                                Text(reason)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Button(accessActionTitle(for: state)) {
                                viewModel.presentManageAccess(for: state.accessDestination)
                            }
                        }
                    }

                    Text("For OpenAI account-backed Codex models, start the external helper, then pair with one click from its menu or paste its URL/token below.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    pairingStatusRow
                    TextField("Codex Helper URL", text: $viewModel.codexHelperBaseURLString)
                    SecureField("Codex Helper Token", text: $viewModel.codexHelperToken)
                    if let tokenError = viewModel.codexHelperTokenSaveError {
                        Text(tokenError)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    Text(viewModel.codexHelperCommand)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                }
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

            #if os(iOS)
            Section(header: Text("Advanced Parameters")) {
                generationSettingsControls
            }
            #endif

            #if !os(watchOS) && !os(tvOS)
            if !viewModel.isProxyContext {
            Section(header: Text("Local Models")) {
                Button(action: {
                    guard !ChatUITestEnvironment.isFixtureActive else { return }
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
                .disabled(ChatUITestEnvironment.isFixtureActive)
            }
            }
            #endif

            Button("Save Settings") { viewModel.saveSettings() }
            if viewModel.canManageAccess {
                Button(viewModel.accessButtonTitle) { viewModel.presentManageAccess() }
            }
            Button("Clear messages", role: .destructive) { viewModel.clearMessages() }

            Section(header: Text("AI Tools")) {
                Toggle("Enable AI Tools", isOn: $viewModel.toolManager.toolsEnabled)
                    .toggleStyle(.switch)

                if viewModel.toolManager.toolsEnabled {
                    ForEach(viewModel.toolManager.allToolConfigurations()) { config in
                        Toggle(config.displayName, isOn: viewModel.toolManager.binding(for: config.id))
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

            Section(header: Text("Display")) {
                Toggle("Rich Content Cards", isOn: $viewModel.toolSettings.richContentEnabled)
                Text("Display weather, contacts, and events as visual cards below messages")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Toggle("Keep Tool Calls in History", isOn: $viewModel.toolSettings.keepsToolCallsInHistory)
                Text("Show tool-call cards after the tool completes. Turn off to hide them once the response continues.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Toggle("Share Tool Results Across Providers", isOn: $viewModel.toolSettings.crossProviderToolReplay)
                Text("Let hidden structured agent results be sent to whichever provider you switch to. Turn off to send them only to the provider that produced them.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Custom sections from app (e.g., Backend)
            ForEach(viewModel.customTabs) { customTab in
                Section(header: Text(customTab.name)) {
                    customTab.content()
                }
            }

            Section(header: Text("Voice Input")) {
                Toggle("Enable Voice Input", isOn: $viewModel.toolSettings.voiceInputEnabled)
                    .toggleStyle(.switch)

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
                            ForEach(WhisperKitModelSize.allCases, id: \.self) { size in
                                Text(size.displayName).tag(size)
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
                        ForEach(STTLanguage.allCases, id: \.self) { language in
                            Text(language.displayName).tag(language)
                        }
                    }

                    Text("Select the language you'll be speaking")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Toggle("Auto-stop on silence", isOn: $viewModel.toolSettings.autoStopOnSilence)

                    if viewModel.toolSettings.autoStopOnSilence {
                        Picker("Silence timeout", selection: $viewModel.toolSettings.silenceTimeout) {
                            ForEach(SilenceTimeout.allCases, id: \.self) { timeout in
                                Text(timeout.displayName).tag(timeout)
                            }
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
                            Picker("Update interval", selection: $viewModel.toolSettings.streamingChunkInterval) {
                                ForEach(StreamingChunkInterval.allCases, id: \.self) { interval in
                                    Text(interval.displayName).tag(interval)
                                }
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
        .directAccessPrompts(enabled: !viewModel.isProxyContext)
    }

    @ViewBuilder
    private var modelCatalogStatus: some View {
        if let source = viewModel.modelSource {
            switch source.state {
            case .direct, .ready:
                EmptyView()
            case .loading:
                ProgressView("Loading server models…")
                    .accessibilityIdentifier("settings.models.loading")
            case .authenticationRequired:
                Text("Sign in to load server models.")
                    .accessibilityIdentifier("settings.models.error")
                Button("Sign In", action: source.signIn)
                    .accessibilityIdentifier("settings.models.signIn")
            case .empty:
                Text("No models are configured on this server.")
                    .accessibilityIdentifier("settings.models.empty")
                Button("Retry", action: source.retry)
                    .accessibilityIdentifier("settings.models.retry")
            case .failed(let message):
                Text(message).accessibilityIdentifier("settings.models.error")
                Button("Retry", action: source.retry)
                    .accessibilityIdentifier("settings.models.retry")
            case .unsupportedCatalog:
                Text("The server catalog contains no supported chat models. Update the app or contact the server administrator.")
                    .accessibilityIdentifier("settings.models.error")
                Button("Retry", action: source.retry)
                    .accessibilityIdentifier("settings.models.retry")
            }
        }
    }

    @ViewBuilder
    private var selectedModelAvailabilityStatus: some View {
        if let reason = viewModel.selectedModelUnavailableReason {
            Text(reason)
                .font(.caption)
                .foregroundColor(.secondary)
                .accessibilityIdentifier("settings.models.selectedUnavailable")
        }
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
                            ForEach(viewModel.availableModels, id: \.self) { model in
                                Text(viewModel.modelPickerTitle(for: model)).tag(model)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 400)
                        .accessibilityIdentifier("settings.modelPicker")
                        .disabled(viewModel.availableModels.isEmpty)

                        modelCatalogStatus
                        selectedModelAvailabilityStatus
                        Divider()

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Model Info")
                                .font(.headline)
                                .foregroundColor(.secondary)

                            if !viewModel.isProxyContext {
                                Text(viewModel.transportLabel(for: viewModel.model))
                                    .font(.caption)
                            }
                            Text(viewModel.isProxyContext ? "Models are provided by the Botsworth server. No personal provider API key is required." : modelDescription(for: viewModel.model))
                                .font(.body)
                        }

                        if viewModel.canManageAccess {
                            Divider()

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Codex Helper")
                                    .font(.headline)
                                Text("Run one of these in Terminal before using OpenAI account-backed Codex models, or pair with one click from the helper app's menu:")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                Text(viewModel.codexHelperCommand)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                pairingStatusRow
                                TextField("Codex Helper URL", text: $viewModel.codexHelperBaseURLString)
                                    .textFieldStyle(.roundedBorder)
                                SecureField("Codex Helper Token", text: $viewModel.codexHelperToken)
                                    .textFieldStyle(.roundedBorder)
                                Text("OpenAI account-backed models use the external Codex helper. API-key-backed OpenAI Platform models continue to use the regular API path.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(8)
                }

                if viewModel.canManageAccess {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Model Access")
                                .font(.headline)

                            Text("Models appear here when their provider is configured. Add an API key for direct API requests, or sign in with an account for provider-specific access like Codex.")
                                .font(.body)
                                .foregroundColor(.secondary)

                            ForEach(viewModel.providerAccessStates) { state in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(state.displayName)
                                            .font(.headline)
                                        Spacer()
                                        Text(state.badgeTitle)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }

                                    Text(state.statusDescription)
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                    accountTransportControls(for: state)

                                    if let reason = viewModel.unavailableReason(for: state) {
                                        Text(reason)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }

                                    Button(accessActionTitle(for: state)) {
                                        viewModel.presentManageAccess(for: state.accessDestination)
                                    }
                                    .buttonStyle(.bordered)
                                }

                                if state.service != viewModel.providerAccessStates.last?.service {
                                    Divider()
                                }
                            }
                        }
                        .padding(8)
                    }
                    .padding(.top, 8)
                }
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
                            .toggleStyle(.switch)
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
                                        ForEach(WhisperKitModelSize.allCases, id: \.self) { size in
                                            Text(size.displayName).tag(size)
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
                                .toggleStyle(.switch)

                            Text("Show microphone button in place of send button when text field is empty")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Divider()

                            Text("Language")
                                .font(.headline)

                            Picker("", selection: $viewModel.toolSettings.sttLanguage) {
                                ForEach(STTLanguage.allCases, id: \.self) { language in
                                    if language == .auto {
                                        Text(language.displayName).tag(language)
                                        Divider()
                                    } else {
                                        Text(language.displayName).tag(language)
                                    }
                                }
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
                                .toggleStyle(.switch)

                            if viewModel.toolSettings.autoStopOnSilence {
                                HStack {
                                    Text("Silence timeout:")
                                    Picker("", selection: $viewModel.toolSettings.silenceTimeout) {
                                        ForEach(SilenceTimeout.allCases, id: \.self) { timeout in
                                            Text(timeout.displayName).tag(timeout)
                                        }
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
                                .toggleStyle(.switch)

                            Text("Display transcribed text as you speak, before recording is complete.")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            if viewModel.toolSettings.streamingTranscriptionEnabled &&
                               viewModel.toolSettings.sttProvider == .openAIWhisper {

                                Toggle("Simulated streaming", isOn: $viewModel.toolSettings.enableOpenAISimulatedStreaming)
                                    .toggleStyle(.switch)

                                if viewModel.toolSettings.enableOpenAISimulatedStreaming {
                                    HStack {
                                        Text("Update interval:")
                                        Picker("", selection: $viewModel.toolSettings.streamingChunkInterval) {
                                            ForEach(StreamingChunkInterval.allCases, id: \.self) { interval in
                                                Text(interval.displayName).tag(interval)
                                            }
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

    private var contextSettingsView: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Context & Memory")
                .font(.title2)
                .fontWeight(.semibold)

            Divider()

            // System prompt section
            VStack(alignment: .leading, spacing: 12) {
                Text("System Prompt")
                    .font(.headline)

                Text("Instructions that guide the AI's behavior. This message sets the context for how the AI should respond.")
                    .font(.body)
                    .foregroundColor(.secondary)

                GroupBox {
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
                    .frame(height: 120)
                    .padding(4)
                }

                HStack(spacing: 12) {
                    Button("Reset to Default") {
                        viewModel.systemMessage = "You are a helpful AI assistant."
                    }
                    Button {
                        isEditingSystemMessage = true
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }

            Divider()

            // Context window section
            VStack(alignment: .leading, spacing: 8) {
                Text("Context Window")
                    .font(.headline)

                if let ctxTokens = viewModel.model.generationCapabilities.contextWindowTokens {
                    Text("This model supports up to \(ctxTokens.formatted()) input tokens.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Message Limit")
                            .font(.caption)
                        TextField("Unlimited", value: Binding(
                            get: { viewModel.conversationSettings.maxContextMessages },
                            set: { viewModel.updateMaxContextMessages($0) }
                        ), format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Window % — stored only")
                            .font(.caption)
                        TextField("100", value: Binding(
                            get: { viewModel.conversationSettings.contextWindowPercent },
                            set: { viewModel.updateContextWindowPercent($0) }
                        ), format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                    }

                    Text("Only Message Limit is applied to requests; Window % is stored for future wiring.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            // Memory fields section
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Memory")
                        .font(.headline)
                    Spacer()
                    Button {
                        viewModel.addMemoryField(label: "", value: "")
                    } label: {
                        Label("Add", systemImage: "plus.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }

                Text("Custom information injected into the system prompt. Useful for names, preferences, project context, or any details you want the AI to remember.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if viewModel.conversationSettings.memoryFields.isEmpty {
                    Text("No memory fields. Add some to give the AI personal context.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 8)
                }

                ForEach(viewModel.conversationSettings.memoryFields) { field in
                    HStack(spacing: 8) {
                        TextField("Label", text: Binding(
                            get: { field.label },
                            set: { viewModel.updateMemoryField(id: field.id, label: $0, value: field.value) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)

                        TextField("Value", text: Binding(
                            get: { field.value },
                            set: { viewModel.updateMemoryField(id: field.id, label: field.label, value: $0) }
                        ))
                        .textFieldStyle(.roundedBorder)

                        Button {
                            viewModel.removeMemoryField(id: field.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var advancedSettingsView: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Advanced Parameters")
                .font(.title2)
                .fontWeight(.semibold)

            Divider()

            GroupBox {
                generationSettingsControls
                    .padding(8)
            }
        }
    }

    private var generationSettingsControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            ChatGenerationSettingsView(
                maxOutputTokens: Binding(
                    get: { viewModel.generationSettings.maxOutputTokens },
                    set: { viewModel.updateMaximumOutputTokens($0) }
                ),
                temperature: Binding(
                    get: { viewModel.generationSettings.temperature },
                    set: { viewModel.updateTemperature($0) }
                ),
                topP: Binding(
                    get: { viewModel.generationSettings.topP },
                    set: { viewModel.updateTopP($0) }
                ),
                frequencyPenalty: Binding(
                    get: { viewModel.generationSettings.frequencyPenalty },
                    set: { viewModel.updateFrequencyPenalty($0) }
                ),
                presencePenalty: Binding(
                    get: { viewModel.generationSettings.presencePenalty },
                    set: { viewModel.updatePresencePenalty($0) }
                ),
                topK: Binding(
                    get: { viewModel.generationSettings.topK },
                    set: { viewModel.updateTopK($0) }
                ),
                seed: Binding(
                    get: { viewModel.generationSettings.seed },
                    set: { viewModel.updateSeed($0) }
                ),
                stop: Binding(
                    get: { viewModel.generationSettings.stop },
                    set: { viewModel.updateStop($0) }
                ),
                capabilities: viewModel.model.generationCapabilities,
                reset: viewModel.resetGenerationSettings
            )
            if let error = viewModel.generationSettingsError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
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
                    guard !ChatUITestEnvironment.isFixtureActive else { return }
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
                .disabled(ChatUITestEnvironment.isFixtureActive)
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

    @ViewBuilder
    private func accountTransportControls(for state: ProviderAccessState) -> some View {
        if let provider = state.accessDestination?.accountProvider {
            Picker("Transport", selection: Binding(
                get: { viewModel.accountTransport(for: provider) },
                set: { viewModel.selectAccountTransport($0, for: provider) }
            )) {
                Text(provider == .openAI ? "Local Codex helper" : "Claude Code backend").tag(AccountTransportChoice.existing)
                Text(viewModel.pairedHelperLabel).tag(AccountTransportChoice.pairedHelper)
            }
            .accessibilityIdentifier("settings.accountTransport.\(provider.rawValue)")
            if viewModel.accountTransport(for: provider) == .pairedHelper {
                Button("Refresh Account Models") { viewModel.refreshPairedAccount(provider) }
                Button("Disconnect Paired Helper", role: .destructive) { viewModel.disconnectPairedHelper() }
                Text("Requires the same trusted network. Sign in to Codex on the Mac. Claude Code requires an existing external backend account session; pairing does not create one. No automatic fallback.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            if let error = viewModel.accountTransportError {
                Text(error).font(.caption).foregroundColor(.red)
            }
        } else {
            Text("Direct API key").font(.caption).foregroundColor(.secondary)
        }
    }

    // Helper function to provide model descriptions
    private func accessActionTitle(for state: ProviderAccessState) -> String {
        "Manage \(state.displayName) Access"
    }

    private func modelDescription(for model: Model) -> String {
        switch model {
        case .codex:
            return "This model uses your Codex account through \(viewModel.transportLabel(for: model)), not the OpenAI Platform API."
        case .claudeCode:
            return "This model uses the external Claude Code account backend through \(viewModel.transportLabel(for: model)), not an Anthropic API key."
        case .openAI where model.slug.contains("gpt-3.5"):
            return "GPT-3.5 is a fast and cost-effective model suitable for most everyday tasks. It offers a good balance between capabilities and response time, with good understanding of context and general knowledge up to its training cutoff date."
        case .openAI where model.slug.contains("gpt-4o"):
            return "GPT-4o is OpenAI's latest model offering the best balance of intelligence and speed. It has enhanced reasoning capabilities and multimodal understanding while providing faster responses than traditional GPT-4."
        case .openAI where model.slug.contains("gpt-5.5") || model.slug.contains("gpt-5.4"):
            return "This model runs through the OpenAI Platform API and requires an OpenAI API key."
        case .openAI where model.slug.contains("gpt-4"):
            return "GPT-4 is OpenAI's most advanced model for complex reasoning and problem-solving. It excels at tasks requiring deep understanding, nuance, and specialized knowledge, though it may be slower than other models."
        case .anthropic where model.slug.contains("claude"):
            return "Claude models provide strong reasoning and long-context performance through Anthropic."
        case .xAI where model.slug.contains("grok"):
            return "Grok is xAI's model designed to be conversational and witty while still providing accurate information."
        case .gemini where model.slug.contains("gemini"):
            return "Gemini is Google's multimodal AI model with strong reasoning and multimodal capabilities."
        case .ollama:
            return "This is a locally-hosted model running through Ollama. Performance and capabilities depend on the model and your local hardware."
        default:
            return "Selected model"
        }
    }
}

private extension View {
    @ViewBuilder
    func directAccessPrompts(enabled: Bool) -> some View {
        if enabled && !ChatUITestEnvironment.isFixtureActive {
            manageAccessPrompts(priority: 10)
        } else {
            self
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
        public let modelSource: ChatModelSource?
        public var isProxyContext: Bool { modelSource?.isProxy == true }

        @Published public var model: Model = UserDefaults.model {
            didSet { UserDefaults.model = model }
        }
        @Published var generationSettings = ChatGenerationSettings.automatic
        @Published var generationSettingsError: String?
        @Published var conversationSettings = ChatConversationSettings.default
        @Published var systemMessage = UserDefaults.systemMessage // legacy source compat
        @Published var codexHelperBaseURLString = UserDefaults.codexHelperBaseURL.absoluteString
        @Published var codexHelperToken: String
        /// Raw helper token as last synced from a successful pairing.
        /// Compared against the form token to avoid overwriting in-progress edits.
        var lastSyncedHelperTokenSnapshot: String
        /// Last URL loaded into the form; pairing must not overwrite an edit.
        var lastSyncedHelperURLSnapshot: String = UserDefaults.codexHelperBaseURL.absoluteString
        @Published var codexHelperTokenSaveError: String?
        @Published var toolSettings = ToolSettings.shared
        @Published public var toolManager = ToolManager.shared
        public var accessManager: ProviderAccessManager

        let clearMessages: () -> Void
        private let generationSettingsStore: ChatGenerationSettingsStoring
        private let conversationSettingsStore: ChatConversationSettingsStoring
        private let codexHelperTokenStore: CodexHelperTokenStore

        /// Callback to trigger WhisperKit preload (set by app)
        public var onPreloadWhisperKit: (() -> Void)?

        /// Callback to get WhisperKit loading state (set by app)
        public var getWhisperKitState: (() -> (isLoading: Bool, description: String))?

        // MARK: - Custom Settings Tabs
        /// Custom tabs injected by the app (e.g., Backend settings)
        public var customTabs: [CustomSettingsTab] = []

        /// Retains subscriptions that relay nested ObservableObject changes.
        private var cancellables: Set<AnyCancellable> = []

        public init(
            clearMessages: @escaping () -> Void,
            modelSource: ChatModelSource? = nil,
            generationSettingsStore: ChatGenerationSettingsStoring = ChatGenerationSettingsStore(),
            conversationSettingsStore: ChatConversationSettingsStoring = ChatConversationSettingsStore(),
            accessManager: ProviderAccessManager = .shared,
            codexHelperTokenStore: CodexHelperTokenStore = CodexHelperTokenStore()
        ) {
            self.clearMessages = clearMessages
            self.modelSource = modelSource
            self.generationSettingsStore = generationSettingsStore
            self.conversationSettingsStore = conversationSettingsStore
            self.accessManager = accessManager
            self.codexHelperTokenStore = codexHelperTokenStore
            let helperToken = codexHelperTokenStore.token()
            self.codexHelperToken = helperToken
            self.lastSyncedHelperTokenSnapshot = helperToken
            modelSource?.$state.sink { [weak self] state in
                guard let self else { return }
                if case .ready(let models) = state, !models.contains(self.model), let first = models.first {
                    self.model = first
                }
                self.objectWillChange.send()
            }.store(in: &cancellables)
            // ToolManager is a nested ObservableObject. SwiftUI won't re-render this view
            // when ToolManager's @Published properties change unless we relay its
            // objectWillChange through our own.
            ToolManager.shared.objectWillChange
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)

            accessManager.objectWillChange
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }

        public var availableModels: [Model] {
            if let modelSource, modelSource.isProxy { return modelSource.models }
            let available = accessManager.availableChatModels()
            guard !available.contains(model),
                  model.apiService == .ollama || accessManager.usesPairedAccountTransport(for: model) else { return available }
            return [model] + available
        }

        var selectedModelUnavailableReason: String? {
            guard !isProxyContext,
                  accessManager.usesPairedAccountTransport(for: model),
                  !accessManager.availableChatModels().contains(model) else { return nil }
            let state = providerAccessStates.first { $0.accessDestination == AccessDestination.destination(for: model) }
            let reason = state.flatMap { accessManager.unavailableReason(for: $0) }
                ?? "The selected model is not in the current helper account catalog."
            return "Selected model \(model.rawValue) is unavailable. \(reason) Your selection is kept; reconnect or explicitly choose another model. No direct API fallback is used."
        }

        func loadSettings() {
            if let modelSource, modelSource.isProxy {
                model = modelSource.reconciledSelection(UserDefaults.model)
            } else {
                accessManager.refresh()
                model = accessManager.validateSelectedModel(UserDefaults.model)
            }
            generationSettings = generationSettingsStore.load()
            generationSettingsError = nil
            conversationSettings = conversationSettingsStore.load()
            systemMessage = conversationSettings.systemPrompt
            codexHelperBaseURLString = UserDefaults.codexHelperBaseURL.absoluteString
            codexHelperToken = codexHelperTokenStore.token()
            lastSyncedHelperURLSnapshot = codexHelperBaseURLString
            lastSyncedHelperTokenSnapshot = codexHelperToken
        }

        var canManageAccess: Bool {
            !isProxyContext && model.apiService != .ollama
        }

        var providerAccessStates: [ProviderAccessState] {
            accessManager.statesForAccessUI()
        }

        @Published var accountTransportError: String?

        var pairedHelperLabel: String { accessManager.accountTransports.pairedHelperLabel }
        func accountTransport(for provider: AccountLoginProvider) -> AccountTransportChoice {
            accessManager.accountTransports.snapshot(for: provider).choice
        }
        func transportLabel(for model: Model) -> String { accessManager.transportLabel(for: model) }
        func selectAccountTransport(_ choice: AccountTransportChoice, for provider: AccountLoginProvider) {
            accountTransportError = nil
            accessManager.accountTransports.select(choice, for: provider)
            accessManager.refresh()
            objectWillChange.send()
            if choice == .pairedHelper { refreshPairedAccount(provider) }
        }
        func refreshPairedAccount(_ provider: AccountLoginProvider) {
            Task { await accessManager.refreshPairedAccount(provider) }
        }
        func disconnectPairedHelper() {
            do {
                try accessManager.disconnectPairedHelper()
                objectWillChange.send()
            } catch { accountTransportError = error.localizedDescription }
        }

        func unavailableReason(for state: ProviderAccessState) -> String? {
            accessManager.unavailableReason(for: state)
        }

        var accessButtonTitle: String {
            switch model.apiService {
            case .anthropic:
                return "Manage Claude / Anthropic Access"
            default:
                return "Manage \(model.apiService.displayName) Access"
            }
        }

        func saveSettings() {
            UserDefaults.model = isProxyContext ? (modelSource?.reconciledSelection(model) ?? model) : accessManager.validateSelectedModel(model)
            generationSettingsStore.save(generationSettings)
            generationSettingsError = nil
            var cs = conversationSettings
            cs = ChatConversationSettings(
                systemPrompt: systemMessage,
                maxContextMessages: cs.maxContextMessages,
                contextWindowPercent: cs.contextWindowPercent,
                memoryFields: cs.memoryFields
            )
            conversationSettingsStore.save(cs)
            UserDefaults.systemMessage = systemMessage // legacy compat
            guard !isProxyContext else { return }
            if let url = URL(string: codexHelperBaseURLString), url.scheme?.isEmpty == false {
                UserDefaults.codexHelperBaseURL = url
                lastSyncedHelperURLSnapshot = codexHelperBaseURLString
            }
            do {
                try codexHelperTokenStore.setToken(codexHelperToken.trimmingCharacters(in: .whitespacesAndNewlines))
                codexHelperTokenSaveError = nil
            } catch {
                // Surface Keychain persistence failures instead of silently
                // retaining the prior credential.
                codexHelperTokenSaveError = error.localizedDescription
            }
        }

        func updateMaximumOutputTokens(_ value: Int?) {
            updateGenerationSettings { settings in
                try ChatGenerationSettings(
                    maxOutputTokens: value,
                    temperature: settings.temperature,
                    topP: settings.topP,
                    frequencyPenalty: settings.frequencyPenalty,
                    presencePenalty: settings.presencePenalty,
                    topK: settings.topK,
                    seed: settings.seed,
                    stop: settings.stop
                )
            }
        }

        func updateTemperature(_ value: Double?) {
            updateGenerationSettings { settings in
                try ChatGenerationSettings(
                    maxOutputTokens: settings.maxOutputTokens,
                    temperature: value,
                    topP: settings.topP,
                    frequencyPenalty: settings.frequencyPenalty,
                    presencePenalty: settings.presencePenalty,
                    topK: settings.topK,
                    seed: settings.seed,
                    stop: settings.stop
                )
            }
        }

        func updateTopP(_ value: Double?) {
            updateGenerationSettings { settings in
                try ChatGenerationSettings(
                    maxOutputTokens: settings.maxOutputTokens,
                    temperature: settings.temperature,
                    topP: value,
                    frequencyPenalty: settings.frequencyPenalty,
                    presencePenalty: settings.presencePenalty,
                    topK: settings.topK,
                    seed: settings.seed,
                    stop: settings.stop
                )
            }
        }

        func updateFrequencyPenalty(_ value: Double?) {
            updateGenerationSettings { settings in
                try ChatGenerationSettings(
                    maxOutputTokens: settings.maxOutputTokens,
                    temperature: settings.temperature,
                    topP: settings.topP,
                    frequencyPenalty: value,
                    presencePenalty: settings.presencePenalty,
                    topK: settings.topK,
                    seed: settings.seed,
                    stop: settings.stop
                )
            }
        }

        func updatePresencePenalty(_ value: Double?) {
            updateGenerationSettings { settings in
                try ChatGenerationSettings(
                    maxOutputTokens: settings.maxOutputTokens,
                    temperature: settings.temperature,
                    topP: settings.topP,
                    frequencyPenalty: settings.frequencyPenalty,
                    presencePenalty: value,
                    topK: settings.topK,
                    seed: settings.seed,
                    stop: settings.stop
                )
            }
        }

        func updateTopK(_ value: Int?) {
            updateGenerationSettings { settings in
                try ChatGenerationSettings(
                    maxOutputTokens: settings.maxOutputTokens,
                    temperature: settings.temperature,
                    topP: settings.topP,
                    frequencyPenalty: settings.frequencyPenalty,
                    presencePenalty: settings.presencePenalty,
                    topK: value,
                    seed: settings.seed,
                    stop: settings.stop
                )
            }
        }

        func updateSeed(_ value: Int?) {
            updateGenerationSettings { settings in
                try ChatGenerationSettings(
                    maxOutputTokens: settings.maxOutputTokens,
                    temperature: settings.temperature,
                    topP: settings.topP,
                    frequencyPenalty: settings.frequencyPenalty,
                    presencePenalty: settings.presencePenalty,
                    topK: settings.topK,
                    seed: value,
                    stop: settings.stop
                )
            }
        }

        func updateStop(_ value: [String]?) {
            updateGenerationSettings { settings in
                try ChatGenerationSettings(
                    maxOutputTokens: settings.maxOutputTokens,
                    temperature: settings.temperature,
                    topP: settings.topP,
                    frequencyPenalty: settings.frequencyPenalty,
                    presencePenalty: settings.presencePenalty,
                    topK: settings.topK,
                    seed: settings.seed,
                    stop: value
                )
            }
        }

        func resetGenerationSettings() {
            generationSettingsStore.reset()
            generationSettings = .automatic
            generationSettingsError = nil
        }

        // MARK: - Conversation settings

        func updateMaxContextMessages(_ value: Int?) {
            conversationSettings = ChatConversationSettings(
                systemPrompt: conversationSettings.systemPrompt,
                maxContextMessages: value,
                contextWindowPercent: conversationSettings.contextWindowPercent,
                memoryFields: conversationSettings.memoryFields
            )
        }

        func updateContextWindowPercent(_ value: Int?) {
            conversationSettings = ChatConversationSettings(
                systemPrompt: conversationSettings.systemPrompt,
                maxContextMessages: conversationSettings.maxContextMessages,
                contextWindowPercent: value,
                memoryFields: conversationSettings.memoryFields
            )
        }

        func addMemoryField(label: String, value: String) {
            var fields = conversationSettings.memoryFields
            fields.append(.init(label: label, value: value))
            conversationSettings = ChatConversationSettings(
                systemPrompt: conversationSettings.systemPrompt,
                maxContextMessages: conversationSettings.maxContextMessages,
                contextWindowPercent: conversationSettings.contextWindowPercent,
                memoryFields: fields
            )
        }

        func updateMemoryField(id: UUID, label: String, value: String) {
            var fields = conversationSettings.memoryFields
            if let idx = fields.firstIndex(where: { $0.id == id }) {
                fields[idx] = .init(id: id, label: label, value: value)
            }
            conversationSettings = ChatConversationSettings(
                systemPrompt: conversationSettings.systemPrompt,
                maxContextMessages: conversationSettings.maxContextMessages,
                contextWindowPercent: conversationSettings.contextWindowPercent,
                memoryFields: fields
            )
        }

        func removeMemoryField(id: UUID) {
            var fields = conversationSettings.memoryFields
            fields.removeAll { $0.id == id }
            conversationSettings = ChatConversationSettings(
                systemPrompt: conversationSettings.systemPrompt,
                maxContextMessages: conversationSettings.maxContextMessages,
                contextWindowPercent: conversationSettings.contextWindowPercent,
                memoryFields: fields
            )
        }

        private func updateGenerationSettings(transform: (ChatGenerationSettings) throws -> ChatGenerationSettings) {
            do {
                generationSettings = try transform(generationSettings)
                generationSettingsError = nil
            } catch {
                generationSettingsError = error.localizedDescription
            }
        }

        func presentManageAccess(for destination: AccessDestination? = nil) {
            guard !isProxyContext else { return }
            let targetDestination = destination ?? AccessDestination.destination(for: model)
            AuthPresentationCoordinator.shared.present(preferredDestination: targetDestination)
        }

        /// Refreshes a confirmed pairing without clobbering token or URL edits
        /// already in progress in the Settings form.
        func applyHydratedHelperConfigurationIfTokenUnedited(port: Int) {
            guard codexHelperToken == lastSyncedHelperTokenSnapshot else { return }
            let persistedToken = codexHelperTokenStore.token()
            codexHelperToken = persistedToken
            lastSyncedHelperTokenSnapshot = persistedToken
            if codexHelperBaseURLString == lastSyncedHelperURLSnapshot {
                codexHelperBaseURLString = "http://127.0.0.1:\(port)"
                lastSyncedHelperURLSnapshot = codexHelperBaseURLString
            }
        }

        func saveToolSettings() {
            toolSettings.saveSettings()
        }

        var codexHelperCommand: String {
            "make helper-app-open  # menu-bar app with one-click pairing\nmake codex-helper    # CLI alternative"
        }

        func modelPickerTitle(for model: Model) -> String {
            if isProxyContext { return model.rawValue }
            if model.apiService == .ollama,
               !accessManager.availableChatModels().contains(model) {
                return "\(model.rawValue) — Unavailable on current Ollama server"
            }
            if accessManager.usesPairedAccountTransport(for: model),
               !accessManager.availableChatModels().contains(model) {
                return "\(model.rawValue) — Unavailable — \(transportLabel(for: model))"
            }
            return "\(model.rawValue) — \(transportLabel(for: model))"
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
                        Toggle("Enable AI Tools", isOn: $viewModel.toolManager.toolsEnabled)
                            .toggleStyle(.switch)
                            .padding(.vertical, 4)

                        Text("When disabled, the AI will not use any tools to perform actions.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(8)
                }

                // Individual tool toggles driven by ToolManager
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

                // Rich Content Cards toggle (independent of tools master switch)
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Rich Content Cards", isOn: $viewModel.toolSettings.richContentEnabled)
                            .toggleStyle(.switch)
                            .padding(.vertical, 4)

                        Text("Display weather, contacts, and events as visual cards below messages instead of plain text.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Divider()

                        Toggle("Keep Tool Calls in History", isOn: $viewModel.toolSettings.keepsToolCallsInHistory)
                            .toggleStyle(.switch)
                            .padding(.vertical, 4)

                        Text("Show tool-call cards after the tool completes. Turn off to hide them once the response continues.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(8)
                }

                Divider()

                // Tool execution settings
                VStack(alignment: .leading, spacing: 12) {
                    Text("Tool Execution")
                        .font(.headline)

                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Max Iterations")
                                .font(.caption)
                            TextField("Unlimited", value: Binding(
                                get: { viewModel.toolSettings.maxToolIterations },
                                set: { viewModel.toolSettings.maxToolIterations = $0 }
                            ), format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Timeout (s) — stored only")
                                .font(.caption)
                            TextField("None", value: Binding(
                                get: { viewModel.toolSettings.toolTimeoutSeconds },
                                set: { viewModel.toolSettings.toolTimeoutSeconds = $0 }
                            ), format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        }
                    }
                    .padding(.bottom, 4)

                    Toggle("Auto-Retry Failed Tools", isOn: $viewModel.toolSettings.autoRetryFailedTools)
                        .accessibilityIdentifier("settings.tools.autoRetryFailedTools.toggle")
                        .checkboxToggleStyle()
                    Text("Automatically retry a failed tool call once before reporting the error. (UI only — execution wiring coming soon)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 8)

                Divider()

                // Agent model override
                VStack(alignment: .leading, spacing: 8) {
                    Text("Agent Model")
                        .font(.headline)

                    Text("Override the conversation model for agent execution. Leave as 'Conversation Model' to use the currently selected model.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Picker("Agent Model Override", selection: Binding(
                        get: { viewModel.toolSettings.agentModelOverride },
                        set: { viewModel.toolSettings.agentModelOverride = $0 }
                    )) {
                        Text("Conversation Model").tag(nil as Model?)
                        ForEach(viewModel.availableModels, id: \.self) { model in
                            Text(model.rawValue).tag(model as Model?)
                        }
                    }
                    .pickerStyle(.menu)
                }
                .padding(.top, 8)

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

    // Helper function to create a tool toggle row from explicit fields
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

    // Helper function to create a tool toggle row from a ToolConfiguration
    private func toolToggleRow(
        config: ToolConfiguration,
        isOn: Binding<Bool>
    ) -> some View {
        toolToggleRow(
            title: config.displayName,
            description: config.description,
            icon: config.iconName,
            isOn: isOn
        )
    }
}

/// Custom settings tab that can be injected by the app
public struct CustomSettingsTab: Identifiable {
    public let id: String
    public let name: String
    public let icon: String
    public let content: () -> AnyView

    public init(
        id: String,
        name: String,
        icon: String,
        content: @escaping () -> AnyView
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.content = content
    }
}

