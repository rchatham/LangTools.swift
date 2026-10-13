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
    private let ollamaEndpointConfiguration: OllamaEndpointConfiguration
    public let accountTransports: AccountTransportSelectionStore
    private let stateLock = NSLock()
    private var refreshGeneration: UInt64 = 0
    private var transportSubscription: AnyCancellable?

    public init(
        keychainService: KeychainService = .shared,
        sessionStore: AuthSessionStore = .shared,
        ollamaEndpointConfiguration: OllamaEndpointConfiguration = .shared,
        accountTransports: AccountTransportSelectionStore = .shared
    ) {
        self.keychainService = keychainService
        self.sessionStore = sessionStore
        self.ollamaEndpointConfiguration = ollamaEndpointConfiguration
        self.accountTransports = accountTransports
        transportSubscription = NotificationCenter.default.publisher(for: AccountTransportSelectionStore.didChange, object: accountTransports)
            .sink { [weak self] _ in self?.refresh() }
        refresh()
    }

    public func refresh() {
        stateLock.lock()
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let ollamaSnapshot = ollamaEndpointConfiguration.snapshot()
        let accountSnapshots = AccountLoginProvider.allCases.map { accountTransports.snapshot(for: $0) }
        let sessionRevisions = AccountLoginProvider.allCases.map { ($0, sessionStore.revision(for: $0)) }
        stateLock.unlock()

        var newStates: [APIService: ProviderAccessState] = [:]
        for service in APIService.allCases {
            let apiKey = keychainService.getApiKey(for: service)
            let accountProvider = service.accountLoginProvider
            let session = accountProvider.flatMap { provider in
                effectiveSession(for: provider, snapshot: accountSnapshots.first { $0.provider == provider }!)
            }
            let status = authStatus(apiKey: apiKey, session: session)
            newStates[service] = ProviderAccessState(
                service: service,
                authStatus: status,
                availableModels: availableModels(for: service, apiKey: apiKey, session: session, ollamaSnapshot: ollamaSnapshot),
                accountIdentifier: session?.accountIdentifier
            )
        }
        let applyStates = {
            self.stateLock.lock()
            defer { self.stateLock.unlock() }
            // Background refreshes must not restore an older catalog after a
            // newer refresh, server switch, repair, or helper disconnect.
            guard generation == self.refreshGeneration,
                  self.ollamaEndpointConfiguration.isCurrent(ollamaSnapshot),
                  accountSnapshots.allSatisfy(self.accountTransports.isCurrent),
                  sessionRevisions.allSatisfy({ self.sessionStore.revision(for: $0.0) == $0.1 }) else { return }
            self.states = newStates
        }
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

    /// Snapshot of `states` safe to read from any thread (including nonisolated
    /// `async` call sites such as `NetworkClient.ensureModelAccess`). The
    /// dictionary is a value type, so a copy under the lock avoids racing the
    /// main-thread `@Published` write in `refresh()`.
    private func snapshotStates() -> [APIService: ProviderAccessState] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return states
    }

    public func state(for service: APIService) -> ProviderAccessState {
        snapshotStates()[service] ?? ProviderAccessState(service: service, authStatus: .notConfigured, availableModels: [])
    }

    public func hasAccountSession(for service: APIService) -> Bool {
        state(for: service).hasAccountSession
    }

    public func hasAPIKey(for service: APIService) -> Bool {
        state(for: service).hasAPIKey
    }

    public func session(for provider: AccountLoginProvider) -> AccountSession? {
        effectiveSession(for: provider, snapshot: accountTransports.snapshot(for: provider))
    }

    /// Bind authorization and the catalog to the same transport revision before
    /// any network await. A change during secure-store access fails closed;
    /// later changes may not retarget this immutable context.
    func accountRequestContext(for model: Model) throws -> (session: AccountSession, snapshot: AccountTransportSelectionStore.Snapshot)? {
        let provider: AccountLoginProvider
        switch model.route {
        case .codex: provider = .openAI
        case .claudeCode: provider = .claudeCode
        default: return nil
        }
        let snapshot = accountTransports.snapshot(for: provider)
        guard let session = effectiveSession(for: provider, snapshot: snapshot),
              accountTransports.isCurrent(snapshot),
              accountModels(session: session, service: model.apiService).contains(model) else {
            throw NetworkClient.NetworkError.modelAccessUnavailable(model.rawValue)
        }
        return (session, snapshot)
    }

    private func effectiveSession(for provider: AccountLoginProvider, snapshot: AccountTransportSelectionStore.Snapshot) -> AccountSession? {
        guard snapshot.isPaired else { return try? sessionStore.session(for: provider) }
        guard (try? snapshot.requireConnection()) != nil, !snapshot.modelIDs.isEmpty else { return nil }
        if provider == .openAI {
            return AccountSession(provider: .openAI, accountIdentifier: snapshot.accountIdentifier ?? snapshot.helperName ?? "Paired Mac",
                accessToken: CodexSessionMarker.value, accessibleModelIDs: snapshot.modelIDs)
        }
        guard let stored = try? sessionStore.snapshot(for: .claudeCode), let session = stored.session,
              snapshot.accountSessionRevision == stored.revision, !session.isExpired else { return nil }
        return AccountSession(id: session.id, provider: session.provider, accountIdentifier: session.accountIdentifier,
            accessToken: session.accessToken, refreshToken: session.refreshToken, expiresAt: session.expiresAt,
            accessibleModelIDs: snapshot.modelIDs, createdAt: session.createdAt)
    }

    /// Read-only discovery. Codex sign-in stays on the Mac; Claude still requires
    /// an existing external-backend account session, not a local CLI runtime.
    public func refreshPairedAccount(_ provider: AccountLoginProvider) async {
        let snapshot = accountTransports.discoverySnapshot(for: provider)
        guard snapshot.isPaired else { refresh(); return }
        refresh()
        do {
            let stored = provider == .claudeCode ? try sessionStore.snapshot(for: provider) : nil
            let catalog = try await PairedAccountCatalogClient().discover(snapshot: snapshot, session: stored?.session)
            // Session replacement/removal (even A→B→A) invalidates Claude discovery.
            if let stored, sessionStore.revision(for: provider) != stored.revision { refresh(); return }
            _ = accountTransports.publish(modelIDs: catalog.models, accountIdentifier: catalog.identifier, for: snapshot,
                accountSessionRevision: stored?.revision)
        } catch {
            // Health runs before route.data's error mapping. A pin rejection
            // can be -999 too; map with the captured delegate before deciding
            // whether this is an ordinary, silent cancellation.
            let actionable = snapshot.actionableError(error)
            if !(actionable is CancellationError), (actionable as? URLError)?.code != .cancelled {
                _ = accountTransports.fail(actionable, for: snapshot)
            }
        }
        refresh()
    }

    /// A shared device connection must be disconnected across all selected
    /// capabilities. Both stores clear future routes even if secure deletion fails.
    public func disconnectPairedHelper() throws {
        var firstError: Error?
        let registeredID = accountTransports.registeredHelperID
        do { try accountTransports.disconnectHelper() } catch { firstError = error }
        if let ollamaID = ollamaEndpointConfiguration.snapshot().helperID, ollamaID == registeredID {
            do { try ollamaEndpointConfiguration.disconnectHelper() } catch { if firstError == nil { firstError = error } }
        }
        refresh()
        if let firstError { throw firstError }
    }

    public func transportLabel(for model: Model) -> String {
        switch model.route {
        case .codex: return accountTransports.snapshot(for: .openAI).label
        case .claudeCode: return accountTransports.snapshot(for: .claudeCode).label
        case .ollama:
            let snapshot = ollamaEndpointConfiguration.snapshot()
            return snapshot.isHelper ? "LangToolsHelper (\(snapshot.helperName ?? "disconnected"))" : "Direct Ollama"
        default: return "Direct API key"
        }
    }

    public func availableChatModels() -> [Model] {
        statesForAccessUI()
            .flatMap(\.availableModels)
            + state(for: .ollama).availableModels
    }

    /// The user's paired-account route is not consent to use a paid API key.
    /// Catalog loss (including relaunch and disconnect) must require an explicit
    /// replacement, while requests for the preserved model still fail closed.
    func usesPairedAccountTransport(for model: Model) -> Bool {
        switch model.route {
        case .codex: return accountTransports.snapshot(for: .openAI).isPaired
        case .claudeCode: return accountTransports.snapshot(for: .claudeCode).isPaired
        default: return false
        }
    }

    public func validateSelectedModel(_ model: Model) -> Model {
        let available = availableChatModels()
        if available.contains(model) || model.apiService == .ollama || usesPairedAccountTransport(for: model) {
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
                availableModels: accountModels(session: codexSession, service: .openAI),
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
                availableModels: accountModels(session: claudeCodeSession, service: .anthropic),
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
        if let provider = state.accessDestination?.accountProvider {
            let snapshot = accountTransports.snapshot(for: provider)
            if snapshot.isPaired {
                do { _ = try snapshot.requireConnection() }
                catch { return error.localizedDescription }
                if snapshot.modelIDs.isEmpty { return "\(snapshot.label): refresh account models after signing in on the Mac. Claude Code also needs its external backend account session." }
            }
        }
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

    private func availableModels(
        for service: APIService,
        apiKey: String?,
        session: AccountSession?,
        ollamaSnapshot: OllamaEndpointConfiguration.Snapshot
    ) -> [Model] {
        if service == .ollama {
            return ollamaEndpointConfiguration.cachedModels(for: ollamaSnapshot).map { .ollama($0) }
        }

        let hasAPIKey = apiKey?.isEmpty == false
        let hasSession = session != nil

        guard hasAPIKey || hasSession else {
            return []
        }

        let sessionModels = accountModels(session: session, service: service)

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
                return ollamaEndpointConfiguration.cachedModels(for: ollamaSnapshot).map { .ollama($0) }
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

    private func accountModels(session: AccountSession?, service: APIService) -> [Model] {
        guard let session else { return [] }
        switch service {
        case .openAI:
            return AccountSession.normalizedModelIDs(session.accessibleModelIDs).map {
                .codex(OpenAI.Model(rawValue: $0) ?? OpenAI.Model(customModelID: $0))
            }
        case .anthropic:
            return session.accessibleModelIDs.compactMap { identifier in
                let slug = identifier.split(separator: "/", maxSplits: 1).last.map(String.init) ?? identifier
                return Anthropic.Model(rawValue: slug).map { .claudeCode($0) }
            }
        default: return session.accessibleModelIDs.compactMap(Model.init(rawValue:))
        }
    }
}

public final class AuthPresentationCoordinator: ObservableObject {
    public static let shared = AuthPresentationCoordinator()

    @Published public var isPresented = false
    @Published public var preferredDestination: AccessDestination?
    @Published private(set) var presentationOwner: UUID?
    private var presenters: [UUID: (priority: Int, order: UInt64)] = [:]
    private var registrationOrder: UInt64 = 0

    /// Settings sheets/windows own their own prompts while visible. The chat
    /// root stays registered as a fallback, not a second simultaneous presenter.
    func registerPresenter(_ id: UUID, priority: Int) {
        registrationOrder &+= 1
        presenters[id] = (priority, registrationOrder)
        updatePresentationOwner()
    }

    func unregisterPresenter(_ id: UUID) {
        presenters.removeValue(forKey: id)
        updatePresentationOwner()
    }

    private func updatePresentationOwner() {
        let owner = presenters.max {
            if $0.value.priority == $1.value.priority { return $0.value.order < $1.value.order }
            return $0.value.priority < $1.value.priority
        }?.key
        if owner != presentationOwner { presentationOwner = owner }
    }

    public func present(preferredDestination: AccessDestination? = nil) {
        self.preferredDestination = preferredDestination
        isPresented = true
    }

    public func dismiss() {
        isPresented = false
        preferredDestination = nil
    }
}
