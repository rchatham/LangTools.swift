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
        let applyStates = { self.states = newStates }
        if Thread.isMainThread {
            applyStates()
        } else {
            DispatchQueue.main.async(execute: applyStates)
        }
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
        statesForAccessUI()
            .flatMap(\.availableModels)
            + state(for: .ollama).availableModels
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

    public func statesForAccessUI() -> [ProviderAccessState] {
        APIService.allCases
            .filter { $0 != .ollama && $0 != .serper }
            .map(state(for:))
    }

    public func unavailableReason(for service: APIService) -> String? {
        let state = state(for: service)
        guard service != .ollama, service != .serper else { return nil }
        if state.authStatus == .notConfigured {
            return "Connect \(service.displayName) with an API key or account to show its models."
        }
        if state.availableModels.isEmpty {
            return "\(service.displayName) is connected, but no chat models are currently available."
        }
        return nil
    }

    private func authStatus(apiKey: String?, session: AccountSession?) -> ProviderAuthStatus {
        let hasKey = apiKey?.isEmpty == false
        switch (hasKey, session) {
        case (true, let session?):
            return .apiKeyAndAccount(session.provider)
        case (true, nil):
            return .apiKeyConfigured
        case (false, let session?):
            return .accountConnected(session.provider)
        case (false, nil):
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

        let sessionModels: [Model] = {
            guard let session else { return [] }
            let parsed: [Model]
            switch service {
            case .openAI:
                parsed = session.accessibleModelIDs.compactMap(OpenAI.Model.init(rawValue:)).map(Model.codex)
            case .anthropic, .xAI, .gemini, .ollama, .serper:
                parsed = session.accessibleModelIDs.compactMap(Model.init(rawValue:))
            }
            if parsed.isEmpty == false {
                return parsed
            }
            if service == .openAI {
                return [
                    .codex(.gpt5_5),
                    .codex(.gpt5_4),
                    .codex(.gpt5_4_mini),
                    .codex(.gpt53_codex_spark),
                ]
            }
            return []
        }()

        let platformModels: [Model] = {
            guard hasAPIKey else { return [] }
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
        }()

        if hasSession, hasAPIKey == false {
            return sessionModels
        }

        if hasSession, hasAPIKey {
            return sessionModels + platformModels
        }

        return platformModels
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
