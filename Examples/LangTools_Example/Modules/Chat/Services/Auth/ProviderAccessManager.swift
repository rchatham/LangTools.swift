import Foundation
import Combine
import OpenAI
import Anthropic
import XAI
import Gemini
import Ollama

public final class ProviderAccessManager: ObservableObject {
    public static let shared = ProviderAccessManager()

    @Published public private(set) var states: [APIService: ProviderAccessState] = [:]

    private let keychainService: KeychainService
    private let sessionStore: AuthSessionStore

    public init(
        keychainService: KeychainService = .shared,
        sessionStore: AuthSessionStore = .shared
    ) {
        self.keychainService = keychainService
        self.sessionStore = sessionStore
        refresh()
    }

    public func refresh() {
        var newStates: [APIService: ProviderAccessState] = [:]
        for service in APIService.allCases {
            let apiKey = keychainService.getApiKey(for: service)
            let accountProvider = service.accountLoginProvider
            let session = accountProvider.flatMap { try? sessionStore.session(for: $0) }
            let status = authStatus(apiKey: apiKey, session: session)
            newStates[service] = ProviderAccessState(
                service: service,
                authStatus: status,
                availableModels: availableModels(for: service, apiKey: apiKey, session: session),
                accountIdentifier: session?.accountIdentifier
            )
        }
        states = newStates
    }

    public func saveAccountSession(_ session: AccountSession) throws {
        try sessionStore.save(session)
        refresh()
    }

    public func removeAccountSession(for provider: AccountLoginProvider) throws {
        try sessionStore.removeSession(for: provider)
        refresh()
    }

    public func state(for service: APIService) -> ProviderAccessState {
        states[service] ?? ProviderAccessState(service: service, authStatus: .notConfigured, availableModels: [])
    }

    public func hasAccountSession(for service: APIService) -> Bool {
        state(for: service).hasAccountSession
    }

    public func hasAPIKey(for service: APIService) -> Bool {
        state(for: service).hasAPIKey
    }

    public func session(for provider: AccountLoginProvider) -> AccountSession? {
        try? sessionStore.session(for: provider)
    }

    public func availableChatModels() -> [Model] {
        let configuredServices = Set(states.values.filter { $0.authStatus != .notConfigured }.map(\.service))
        return Model.chatModels.filter { model in
            switch model {
            case .ollama:
                return true
            default:
                return configuredServices.contains(model.apiService)
            }
        }
    }

    public func validateSelectedModel(_ model: Model) -> Model {
        let available = availableChatModels()
        if available.contains(model) {
            return model
        }
        return available.first ?? .openAI(.gpt4o_mini)
    }

    public func accessibleModelIDs(for service: APIService) -> [String] {
        state(for: service).availableModels.map(\.rawValue)
    }

    private func authStatus(apiKey: String?, session: AccountSession?) -> ProviderAuthStatus {
        switch (apiKey?.isEmpty == false, session != nil) {
        case (true, true):
            return .apiKeyAndAccount(session!.provider)
        case (true, false):
            return .apiKeyConfigured
        case (false, true):
            return .accountConnected(session!.provider)
        case (false, false):
            return .notConfigured
        }
    }

    private func availableModels(for service: APIService, apiKey: String?, session: AccountSession?) -> [Model] {
        if service == .ollama {
            return Model.cachedOllamaModels.map { .ollama($0) }
        }

        let hasAPIKey = apiKey?.isEmpty == false
        let hasSession = session != nil

        guard hasAPIKey || hasSession else {
            return []
        }

        if let session, !session.accessibleModelIDs.isEmpty {
            let sessionModels = session.accessibleModelIDs.compactMap(Model.init(rawValue:))
            if !sessionModels.isEmpty {
                return sessionModels
            }
        }

        switch service {
        case .openAI:
            return OpenAI.Model.chatModels.map { .openAI($0) }
        case .anthropic:
            return Anthropic.Model.activeCases.map { .anthropic($0) }
        case .xAI:
            return XAI.Model.allCases.map { .xAI($0) }
        case .gemini:
            return Gemini.Model.allCases.map { .gemini($0) }
        case .ollama:
            return Model.cachedOllamaModels.map { .ollama($0) }
        case .serper:
            return []
        }
    }
}

public final class AuthPresentationCoordinator: ObservableObject {
    public static let shared = AuthPresentationCoordinator()

    @Published public var isPresented = false
    @Published public var preferredService: APIService?

    public func present(preferredService: APIService? = nil) {
        self.preferredService = preferredService
        isPresented = true
    }

    public func dismiss() {
        isPresented = false
        preferredService = nil
    }
}
