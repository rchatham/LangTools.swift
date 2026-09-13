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
        return available.first ?? model
    }

    public func accessibleModelIDs(for service: APIService) -> [String] {
        state(for: service).availableModels.map(\.rawValue)
    }

    public func statesForAccessUI() -> [ProviderAccessState] {
        let openAIState = state(for: .openAI)
        let anthropicState = state(for: .anthropic)
        let codexSession = session(for: .openAI)
        let claudeCodeSession = session(for: .claudeCode)

        return [
            ProviderAccessState(
                service: .openAI,
                route: .openAI,
                accessDestination: .openAI,
                authStatus: openAIState.hasAPIKey ? .apiKeyConfigured : .notConfigured,
                availableModels: openAIState.availableModels.filter { $0.route == .openAI }
            ),
            ProviderAccessState(
                service: .openAI,
                route: .codex,
                accessDestination: .codex,
                authStatus: codexSession.map { .accountConnected($0.provider) } ?? .notConfigured,
                availableModels: openAIState.availableModels.filter { $0.route == .codex },
                accountIdentifier: codexSession?.accountIdentifier
            ),
            ProviderAccessState(
                service: .anthropic,
                accessDestination: .anthropic,
                authStatus: anthropicState.hasAPIKey ? .apiKeyConfigured : .notConfigured,
                availableModels: anthropicState.availableModels.filter { $0.route == .anthropic }
            ),
            ProviderAccessState(
                service: .anthropic,
                accessDestination: .claudeCode,
                authStatus: claudeCodeSession.map { .accountConnected($0.provider) } ?? .notConfigured,
                availableModels: anthropicState.availableModels.filter { $0.route == .claudeCode },
                accountIdentifier: claudeCodeSession?.accountIdentifier
            ),
            accessState(for: .xAI),
            accessState(for: .gemini)
        ]
    }

    private func accessState(for destination: AccessDestination) -> ProviderAccessState {
        let providerState = state(for: destination.service)
        return ProviderAccessState(
            service: destination.service,
            accessDestination: destination,
            authStatus: providerState.hasAPIKey ? .apiKeyConfigured : .notConfigured,
            availableModels: providerState.availableModels
        )
    }

    public func unavailableReason(for state: ProviderAccessState) -> String? {
        guard state.service != .ollama, state.service != .serper else { return nil }
        if state.authStatus == .notConfigured {
            switch state.accessDestination {
            case .openAI:
                return "Add an OpenAI API key to show Platform API models."
            case .codex:
                return "Connect the Codex helper and sign in with your ChatGPT subscription to show Codex models."
            case .anthropic:
                return "Add an Anthropic API key to show Anthropic Platform models."
            case .claudeCode:
                return "Sign in with Claude Code to show account-backed models."
            default:
                return "Connect \(state.displayName) to show its models."
            }
        }
        if state.availableModels.isEmpty {
            return "\(state.displayName) is connected, but no chat models are currently available."
        }
        return nil
    }

    public func unavailableReason(for service: APIService) -> String? {
        unavailableReason(for: state(for: service))
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
                parsed = session.accessibleModelIDs.compactMap { slug in
                    let trimmed = slug.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.isEmpty == false else { return nil }
                    return .codex(OpenAI.Model(rawValue: trimmed) ?? OpenAI.Model(customModelID: trimmed))
                }
            case .anthropic:
                parsed = session.accessibleModelIDs.compactMap { identifier in
                    let slug = identifier.split(separator: "/", maxSplits: 1).last.map(String.init) ?? identifier
                    guard let model = Anthropic.Model(rawValue: slug) else { return nil }
                    return .claudeCode(model)
                }
            case .xAI, .gemini, .ollama, .serper:
                parsed = session.accessibleModelIDs.compactMap(Model.init(rawValue:))
            }
            return parsed
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
    @Published public var preferredDestination: AccessDestination?

    public func present(preferredDestination: AccessDestination? = nil) {
        self.preferredDestination = preferredDestination
        isPresented = true
    }

    public func dismiss() {
        isPresented = false
        preferredDestination = nil
    }
}
