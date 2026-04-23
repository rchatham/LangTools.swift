import SwiftUI

private struct ManageAccessPromptModifier: ViewModifier {
    @StateObject private var coordinator = AuthPresentationCoordinator.shared
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
                    Task {
                        await handleAccountAction(for: accountProvider, state: state)
                    }
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
            return "Current model provider: OpenAI. \(status). API key entry works today. OpenAI OAuth is not implemented in this branch yet."
        case .anthropic:
            return "Current model provider: Anthropic. \(status). API key entry works today. Claude Code login is not implemented in this branch yet."
        case .xAI, .gemini:
            return "Current model provider: \(service.displayName). \(status). Use an API key to enable requests for this provider."
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
        do {
            if apiKeyService == .serper {
                UserDefaults.serperApiKey = apiKeyInput
                KeychainService.shared.saveApiKey(apiKey: apiKeyInput, for: .serper)
            } else {
                try networkClient.updateApiKey(apiKeyInput, for: apiKeyService)
            }
            accessManager.refresh()
            apiKeyInput = ""
            coordinator.dismiss()
        } catch {
            presentError(error.localizedDescription)
        }
    }

    private func removeAPIKey(for service: APIService) {
        do {
            try networkClient.removeApiKey(for: service)
            accessManager.refresh()
            coordinator.dismiss()
        } catch {
            presentError(error.localizedDescription)
        }
    }

    private func handleAccountAction(for provider: AccountLoginProvider, state: ProviderAccessState) async {
        do {
            if state.hasAccountSession {
                try await networkClient.disconnectAccount(provider)
                presentResult("Disconnected \(provider.displayName).")
            } else {
                try await networkClient.connectAccount(provider)
                let updatedState = accessManager.state(for: provider.service)
                if let accountIdentifier = updatedState.accountIdentifier {
                    presentResult("Connected \(provider.displayName) as \(accountIdentifier).")
                } else {
                    presentResult("Connected \(provider.displayName).")
                }
            }
            accessManager.refresh()
        } catch {
            presentError(error.localizedDescription)
        }
    }

    private func accountActionTitle(for provider: AccountLoginProvider, state: ProviderAccessState) -> String {
        if state.hasAccountSession {
            return "Disconnect \(provider.displayName)"
        }
        switch provider {
        case .openAI:
            return "OpenAI OAuth (coming soon)"
        case .claudeCode:
            return "Claude Code Login (coming soon)"
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
