import SwiftUI

private struct ManageAccessPromptModifier: ViewModifier {
    @ObservedObject private var coordinator = AuthPresentationCoordinator.shared
    @ObservedObject private var loginCoordinator = AccountLoginCoordinator.shared
    @ObservedObject private var accessManager = ProviderAccessManager.shared
    @State private var showAPIKeyPrompt = false
    @State private var apiKeyInput = ""
    @State private var apiKeyService: APIService = .openAI
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    @State private var showResultAlert = false
    @State private var resultMessage = ""

    private let networkClient: NetworkClientProtocol

    init(networkClient: NetworkClientProtocol = NetworkClient.shared) {
        self.networkClient = networkClient
    }

    func body(content: Content) -> some View {
        content
            .confirmationDialog(dialogTitle, isPresented: $coordinator.isPresented, titleVisibility: .visible) {
                actionButtons(for: currentService)
            } message: {
                Text(dialogMessage(for: currentService))
            }
            .alert("Enter \(apiKeyService.displayName) API Key", isPresented: $showAPIKeyPrompt) {
                TextField("API Key", text: $apiKeyInput)
                Button("Save") { saveAPIKey() }
                Button("Cancel", role: .cancel) {
                    apiKeyInput = ""
                }
            } message: {
                Text(apiKeyService.description)
            }
            .alert("Access Updated", isPresented: $showResultAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(resultMessage)
            }
            .alert("Access Error", isPresented: $showErrorAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
            .overlay(alignment: .center) {
                if loginCoordinator.isAuthenticating {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.ultraThinMaterial)
                        VStack(spacing: 12) {
                            ProgressView()
                            Text(loginCoordinator.statusMessage)
                                .font(.callout)
                                .multilineTextAlignment(.center)
                        }
                        .padding(20)
                    }
                    .frame(width: 260, height: 120)
                }
            }
    }

    private var currentService: APIService {
        coordinator.preferredService ?? UserDefaults.model.apiService
    }

    private var dialogTitle: String {
        switch currentService {
        case .openAI:
            return "OpenAI Access"
        case .anthropic:
            return "Claude / Anthropic Access"
        default:
            return "\(currentService.displayName) Access"
        }
    }

    @ViewBuilder
    private func actionButtons(for service: APIService) -> some View {
        let state = accessManager.state(for: service)

        switch service {
        case .ollama:
            Button("OK", role: .cancel) {
                coordinator.dismiss()
            }

        case .serper:
            Button("Enter API Key") {
                presentAPIKeyPrompt(for: service)
            }
            Button("Cancel", role: .cancel) {
                coordinator.dismiss()
            }

        default:
            Button("Enter \(service.displayName) API Key") {
                presentAPIKeyPrompt(for: service)
            }

            if let accountProvider = service.accountLoginProvider {
                Button(accountActionTitle(for: accountProvider, state: state)) {
                    coordinator.dismiss()
                    handleAccountAction(for: accountProvider, state: state)
                }
            }

            if state.hasAPIKey {
                Button("Remove API Key", role: .destructive) {
                    removeAPIKey(for: service)
                }
            }

            Button("Cancel", role: .cancel) {
                coordinator.dismiss()
            }
        }
    }

    private func dialogMessage(for service: APIService) -> String {
        let state = accessManager.state(for: service)
        let status = state.statusDescription

        switch service {
        case .openAI:
            return "Models are shown when their provider is configured. OpenAI status: \(status). Add an API key for direct API requests, or sign in with OpenAI via LangToolsAuthCLI to unlock account-based access like Codex."
        case .anthropic:
            return "Models are shown when their provider is configured. Anthropic status: \(status). Add an Anthropic API key or sign in with Claude Code for account-based access."
        case .xAI, .gemini:
            return "\(service.displayName) status: \(status). Use an API key to enable this provider and make its models appear in the picker."
        case .ollama:
            return "Ollama models run locally and do not require API keys or account login."
        case .serper:
            return "Use your Serper API key for web search capabilities."
        }
    }

    private func presentAPIKeyPrompt(for service: APIService) {
        apiKeyService = service
        apiKeyInput = ""
        showAPIKeyPrompt = true
    }

    private func saveAPIKey() {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            presentError("API key cannot be empty.")
            return
        }
        do {
            if apiKeyService == .serper {
                UserDefaults.serperApiKey = trimmed
                KeychainService.shared.saveApiKey(apiKey: trimmed, for: .serper)
            } else {
                try networkClient.updateApiKey(trimmed, for: apiKeyService)
            }
            apiKeyInput = ""
            coordinator.dismiss()
        } catch {
            presentError(error.localizedDescription)
        }
    }

    private func removeAPIKey(for service: APIService) {
        do {
            try networkClient.removeApiKey(for: service)
            coordinator.dismiss()
        } catch {
            presentError(error.localizedDescription)
        }
    }

    private func handleAccountAction(for provider: AccountLoginProvider, state: ProviderAccessState) {
        Task { @MainActor in
            do {
                if state.hasAccountSession {
                    try await networkClient.disconnectAccount(provider)
                    presentResult(disconnectMessage(for: provider))
                } else {
                    try await networkClient.connectAccount(provider)
                    let updatedState = accessManager.state(for: provider.service)
                    presentResult(connectMessage(for: provider, state: updatedState))
                }
                accessManager.refresh()
            } catch {
                presentError(error.localizedDescription)
            }
        }
    }

    private func connectMessage(for provider: AccountLoginProvider, state: ProviderAccessState) -> String {
        let accountLine: String
        if let accountIdentifier = state.accountIdentifier {
            accountLine = "Connected \(provider.displayName) as \(accountIdentifier)."
        } else {
            accountLine = "Connected \(provider.displayName)."
        }

        switch provider {
        case .openAI:
            return "\(accountLine) Return to LangTools Example to continue. Model access has been refreshed, and you can close the browser tab."
        case .claudeCode:
            return "\(accountLine) Return to LangTools Example to continue."
        }
    }

    private func disconnectMessage(for provider: AccountLoginProvider) -> String {
        switch provider {
        case .openAI:
            return "Disconnected OpenAI. Model access has been refreshed."
        case .claudeCode:
            return "Disconnected Claude Code."
        }
    }

    private func accountActionTitle(for provider: AccountLoginProvider, state: ProviderAccessState) -> String {
        if state.hasAccountSession {
            return "Disconnect \(provider.displayName)"
        }
        switch provider {
        case .openAI:
            return "Login with OpenAI via CLI"
        case .claudeCode:
            return "Login with Claude Code"
        }
    }

    private func presentResult(_ message: String) {
        resultMessage = message
        showResultAlert = true
    }

    private func presentError(_ message: String) {
        errorMessage = message
        showErrorAlert = true
    }
}

public extension View {
    func manageAccessPrompts(networkClient: NetworkClientProtocol = NetworkClient.shared) -> some View {
        modifier(ManageAccessPromptModifier(networkClient: networkClient))
    }
}
