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
                actionButtons(for: currentDestination)
            } message: {
                Text(dialogMessage(for: currentDestination))
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

    private var currentDestination: AccessDestination {
        coordinator.preferredDestination ?? AccessDestination.destination(for: UserDefaults.model) ?? .openAI
    }

    private var dialogTitle: String { "\(currentDestination.displayName) Access" }

    @ViewBuilder
    private func actionButtons(for destination: AccessDestination) -> some View {
        let state = accessManager.statesForAccessUI().first { $0.accessDestination == destination }

        if let accountProvider = destination.accountProvider {
            Button(accountActionTitle(for: accountProvider, state: state)) {
                coordinator.dismiss()
                handleAccountAction(for: accountProvider, state: state)
            }
        } else {
            Button("Enter \(destination.displayName) API Key") {
                presentAPIKeyPrompt(for: destination.service)
            }
            if state?.hasAPIKey == true {
                Button("Remove API Key", role: .destructive) {
                    removeAPIKey(for: destination.service)
                }
            }
        }

        Button("Cancel", role: .cancel) {
            coordinator.dismiss()
        }
    }

    private func dialogMessage(for destination: AccessDestination) -> String {
        let state = accessManager.statesForAccessUI().first { $0.accessDestination == destination }
        let status = state?.statusDescription ?? "Not configured"
        switch destination {
        case .openAI:
            return "OpenAI Platform status: \(status). Add an API key for direct Platform API requests."
        case .codex:
            return "Codex Subscription status: \(status). Sign in with your ChatGPT account through the external Codex helper. This does not configure an OpenAI Platform API key."
        case .anthropic:
            return "Anthropic Platform status: \(status). Add an Anthropic API key for direct API requests."
        case .claudeCode:
            return "Claude Code status: \(status). Sign in with Claude Code for account-backed access. This does not configure an Anthropic API key."
        case .xAI, .gemini:
            return "\(destination.displayName) status: \(status). Add an API key to enable this provider."
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

    private func handleAccountAction(for provider: AccountLoginProvider, state: ProviderAccessState?) {
        Task { @MainActor in
            do {
                if state?.hasAccountSession == true {
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

    private func accountActionTitle(for provider: AccountLoginProvider, state: ProviderAccessState?) -> String {
        if state?.hasAccountSession == true {
            return "Disconnect \(provider.displayName)"
        }
        switch provider {
        case .openAI:
            return "Sign in to Codex"
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
