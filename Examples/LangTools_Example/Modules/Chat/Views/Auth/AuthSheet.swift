import SwiftUI

public struct AuthSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var accessManager = ProviderAccessManager.shared
    @State private var openAIKey = ""
    @State private var anthropicKey = ""
    @State private var errorMessage: String?
    @State private var isLoading = false

    private let networkClient: NetworkClientProtocol
    private let preferredService: APIService?

    public init(
        networkClient: NetworkClientProtocol = NetworkClient.shared,
        preferredService: APIService? = nil
    ) {
        self.networkClient = networkClient
        self.preferredService = preferredService
    }

    public var body: some View {
        NavigationStack {
            Form {
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundColor(.red)
                    }
                }

                providerSection(
                    service: .openAI,
                    accountProvider: .openAI,
                    apiKey: $openAIKey,
                    accountButtonTitle: "Sign in with OpenAI"
                )

                providerSection(
                    service: .anthropic,
                    accountProvider: .claudeCode,
                    apiKey: $anthropicKey,
                    accountButtonTitle: "Sign in with Claude Code"
                )

                Section("Notes") {
                    Text("Account login is scaffolded in this branch so model access and provider state can be wired up. Existing API-key flows remain the primary supported request path until account-backed request transport is finalized.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Manage Access")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .disabled(isLoading)
            .onAppear {
                accessManager.refresh()
            }
        }
    }

    @ViewBuilder
    private func providerSection(
        service: APIService,
        accountProvider: AccountLoginProvider,
        apiKey: Binding<String>,
        accountButtonTitle: String
    ) -> some View {
        let state = accessManager.state(for: service)

        Section(service.displayName) {
            Text(state.statusDescription)
                .font(.subheadline)
                .foregroundColor(.secondary)

            if !state.availableModels.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Available models")
                        .font(.headline)
                    Text(state.availableModels.map(\.rawValue).joined(separator: ", "))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            TextField("API Key", text: apiKey)
#if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
#endif

            Button("Save API Key") {
                do {
                    try networkClient.updateApiKey(apiKey.wrappedValue, for: service)
                    accessManager.refresh()
                    apiKey.wrappedValue = ""
                    errorMessage = nil
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            .disabled(apiKey.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            HStack {
                Button(accountButtonTitle) {
                    Task {
                        await connectAccount(accountProvider)
                    }
                }

                if state.hasAccountSession {
                    Button("Disconnect Account", role: .destructive) {
                        Task {
                            await disconnectAccount(accountProvider)
                        }
                    }
                }
            }

            if state.hasAPIKey {
                Button("Remove API Key", role: .destructive) {
                    do {
                        try networkClient.removeApiKey(for: service)
                        accessManager.refresh()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    @MainActor
    private func connectAccount(_ provider: AccountLoginProvider) async {
        isLoading = true
        defer { isLoading = false }

        do {
            try await networkClient.connectAccount(provider)
            accessManager.refresh()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func disconnectAccount(_ provider: AccountLoginProvider) async {
        isLoading = true
        defer { isLoading = false }

        do {
            try await networkClient.disconnectAccount(provider)
            accessManager.refresh()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
