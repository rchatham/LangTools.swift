//
//  SettingsPanel.swift
//  CLI
//
//  Self-contained settings overlay panel
//

import SwiftTUI
import Foundation

/// Self-contained settings panel overlay
struct SettingsPanel: View {
    /// Current settings navigation mode
    @Binding var mode: SettingsMode

    /// Status message to show feedback
    @Binding var statusMessage: String

    /// Callback to close the panel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with close button
            header

            // Separator
            Text(String(repeating: "─", count: 38))
                .foregroundColor(.blue)

            // Content based on current mode
            settingsContent

            // Footer
            Text(String(repeating: "─", count: 38))
                .foregroundColor(.blue)
            footerHint
        }
        .border()
        .frame(width: 42)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text(headerTitle)
                .foregroundColor(.cyan)
                .bold()

            Spacer()

            Button("[×]") {
                closePanel()
            }
            .foregroundColor(.red)
        }
    }

    private var headerTitle: String {
        switch mode {
        case .none: return "Settings"
        case .main: return "Settings"
        case .apiKeys: return "API Keys"
        case .apiKeyInput(let service): return "Enter \(service.rawValue) Key"
        case .theme: return "Theme"
        case .maxTokens: return "Max Tokens"
        case .temperature: return "Temperature"
        case .model, .modelProvider: return "Model"
        case .modelList(let provider): return "\(provider.rawValue) Models"
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var settingsContent: some View {
        switch mode {
        case .none, .main:
            mainMenu
        case .apiKeys:
            apiKeysMenu
        case .apiKeyInput:
            apiKeyInputView
        case .theme:
            themeMenu
        case .maxTokens:
            maxTokensView
        case .temperature:
            temperatureView
        case .model, .modelProvider:
            providerMenu
        case .modelList(let provider):
            providerModelList(for: provider)
        }
    }

    // MARK: - Main Menu

    private var mainMenu: some View {
        let config = Configuration.load()
        let maxTokensDisplay = UserDefaults.maxTokens == 0 ? "default" : String(UserDefaults.maxTokens)
        let tempDisplay = UserDefaults.temperature == 0 ? "default" : String(format: "%.1f", UserDefaults.temperature)
        let modelDisplay = String(UserDefaults.model.rawValue.prefix(18))

        return VStack(alignment: .leading, spacing: 0) {
            menuButton("1. API Keys", action: { mode = .apiKeys })
            menuButton("2. Model (\(modelDisplay))", action: { mode = .model })
            menuButton("3. Max Tokens (\(maxTokensDisplay))", action: { mode = .maxTokens })
            menuButton("4. Temperature (\(tempDisplay))", action: { mode = .temperature })
            menuButton("5. Theme (\(config.theme.rawValue))", action: { mode = .theme })
            menuButton("6. Streaming (\(config.streamingEnabled ? "on" : "off"))", action: toggleStreaming)
        }
    }

    // MARK: - API Keys Menu

    private var apiKeysMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(APIService.allCases.indices, id: \.self) { index in
                let service = APIService.allCases[index]
                let hasKey = UserDefaults.getApiKey(for: service) != nil
                let status = hasKey ? "✓" : "✗"
                menuButton("\(index + 1). \(service.rawValue) \(status)") {
                    mode = .apiKeyInput(service)
                }
            }
            backButton()
        }
    }

    private var apiKeyInputView: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Enter the API key below.")
                .foregroundColor(.white)
            Text("(Input handled via main prompt)")
                .foregroundColor(.white)
            Text("")
            backButton()
        }
    }

    // MARK: - Theme Menu

    private var themeMenu: some View {
        let config = Configuration.load()
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Theme.allCases.indices, id: \.self) { index in
                let theme = Theme.allCases[index]
                let current = theme == config.theme ? " ●" : ""
                menuButton("\(index + 1). \(theme.rawValue)\(current)") {
                    selectTheme(theme)
                }
            }
            backButton()
        }
    }

    // MARK: - Max Tokens View

    private var maxTokensView: some View {
        let current = UserDefaults.maxTokens == 0 ? "default" : String(UserDefaults.maxTokens)
        return VStack(alignment: .leading, spacing: 1) {
            Text("Current: \(current)")
                .foregroundColor(.white)
            Text("Enter value via prompt (0 = default)")
                .foregroundColor(.white)
            Text("")
            backButton()
        }
    }

    // MARK: - Temperature View

    private var temperatureView: some View {
        let current = UserDefaults.temperature == 0 ? "default" : String(format: "%.1f", UserDefaults.temperature)
        return VStack(alignment: .leading, spacing: 1) {
            Text("Current: \(current)")
                .foregroundColor(.white)
            Text("Enter value via prompt (0.0-2.0)")
                .foregroundColor(.white)
            Text("")
            backButton()
        }
    }

    // MARK: - Provider Menu (Hierarchical Model Selection)

    private var providerMenu: some View {
        let currentModel = UserDefaults.model

        return VStack(alignment: .leading, spacing: 0) {
            // Show current model
            Text("Current: \(String(currentModel.rawValue.prefix(22)))")
                .foregroundColor(.cyan)

            Text("")  // Spacer line

            // List providers with model counts
            ForEach(Provider.allCases.indices, id: \.self) { index in
                let provider = Provider.allCases[index]
                let count = Model.chatModelCount(for: provider)
                menuButton("\(index + 1). \(provider.rawValue) (\(count) models)") {
                    mode = .modelList(provider)
                }
            }

            Text("")  // Spacer line
            Text("Or type model name in input")
                .foregroundColor(.white)

            backButton()
        }
    }

    // MARK: - Provider Model List

    private func providerModelList(for provider: Provider) -> some View {
        let currentModel = UserDefaults.model
        let models = Model.chatModels(for: provider)

        return VStack(alignment: .leading, spacing: 0) {
            ForEach(models.indices, id: \.self) { index in
                let model = models[index]
                let current = model == currentModel ? " ●" : ""
                let displayName = String(model.rawValue.prefix(25))
                menuButton("\(index + 1). \(displayName)\(current)") {
                    selectModel(model)
                }
            }
            backButton()
        }
    }

    // MARK: - Helper Views

    private func menuButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .foregroundColor(.white)
                Spacer()
            }
        }
    }

    private func backButton() -> some View {
        Button(action: goBack) {
            HStack {
                Text("0. Back")
                    .foregroundColor(.yellow)
                Spacer()
            }
        }
    }

    private var footerHint: some View {
        Text("↑↓ navigate  Enter select")
            .foregroundColor(.white)
    }

    // MARK: - Actions

    private func closePanel() {
        mode = .none
        onClose()
    }

    private func goBack() {
        switch mode {
        case .apiKeys, .theme, .maxTokens, .temperature, .model, .modelProvider:
            mode = .main
        case .apiKeyInput:
            mode = .apiKeys
        case .modelList:
            mode = .model  // Go back to provider selection
        default:
            closePanel()
        }
    }

    private func toggleStreaming() {
        var config = Configuration.load()
        config.streamingEnabled.toggle()
        do {
            try config.save()
            statusMessage = "Streaming \(config.streamingEnabled ? "enabled" : "disabled")"
        } catch {
            statusMessage = "Failed to save setting"
        }
    }

    private func selectTheme(_ theme: Theme) {
        var config = Configuration.load()
        config.theme = theme
        do {
            try config.save()
            statusMessage = "Theme set to \(theme.rawValue)"
        } catch {
            statusMessage = "Failed to save theme"
        }
        mode = .main
    }

    private func selectModel(_ model: Model) {
        UserDefaults.model = model
        statusMessage = "Model set to \(model.rawValue)"
        mode = .main
    }
}

// MARK: - Preview

#if DEBUG
// Preview requires a wrapper with @State since SwiftTUI doesn't have Binding.constant
struct SettingsPanelPreviewWrapper: View {
    @State private var mode: SettingsMode = .main
    @State private var statusMessage: String = "Ready"

    var body: some View {
        SettingsPanel(
            mode: $mode,
            statusMessage: $statusMessage,
            onClose: {}
        )
    }
}
#endif
