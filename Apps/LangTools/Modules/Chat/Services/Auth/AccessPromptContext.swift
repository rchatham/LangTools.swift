import Foundation

/// Operations and displayed access state for one owned settings graph.
/// No default operation resolves a global client, manager or credential store.
@MainActor
public struct AccessPromptContext {
    public let accessManager: ProviderAccessManager
    let saveAPIKey: (String, APIService) throws -> Void
    let removeAPIKey: (APIService) throws -> Void
    let connectAccount: (AccountLoginProvider) async throws -> Void
    let disconnectAccount: (AccountLoginProvider) async throws -> Void
    let connectCodexHelper: () async throws -> Void
    let disconnectCodexHelper: () async throws -> Void

    public init(
        accessManager: ProviderAccessManager,
        saveAPIKey: @escaping (String, APIService) throws -> Void,
        removeAPIKey: @escaping (APIService) throws -> Void,
        connectAccount: @escaping (AccountLoginProvider) async throws -> Void,
        disconnectAccount: @escaping (AccountLoginProvider) async throws -> Void,
        connectCodexHelper: @escaping () async throws -> Void,
        disconnectCodexHelper: @escaping () async throws -> Void
    ) {
        self.accessManager = accessManager
        self.saveAPIKey = saveAPIKey
        self.removeAPIKey = removeAPIKey
        self.connectAccount = connectAccount
        self.disconnectAccount = disconnectAccount
        self.connectCodexHelper = connectCodexHelper
        self.disconnectCodexHelper = disconnectCodexHelper
    }

    /// Only the selected legacy presentation may resolve these dependencies.
    static func legacy(networkClient: any NetworkClientProtocol) -> Self {
        Self(accessManager: .shared, saveAPIKey: { key, service in
            if service == .serper {
                UserDefaults.serperApiKey = key
                KeychainService.shared.saveApiKey(apiKey: key, for: .serper)
            } else {
                try networkClient.updateApiKey(key, for: service)
            }
        }, removeAPIKey: { try networkClient.removeApiKey(for: $0) },
        connectAccount: { try await networkClient.connectAccount($0) },
        disconnectAccount: { try await networkClient.disconnectAccount($0) },
        connectCodexHelper: { try await networkClient.connectCodexHelper() },
        disconnectCodexHelper: { try await networkClient.disconnectCodexHelper() })
    }
}

/// Shared by the presenter and memory-only tests; never constructs login UI.
@MainActor
struct AccessPromptController {
    let context: AccessPromptContext
    var accessManager: ProviderAccessManager { context.accessManager }

    func saveAPIKey(_ value: String, for service: APIService) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw NetworkClient.NetworkError.emptyApiKey }
        try context.saveAPIKey(trimmed, service)
        accessManager.refresh()
    }

    func removeAPIKey(for service: APIService) throws {
        try context.removeAPIKey(service)
        accessManager.refresh()
    }

    func connectAccount(_ provider: AccountLoginProvider) async throws -> ProviderAccessState {
        try await context.connectAccount(provider)
        accessManager.refresh()
        return accessManager.statesForAccessUI().first { $0.accessDestination?.accountProvider == provider }
            ?? accessManager.state(for: provider.service)
    }

    func disconnectAccount(_ provider: AccountLoginProvider) async throws {
        try await context.disconnectAccount(provider)
        accessManager.refresh()
    }

    func connectCodexHelper() async throws {
        try await context.connectCodexHelper()
        accessManager.refresh()
    }

    func disconnectCodex(usesHelper: Bool) async throws {
        if usesHelper {
            try await context.disconnectCodexHelper()
        } else {
            try await context.disconnectAccount(.openAI)
        }
        accessManager.refresh()
    }
}

/// Selecting the injected route does not evaluate any legacy factory.
@MainActor
enum AccessPromptPresentation {
    case legacy
    case injected(AccessPromptContext)
}
