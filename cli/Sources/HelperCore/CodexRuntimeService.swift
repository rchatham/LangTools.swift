import Foundation
#if os(macOS)
import AppKit
#endif

public struct CodexAccountStatus: Sendable {
    public let authenticated: Bool
    public let accountIdentifier: String?
    public let planType: String?
}

public enum CodexChatStreamEvent: Equatable, Sendable {
    case delta(String)
    case complete(String)
}

private struct CodexThreadScopedNotificationParams: Decodable, Sendable {
    let threadId: String
}

enum CodexContainment {
    static let approvalPolicy = "never"
    static let sandbox = "workspace-write"
    static let networkAccess = false
    static let excludeTmpdirEnvVar = true
    static let excludeSlashTmp = true

    static var isSupported: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    static func sandboxPolicy(workspace: URL) -> CodexSandboxPolicy {
        .workspaceWrite(
            writableRoots: [workspace.path],
            networkAccess: networkAccess,
            excludeTmpdirEnvVar: excludeTmpdirEnvVar,
            excludeSlashTmp: excludeSlashTmp
        )
    }
}

public actor CodexRuntimeService {
    public static let shared: CodexRuntimeService = {
        let workspaces = CodexConversationWorkspace()
        let environment = ProcessInfo.processInfo.environment
        let client = CodexAppServerClient(
            workspaceRootProvider: { workspaces.processRoot },
            codexHomeProvider: { CodexSeatbeltProfile.resolvedCodexHome(environment: environment) }
        )
        return CodexRuntimeService(client: client, workspaces: workspaces)
    }()
    static let sessionMarker = "langtools-codex-app-server-session-v1"
    static let maximumResponseBytes = 8 * 1_048_576
    static let maximumBufferedStreamEvents = 256

    typealias BrowserOpener = @Sendable (URL) throws -> Void
    typealias LoginStartResponseCheckpoint = @Sendable () async -> Void

    private enum ServicePhase: Equatable {
        case active
        case draining(UUID)
        case shutdown
    }

    private enum ConversationPhase {
        case active
        case terminating
    }

    private struct ServiceOperationToken {
        let id: UUID
        let generation: UUID
    }

    private struct ServiceDrain {
        let id: UUID
        let operationIDs: Set<UUID>
    }

    private enum LoginStartPhase {
        case notSent
        case mayExist
        case identified(String)

        var requiresCleanup: Bool {
            switch self {
            case .notSent: false
            case .mayExist, .identified: true
            }
        }
    }

    private enum LoginCleanupOwner: Equatable {
        case operation
        case drain(UUID)
        case shutdown
    }

    private struct ServiceOperationState {
        let generation: UUID
        var loginStartPhase: LoginStartPhase
        var loginSubscription: CodexNotificationSubscription?
        var loginCleanupOwner: LoginCleanupOwner?
        var loginCleanupFinished: Bool
        var operationBodyFinished: Bool
    }

    private struct ServiceOperationWaiter {
        var remainingIDs: Set<UUID>
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct ConversationState {
        let lifecycleID: UUID
        var phase: ConversationPhase
        var threadID: String?
        var processGeneration: UUID?
        var modelSlug: String
        let workspaceURL: URL
        var expectedTranscript: [HelperChatMessage]
        var lastAccess: Date
        var idleCleanupTask: Task<Void, Never>?
        var activeOperation: Task<String, Error>?
        var activeTurn: ChatTurnContext?
        var requiresReconstruction: Bool
    }

    private let client: CodexAppServerClient
    private let browserOpener: BrowserOpener
    private let loginStartResponseCheckpoint: LoginStartResponseCheckpoint
    private let loginStartTimeout: Duration
    private let loginCompletionTimeout: Duration
    private let turnCompletionTimeout: Duration
    private let conversationIdleTimeout: Duration
    private let responseByteLimit: Int
    private let workspaces: CodexConversationWorkspace
    private var conversations: [UUID: ConversationState] = [:]
    private var servicePhase: ServicePhase = .active
    private var serviceGeneration = UUID()
    private var serviceOperations: [UUID: ServiceOperationState] = [:]
    private var serviceOperationWaiters: [UUID: ServiceOperationWaiter] = [:]
    private var loginInProgress = false

    init(
        client: CodexAppServerClient,
        browserOpener: @escaping BrowserOpener = { try CodexRuntimeService.openBrowser($0) },
        loginStartResponseCheckpoint: @escaping LoginStartResponseCheckpoint = {},
        loginStartTimeout: Duration = .seconds(30),
        loginCompletionTimeout: Duration = .seconds(300),
        turnCompletionTimeout: Duration = .seconds(120),
        conversationIdleTimeout: Duration = .seconds(1_800),
        responseByteLimit: Int = CodexRuntimeService.maximumResponseBytes,
        workspaces: CodexConversationWorkspace = CodexConversationWorkspace()
    ) {
        self.client = client
        self.browserOpener = browserOpener
        self.loginStartResponseCheckpoint = loginStartResponseCheckpoint
        self.loginStartTimeout = loginStartTimeout
        self.loginCompletionTimeout = loginCompletionTimeout
        self.turnCompletionTimeout = turnCompletionTimeout
        self.conversationIdleTimeout = conversationIdleTimeout
        self.responseByteLimit = max(0, responseByteLimit)
        self.workspaces = workspaces
    }

    public func accountStatus(refreshToken: Bool = false) async throws -> CodexAccountStatus {
        let operation = try beginServiceOperation()
        defer { finishServiceOperation(operation.id) }
        return try await readAccountStatus(refreshToken: refreshToken, operation: operation)
    }

    public func login() async throws -> StoredAccountSession {
        guard loginInProgress == false else {
            throw CodexRuntimeError.accountConflict("A ChatGPT login is already in progress.")
        }
        let operation = try beginServiceOperation()
        loginInProgress = true
        defer {
            loginInProgress = false
            finishServiceOperation(operation.id)
        }

        do {
            let current: CodexGetAccountResponse = try await client.request(
                method: "account/read",
                params: CodexGetAccountParams(refreshToken: false),
                cancellationScope: operation.id
            )
            try validateServiceOperation(operation)
            if let account = current.account {
                guard case .chatgpt = account else {
                    throw CodexRuntimeError.accountConflict("Codex already has a non-ChatGPT account configured.")
                }
                let session = try await makeSession(refreshToken: true, operation: operation)
                try validateServiceOperation(operation)
                return session
            }

            let createdSubscription = await client.subscribeToNotifications(methods: ["account/login/completed"])
            updateLoginOperation(operation.id, subscription: createdSubscription)
            try validateServiceOperation(operation)

            updateLoginOperation(operation.id, loginStartPhase: .mayExist)
            let response: CodexLoginAccountResponse = try await client.request(
                method: "account/login/start",
                params: CodexChatGPTLoginParams(codexStreamlinedLogin: true),
                timeout: loginStartTimeout,
                cancellationScope: operation.id
            )
            try Task.checkCancellation()
            await loginStartResponseCheckpoint()
            try Task.checkCancellation()
            try validateServiceOperation(operation)
            guard case .chatgpt(let returnedLoginID, let authURLString) = response else {
                throw CodexRuntimeError.invalidResponse("Codex did not return a ChatGPT browser login URL.")
            }
            updateLoginOperation(operation.id, loginStartPhase: .identified(returnedLoginID))

            guard let authURL = URL(string: authURLString), Self.isAllowedAuthURL(authURL) else {
                throw CodexRuntimeError.invalidResponse("Codex returned an unsafe ChatGPT browser login URL.")
            }
            try Task.checkCancellation()
            try browserOpener(authURL)
            let notification = try await client.nextNotification(
                from: createdSubscription,
                timeout: loginCompletionTimeout,
                matching: { data in
                    (try? JSONDecoder().decode(CodexAccountLoginCompletedNotification.self, from: data).loginId) == returnedLoginID
                }
            )
            try validateServiceOperation(operation)
            let completed = try JSONDecoder().decode(CodexAccountLoginCompletedNotification.self, from: notification.params)
            guard completed.success else {
                throw CodexRuntimeError.authentication(completed.error ?? "ChatGPT login failed.")
            }
            let session = try await makeSession(refreshToken: true, operation: operation)
            try validateServiceOperation(operation)
            await client.cancelNotificationSubscription(createdSubscription)
            try validateServiceOperation(operation)
            return session
        } catch {
            if claimLoginCleanup(operation) {
                await Task.detached { [self] in
                    try? await cleanupServiceOperations(
                        [operation.id],
                        owner: .operation,
                        allowsRestart: true
                    )
                }.value
            }
            throw error
        }
    }

    public func logout() async throws {
        let drain = try beginServiceDrain()
        do {
            try await cleanupServiceOperations(
                drain.operationIDs,
                owner: .drain(drain.id),
                allowsRestart: true
            )
            try validateServiceDrain(drain.id)
            await waitForServiceOperations(drain.operationIDs)
            try validateServiceDrain(drain.id)
            let before: CodexGetAccountResponse = try await client.request(
                method: "account/read",
                params: CodexGetAccountParams(refreshToken: false)
            )
            try validateServiceDrain(drain.id)
            if let account = before.account {
                guard case .chatgpt = account else {
                    throw CodexRuntimeError.accountConflict("Refusing to log out a non-ChatGPT Codex account.")
                }
                let _: CodexLogoutAccountResponse = try await client.request(
                    method: "account/logout",
                    params: CodexEmptyParams()
                )
                try validateServiceDrain(drain.id)
                let after: CodexGetAccountResponse = try await client.request(
                    method: "account/read",
                    params: CodexGetAccountParams(refreshToken: false)
                )
                try validateServiceDrain(drain.id)
                guard after.account == nil else {
                    throw CodexRuntimeError.invalidResponse("Codex reported logout success but the account is still present.")
                }
            }
            await drainTerminatingConversations()
            try validateServiceDrain(drain.id)
            reopenAfterDrain(drain.id)
        } catch {
            await waitForServiceOperations(drain.operationIDs)
            await drainTerminatingConversations()
            reopenAfterDrain(drain.id)
            throw error
        }
    }

    public func modelSlugs() async throws -> [String] {
        let operation = try beginServiceOperation()
        defer { finishServiceOperation(operation.id) }
        return try await loadModelSlugs(operation: operation)
    }

    func chat(
        model: String,
        messages: [HelperChatMessage],
        conversationID: UUID? = nil
    ) async throws -> String {
        try await chat(
            model: model,
            messages: messages,
            conversationID: conversationID,
            onDelta: { _ in }
        )
    }

    public func chatStream(
        model: String,
        messages: [HelperChatMessage],
        conversationID: UUID? = nil
    ) -> AsyncThrowingStream<CodexChatStreamEvent, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(Self.maximumBufferedStreamEvents)) { continuation in
            let producer = Task { [weak self] in
                guard let self else {
                    continuation.finish(throwing: CancellationError())
                    return
                }
                do {
                    let response = try await self.chat(
                        model: model,
                        messages: messages,
                        conversationID: conversationID,
                        onDelta: { delta in
                            switch continuation.yield(.delta(delta)) {
                            case .enqueued: return
                            case .dropped:
                                throw CodexRuntimeError.runtime("The response stream consumer could not keep up.")
                            case .terminated:
                                throw CancellationError()
                            @unknown default:
                                throw CodexRuntimeError.runtime("The response stream entered an unknown state.")
                            }
                        }
                    )
                    switch continuation.yield(.complete(response)) {
                    case .enqueued:
                        continuation.finish()
                    case .dropped:
                        continuation.finish(throwing: CodexRuntimeError.runtime("The response stream consumer could not keep up."))
                    case .terminated:
                        return
                    @unknown default:
                        continuation.finish(throwing: CodexRuntimeError.runtime("The response stream entered an unknown state."))
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }

    private func chat(
        model: String,
        messages: [HelperChatMessage],
        conversationID: UUID?,
        onDelta: @escaping @Sendable (String) throws -> Void
    ) async throws -> String {
        guard servicePhase == .active else {
            throw CodexRuntimeError.accountConflict("Codex runtime is draining or shut down.")
        }
        let slug = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard slug.isEmpty == false else { throw CodexRuntimeError.badRequest("A model slug is required.") }
        guard messages.isEmpty == false else { throw CodexRuntimeError.badRequest("At least one chat message is required.") }

        guard let conversationID else {
            let ephemeralID = UUID()
            do {
                let response = try await chat(
                    model: slug,
                    messages: messages,
                    conversationID: ephemeralID,
                    onDelta: onDelta
                )
                await endConversation(id: ephemeralID)
                return response
            } catch {
                await endConversation(id: ephemeralID)
                throw error
            }
        }
        if let existing = conversations[conversationID] {
            guard existing.phase == .active, existing.activeOperation == nil else {
                throw CodexRuntimeError.accountConflict("A turn is already active or the conversation is terminating.")
            }
        }

        let lifecycleID: UUID
        if var state = conversations[conversationID] {
            lifecycleID = state.lifecycleID
            state.idleCleanupTask?.cancel()
            state.idleCleanupTask = nil
            state.lastAccess = Date()
            conversations[conversationID] = state
        } else {
            lifecycleID = UUID()
            let workspace = try workspaces.createWorkspace(for: conversationID)
            conversations[conversationID] = ConversationState(
                lifecycleID: lifecycleID,
                phase: .active,
                threadID: nil,
                processGeneration: nil,
                modelSlug: slug,
                workspaceURL: workspace,
                expectedTranscript: [],
                lastAccess: Date(),
                idleCleanupTask: nil,
                activeOperation: nil,
                activeTurn: nil,
                requiresReconstruction: true
            )
        }

        let operation = Task {
            try await self.performConversationTurn(
                conversationID: conversationID,
                lifecycleID: lifecycleID,
                model: slug,
                messages: messages,
                onDelta: onDelta
            )
        }
        conversations[conversationID]?.activeOperation = operation

        do {
            let response = try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: {
                operation.cancel()
            }
            try validateActiveLifecycle(conversationID, lifecycleID: lifecycleID)
            conversations[conversationID]?.expectedTranscript = messages + [
                HelperChatMessage(role: "assistant", content: response)
            ]
            conversations[conversationID]?.activeOperation = nil
            conversations[conversationID]?.activeTurn = nil
            conversations[conversationID]?.requiresReconstruction = false
            conversations[conversationID]?.lastAccess = Date()
            scheduleIdleCleanup(for: conversationID, lifecycleID: lifecycleID)
            return response
        } catch {
            if isActiveLifecycle(conversationID, lifecycleID: lifecycleID) {
                conversations[conversationID]?.activeOperation = nil
                conversations[conversationID]?.activeTurn = nil
                conversations[conversationID]?.requiresReconstruction = true
                conversations[conversationID]?.lastAccess = Date()
                scheduleIdleCleanup(for: conversationID, lifecycleID: lifecycleID)
            }
            throw error
        }
    }

    public func endConversation(id: UUID) async {
        guard let lifecycleID = markConversationTerminating(id: id) else { return }
        await cleanupTerminatingConversation(id: id, lifecycleID: lifecycleID)
    }

    public func shutdown() async {
        guard servicePhase != .shutdown else { return }
        serviceGeneration = UUID()
        let operationIDs = Set(serviceOperations.keys)
        servicePhase = .shutdown
        claimLoginCleanup(operationIDs, owner: .shutdown)
        markAllConversationsTerminating()
        for id in operationIDs {
            await client.cancelRequests(in: id)
        }
        await client.shutdown()
        try? await cleanupServiceOperations(operationIDs, owner: .shutdown, allowsRestart: false)
        await waitForServiceOperations(operationIDs)
        await drainTerminatingConversations()
        workspaces.removeAllWorkspaces()
    }

    private func performConversationTurn(
        conversationID: UUID,
        lifecycleID: UUID,
        model: String,
        messages: [HelperChatMessage],
        onDelta: @escaping @Sendable (String) throws -> Void
    ) async throws -> String {
        var state = try activeState(conversationID, lifecycleID: lifecycleID)
        let generation = try await client.initializedProcessGeneration()
        try validateActiveLifecycle(conversationID, lifecycleID: lifecycleID)

        let reconstruct = state.requiresReconstruction
            || state.threadID == nil
            || state.modelSlug != model
            || state.processGeneration != generation
        let turnMessages: [HelperChatMessage]
        if reconstruct {
            let thread = try await startThread(
                model: model,
                workspace: state.workspaceURL,
                lifecycle: (conversationID, lifecycleID)
            )
            try validateActiveLifecycle(conversationID, lifecycleID: lifecycleID)
            state.threadID = thread.id
            state.processGeneration = thread.generation
            state.modelSlug = model
            state.requiresReconstruction = false
            conversations[conversationID] = state
            turnMessages = messages
        } else if messages == state.expectedTranscript {
            throw CodexRuntimeError.badRequest("The conversation request must include new input.")
        } else if messages.count > state.expectedTranscript.count,
                  Array(messages.prefix(state.expectedTranscript.count)) == state.expectedTranscript {
            turnMessages = Array(messages.dropFirst(state.expectedTranscript.count))
        } else {
            let thread = try await startThread(
                model: model,
                workspace: state.workspaceURL,
                lifecycle: (conversationID, lifecycleID)
            )
            try validateActiveLifecycle(conversationID, lifecycleID: lifecycleID)
            state.threadID = thread.id
            state.processGeneration = thread.generation
            state.modelSlug = model
            conversations[conversationID] = state
            return try await executeConversationTurnWithStaleRetry(
                conversationID: conversationID,
                lifecycleID: lifecycleID,
                model: model,
                workspace: state.workspaceURL,
                messages: messages,
                onDelta: onDelta
            )
        }

        return try await executeConversationTurnWithStaleRetry(
            conversationID: conversationID,
            lifecycleID: lifecycleID,
            model: model,
            workspace: state.workspaceURL,
            messages: turnMessages,
            retryMessages: messages,
            onDelta: onDelta
        )
    }

    private func executeConversationTurnWithStaleRetry(
        conversationID: UUID,
        lifecycleID: UUID,
        model: String,
        workspace: URL,
        messages: [HelperChatMessage],
        retryMessages: [HelperChatMessage]? = nil,
        onDelta: @escaping @Sendable (String) throws -> Void
    ) async throws -> String {
        let state = try activeState(conversationID, lifecycleID: lifecycleID)
        guard let threadID = state.threadID else {
            throw CodexRuntimeError.invalidResponse("Codex conversation has no thread.")
        }
        do {
            let response = try await executeTurn(
                threadID: threadID,
                model: model,
                workspace: workspace,
                messages: messages,
                lifecycle: (conversationID, lifecycleID),
                onDelta: onDelta
            )
            try validateActiveLifecycle(conversationID, lifecycleID: lifecycleID)
            return response
        } catch InternalTurnStartError.staleThread {
            try validateActiveLifecycle(conversationID, lifecycleID: lifecycleID)
            let thread = try await startThread(
                model: model,
                workspace: workspace,
                lifecycle: (conversationID, lifecycleID)
            )
            try validateActiveLifecycle(conversationID, lifecycleID: lifecycleID)
            conversations[conversationID]?.threadID = thread.id
            conversations[conversationID]?.processGeneration = thread.generation
            conversations[conversationID]?.modelSlug = model
            let response = try await executeTurn(
                threadID: thread.id,
                model: model,
                workspace: workspace,
                messages: retryMessages ?? messages,
                lifecycle: (conversationID, lifecycleID),
                allowStaleThreadMapping: false,
                onDelta: onDelta
            )
            try validateActiveLifecycle(conversationID, lifecycleID: lifecycleID)
            return response
        }
    }

    private func startThread(
        model: String,
        workspace: URL,
        lifecycle: (conversationID: UUID, lifecycleID: UUID)? = nil
    ) async throws -> (id: String, generation: UUID) {
        guard CodexContainment.isSupported else {
            throw CodexRuntimeError.runtime("Codex account chat containment is supported only on macOS.")
        }
        let thread: CodexThreadStartResponse = try await client.request(
            method: "thread/start",
            params: CodexThreadStartParams(
                model: model,
                cwd: workspace.path,
                approvalPolicy: CodexContainment.approvalPolicy,
                sandbox: CodexContainment.sandbox,
                ephemeral: true
            )
        )
        if let lifecycle {
            try validateActiveLifecycle(lifecycle.conversationID, lifecycleID: lifecycle.lifecycleID)
        }
        let generation = try await client.initializedProcessGeneration()
        if let lifecycle {
            try validateActiveLifecycle(lifecycle.conversationID, lifecycleID: lifecycle.lifecycleID)
        }
        return (thread.thread.id, generation)
    }

    private func executeTurn(
        threadID: String,
        model: String,
        workspace: URL,
        messages: [HelperChatMessage],
        lifecycle: (conversationID: UUID, lifecycleID: UUID)? = nil,
        allowStaleThreadMapping: Bool = true,
        onDelta: @escaping @Sendable (String) throws -> Void
    ) async throws -> String {
        let context = ChatTurnContext(threadID: threadID)
        if let lifecycle {
            try validateActiveLifecycle(lifecycle.conversationID, lifecycleID: lifecycle.lifecycleID)
            conversations[lifecycle.conversationID]?.activeTurn = context
        }
        let subscription = await client.subscribeToNotifications(
            methods: ["item/agentMessage/delta", "turn/completed", "error"],
            accepts: { data in
                (try? JSONDecoder().decode(CodexThreadScopedNotificationParams.self, from: data).threadId) == threadID
            }
        )
        do {
            if let lifecycle {
                try validateActiveLifecycle(lifecycle.conversationID, lifecycleID: lifecycle.lifecycleID)
            }
            let started: CodexTurnStartResponse
            do {
                started = try await client.request(
                    method: "turn/start",
                    params: CodexTurnStartParams(
                        threadId: threadID,
                        input: [.init(text: Self.renderPrompt(messages: messages))],
                        approvalPolicy: CodexContainment.approvalPolicy,
                        sandboxPolicy: CodexContainment.sandboxPolicy(workspace: workspace),
                        model: model
                    ),
                    cancelOnTaskCancellation: false
                )
            } catch {
                if case CodexAppServerError.timeout(let method) = error, method == "turn/start" {
                    // The server may have started a turn whose ID was lost with the
                    // timed-out response. Restarting is the only fail-closed way to
                    // guarantee that unknown turn cannot continue.
                    try? await client.restart()
                    throw error
                }
                if allowStaleThreadMapping, Self.isStaleThreadError(error) {
                    throw InternalTurnStartError.staleThread
                }
                throw error
            }
            // Capture the returned ID before lifecycle validation so cleanup can
            // always interrupt a turn/start response that raced termination.
            context.setTurnID(started.turn.id)
            if let lifecycle {
                try validateActiveLifecycle(lifecycle.conversationID, lifecycleID: lifecycle.lifecycleID)
            }
            try Task.checkCancellation()
            let response = try await collectResponse(
                subscription: subscription,
                threadID: threadID,
                turnID: started.turn.id,
                onDelta: onDelta
            )
            if let lifecycle {
                try validateActiveLifecycle(lifecycle.conversationID, lifecycleID: lifecycle.lifecycleID)
            }
            await client.cancelNotificationSubscription(subscription)
            if let lifecycle {
                try validateActiveLifecycle(lifecycle.conversationID, lifecycleID: lifecycle.lifecycleID)
            }
            return response
        } catch {
            await client.cancelNotificationSubscription(subscription)
            await interruptTurnIfAvailable(context)
            throw error
        }
    }

    private func scheduleIdleCleanup(for conversationID: UUID, lifecycleID: UUID) {
        conversations[conversationID]?.idleCleanupTask?.cancel()
        let lastAccess = conversations[conversationID]?.lastAccess
        let idleTimeout = conversationIdleTimeout
        conversations[conversationID]?.idleCleanupTask = Task { [weak self] in
            do { try await Task.sleep(for: idleTimeout) }
            catch { return }
            await self?.expireConversation(id: conversationID, lifecycleID: lifecycleID, lastAccess: lastAccess)
        }
    }

    private func expireConversation(id: UUID, lifecycleID: UUID, lastAccess: Date?) async {
        guard isActiveLifecycle(id, lifecycleID: lifecycleID),
              conversations[id]?.lastAccess == lastAccess,
              conversations[id]?.activeOperation == nil
        else { return }
        await endConversation(id: id)
    }

    private func activeState(_ id: UUID, lifecycleID: UUID) throws -> ConversationState {
        try validateActiveLifecycle(id, lifecycleID: lifecycleID)
        guard let state = conversations[id] else { throw CancellationError() }
        return state
    }

    private func validateActiveLifecycle(_ id: UUID, lifecycleID: UUID) throws {
        guard isActiveLifecycle(id, lifecycleID: lifecycleID) else { throw CancellationError() }
    }

    private func isActiveLifecycle(_ id: UUID, lifecycleID: UUID) -> Bool {
        conversations[id]?.lifecycleID == lifecycleID && conversations[id]?.phase == .active
    }

    private func beginServiceOperation() throws -> ServiceOperationToken {
        guard servicePhase == .active else {
            throw CodexRuntimeError.accountConflict("Codex runtime is draining or shut down.")
        }
        let token = ServiceOperationToken(id: UUID(), generation: serviceGeneration)
        serviceOperations[token.id] = ServiceOperationState(
            generation: token.generation,
            loginStartPhase: .notSent,
            loginSubscription: nil,
            loginCleanupOwner: nil,
            loginCleanupFinished: false,
            operationBodyFinished: false
        )
        return token
    }

    private func validateServiceOperation(_ operation: ServiceOperationToken) throws {
        guard isCurrentServiceOperation(operation) else { throw CancellationError() }
    }

    private func isCurrentServiceOperation(_ operation: ServiceOperationToken) -> Bool {
        servicePhase == .active
            && serviceGeneration == operation.generation
            && serviceOperations[operation.id]?.generation == operation.generation
    }

    private func finishServiceOperation(_ id: UUID) {
        guard var operation = serviceOperations[id] else { return }
        if operation.loginCleanupOwner != nil, operation.loginCleanupFinished == false {
            operation.operationBodyFinished = true
            serviceOperations[id] = operation
            return
        }
        removeServiceOperation(id)
    }

    private func removeServiceOperation(_ id: UUID) {
        serviceOperations.removeValue(forKey: id)
        let client = self.client
        Task { await client.closeRequestCancellationScope(id) }
        for waiterID in Array(serviceOperationWaiters.keys) {
            guard var waiter = serviceOperationWaiters[waiterID] else { continue }
            waiter.remainingIDs.remove(id)
            if waiter.remainingIDs.isEmpty {
                serviceOperationWaiters.removeValue(forKey: waiterID)
                waiter.continuation.resume()
            } else {
                serviceOperationWaiters[waiterID] = waiter
            }
        }
    }

    private func updateLoginOperation(
        _ id: UUID,
        loginStartPhase: LoginStartPhase? = nil,
        subscription: CodexNotificationSubscription? = nil
    ) {
        guard var operation = serviceOperations[id] else { return }
        if let loginStartPhase { operation.loginStartPhase = loginStartPhase }
        if let subscription { operation.loginSubscription = subscription }
        serviceOperations[id] = operation
    }

    private func beginServiceDrain() throws -> ServiceDrain {
        guard servicePhase == .active else {
            throw CodexRuntimeError.accountConflict("Codex runtime is already draining or shut down.")
        }
        let drainID = UUID()
        let operationIDs = Set(serviceOperations.keys)
        serviceGeneration = UUID()
        servicePhase = .draining(drainID)
        claimLoginCleanup(operationIDs, owner: .drain(drainID))
        markAllConversationsTerminating()
        return ServiceDrain(id: drainID, operationIDs: operationIDs)
    }

    private func validateServiceDrain(_ drainID: UUID) throws {
        guard servicePhase == .draining(drainID) else { throw CancellationError() }
    }

    private func claimLoginCleanup(_ operation: ServiceOperationToken) -> Bool {
        guard isCurrentServiceOperation(operation),
              var state = serviceOperations[operation.id],
              state.loginCleanupOwner == nil,
              state.loginStartPhase.requiresCleanup
        else { return false }
        state.loginCleanupOwner = .operation
        serviceOperations[operation.id] = state
        return true
    }

    private func claimLoginCleanup(_ operationIDs: Set<UUID>, owner: LoginCleanupOwner) {
        for id in operationIDs {
            guard var operation = serviceOperations[id],
                  operation.loginCleanupOwner == nil,
                  operation.loginStartPhase.requiresCleanup
            else { continue }
            operation.loginCleanupOwner = owner
            serviceOperations[id] = operation
        }
    }

    private func cleanupServiceOperations(
        _ operationIDs: Set<UUID>,
        owner: LoginCleanupOwner,
        allowsRestart: Bool
    ) async throws {
        defer { finishLoginCleanup(operationIDs, owner: owner) }
        let ownedOperations = operationIDs.compactMap { id -> ServiceOperationState? in
            guard let operation = serviceOperations[id], operation.loginCleanupOwner == owner else { return nil }
            return operation
        }
        let loginIDs = ownedOperations.compactMap { operation -> String? in
            guard case .identified(let loginID) = operation.loginStartPhase else { return nil }
            return loginID
        }
        let hasUnidentifiedLogin = ownedOperations.contains { operation in
            guard case .mayExist = operation.loginStartPhase else { return false }
            return true
        }

        for id in operationIDs {
            await client.cancelRequests(in: id)
        }
        for subscription in ownedOperations.compactMap(\.loginSubscription) {
            await client.cancelNotificationSubscription(subscription)
        }
        var exactCancellationFailed = false
        for loginID in loginIDs {
            if await cancelLogin(loginID: loginID) == false {
                exactCancellationFailed = true
            }
        }
        guard allowsRestart,
              hasUnidentifiedLogin || exactCancellationFailed,
              servicePhase != .shutdown
        else { return }
        try await client.restart()
    }

    private func finishLoginCleanup(_ operationIDs: Set<UUID>, owner: LoginCleanupOwner) {
        for id in operationIDs {
            guard var operation = serviceOperations[id], operation.loginCleanupOwner == owner else { continue }
            operation.loginCleanupFinished = true
            serviceOperations[id] = operation
            if operation.operationBodyFinished {
                removeServiceOperation(id)
            }
        }
    }

    private func waitForServiceOperations(_ operationIDs: Set<UUID>) async {
        let remaining = operationIDs.intersection(serviceOperations.keys)
        guard remaining.isEmpty == false else { return }
        let waiterID = UUID()
        await withCheckedContinuation { continuation in
            serviceOperationWaiters[waiterID] = ServiceOperationWaiter(
                remainingIDs: remaining,
                continuation: continuation
            )
        }
    }

    private func reopenAfterDrain(_ drainID: UUID) {
        guard servicePhase == .draining(drainID) else { return }
        servicePhase = .active
    }

    private func markAllConversationsTerminating() {
        for id in Array(conversations.keys) {
            _ = markConversationTerminating(id: id)
        }
    }

    private func markConversationTerminating(id: UUID) -> UUID? {
        guard var state = conversations[id] else { return nil }
        if state.phase == .active {
            state.phase = .terminating
            state.idleCleanupTask?.cancel()
            state.idleCleanupTask = nil
            state.activeOperation?.cancel()
            conversations[id] = state
        }
        return state.lifecycleID
    }

    private func drainTerminatingConversations() async {
        let lifecycles = conversations.map { ($0.key, $0.value.lifecycleID) }
        for (id, lifecycleID) in lifecycles {
            await cleanupTerminatingConversation(id: id, lifecycleID: lifecycleID)
        }
    }

    private func cleanupTerminatingConversation(id: UUID, lifecycleID: UUID) async {
        guard let state = conversations[id],
              state.lifecycleID == lifecycleID,
              state.phase == .terminating
        else { return }
        if let activeTurn = state.activeTurn {
            await interruptTurnIfAvailable(activeTurn)
        }
        if let operation = state.activeOperation {
            _ = await operation.result
        }
        guard conversations[id]?.lifecycleID == lifecycleID,
              conversations[id]?.phase == .terminating
        else { return }
        workspaces.removeWorkspace(state.workspaceURL)
        if conversations[id]?.lifecycleID == lifecycleID {
            conversations.removeValue(forKey: id)
        }
    }

    private static func isStaleThreadError(_ error: Error) -> Bool {
        let message: String
        switch error {
        case CodexAppServerError.invalidRequest(let value): message = value
        case CodexAppServerError.server(_, let value): message = value
        default: return false
        }
        let lower = message.lowercased()
        guard lower.contains("thread") else { return false }
        return lower.contains("not found")
            || lower.contains("does not exist")
            || lower.contains("unknown thread")
            || lower.contains("invalid thread")
            || lower.contains("stale thread")
    }

    private func readAccountStatus(
        refreshToken: Bool,
        operation: ServiceOperationToken
    ) async throws -> CodexAccountStatus {
        let response: CodexGetAccountResponse = try await client.request(
            method: "account/read",
            params: CodexGetAccountParams(refreshToken: refreshToken),
            cancellationScope: operation.id
        )
        try validateServiceOperation(operation)
        guard let account = response.account else {
            return CodexAccountStatus(authenticated: false, accountIdentifier: nil, planType: nil)
        }
        switch account {
        case .chatgpt(let email, let planType):
            let identifier = email?.trimmingCharacters(in: .whitespacesAndNewlines)
            return CodexAccountStatus(
                authenticated: true,
                accountIdentifier: identifier?.isEmpty == false ? identifier : "ChatGPT Account",
                planType: planType
            )
        case .apiKey, .amazonBedrock:
            return CodexAccountStatus(authenticated: false, accountIdentifier: nil, planType: nil)
        }
    }

    private func loadModelSlugs(operation: ServiceOperationToken) async throws -> [String] {
        var cursor: String?
        var seenCursors = Set<String>()
        var seen = Set<String>()
        var models: [String] = []
        repeat {
            let response: CodexModelListResponse = try await client.request(
                method: "model/list",
                params: CodexModelListParams(cursor: cursor, limit: 100, includeHidden: false),
                cancellationScope: operation.id
            )
            try validateServiceOperation(operation)
            for model in response.data {
                let slug = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
                if slug.isEmpty == false, seen.insert(slug).inserted {
                    models.append(slug)
                }
            }
            cursor = response.nextCursor?.trimmingCharacters(in: .whitespacesAndNewlines)
            if cursor?.isEmpty == true { cursor = nil }
            if let cursor, seenCursors.insert(cursor).inserted == false {
                throw CodexRuntimeError.invalidResponse("Codex model pagination repeated a cursor.")
            }
        } while cursor != nil
        try validateServiceOperation(operation)
        return models
    }

    private func makeSession(
        refreshToken: Bool,
        operation: ServiceOperationToken
    ) async throws -> StoredAccountSession {
        let status = try await readAccountStatus(refreshToken: refreshToken, operation: operation)
        try validateServiceOperation(operation)
        guard status.authenticated else {
            throw CodexRuntimeError.authentication("Codex did not report an authenticated ChatGPT account.")
        }
        let models = try await loadModelSlugs(operation: operation)
        try validateServiceOperation(operation)
        return StoredAccountSession(
            provider: "openAI",
            accountIdentifier: status.accountIdentifier ?? "ChatGPT Account",
            accessToken: Self.sessionMarker,
            refreshToken: nil,
            idToken: nil,
            tokenType: nil,
            expiresAt: nil,
            accessibleModelIDs: models,
            createdAt: Date(),
            id: UUID()
        )
    }

    private func collectResponse(
        subscription: CodexNotificationSubscription,
        threadID: String,
        turnID: String,
        onDelta: @escaping @Sendable (String) throws -> Void
    ) async throws -> String {
        var content = ""
        var responseBytes = 0
        while true {
            let notification = try await client.nextNotification(
                from: subscription,
                timeout: turnCompletionTimeout,
                matching: { data in
                    if let delta = try? JSONDecoder().decode(CodexAgentMessageDeltaNotification.self, from: data) {
                        return delta.threadId == threadID && delta.turnId == turnID
                    }
                    if let completed = try? JSONDecoder().decode(CodexTurnCompletedNotification.self, from: data) {
                        return completed.threadId == threadID && completed.turn.id == turnID
                    }
                    if let error = try? JSONDecoder().decode(CodexErrorNotification.self, from: data) {
                        return error.threadId == threadID && error.turnId == turnID
                    }
                    return false
                }
            )
            switch notification.method {
            case "item/agentMessage/delta":
                let delta = try JSONDecoder().decode(CodexAgentMessageDeltaNotification.self, from: notification.params).delta
                let deltaBytes = delta.utf8.count
                guard deltaBytes <= responseByteLimit - responseBytes else {
                    throw CodexRuntimeError.responseTooLarge
                }
                responseBytes += deltaBytes
                content += delta
                try onDelta(delta)
            case "error":
                let failure = try JSONDecoder().decode(CodexErrorNotification.self, from: notification.params)
                if failure.willRetry == false {
                    throw Self.mapTurnError(failure.error)
                }
            case "turn/completed":
                let completed = try JSONDecoder().decode(CodexTurnCompletedNotification.self, from: notification.params)
                switch completed.turn.status {
                case "completed":
                    guard content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                        throw CodexRuntimeError.invalidResponse("Codex completed the turn without an assistant response.")
                    }
                    return content
                case "interrupted": throw CancellationError()
                case "failed":
                    if let error = completed.turn.error { throw Self.mapTurnError(error) }
                    throw CodexRuntimeError.runtime("Codex turn failed.")
                default: throw CodexRuntimeError.invalidResponse("Unexpected completed turn status: \(completed.turn.status)")
                }
            default: break
            }
        }
    }

    private func cancelLogin(loginID: String) async -> Bool {
        let client = self.client
        return await Task.detached {
            do {
                let response: CodexCancelLoginAccountResponse = try await client.request(
                    method: "account/login/cancel",
                    params: CodexCancelLoginAccountParams(loginId: loginID),
                    timeout: .seconds(5)
                )
                let status = response.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return status == "canceled" || status == "cancelled"
            } catch {
                return false
            }
        }.value
    }

    private func interruptTurnIfAvailable(_ context: ChatTurnContext) async {
        guard let turnID = context.turnID else { return }
        let client = self.client
        await Task.detached {
            let _: CodexEmptyParams? = try? await client.request(
                method: "turn/interrupt",
                params: CodexTurnInterruptParams(threadId: context.threadID, turnId: turnID),
                timeout: .seconds(5)
            )
        }.value
    }

    static func isAllowedAuthURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return false }
        if scheme == "https" { return true }
        guard scheme == "http" else { return false }
        if host == "localhost" || host == "::1" || host == "0:0:0:0:0:0:0:1" { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4
            && octets.first == "127"
            && octets.allSatisfy { UInt8($0) != nil }
    }

    private static func mapTurnError(_ error: CodexTurnError) -> CodexRuntimeError {
        let code: CodexErrorCode?
        let status: Int?
        switch error.codexErrorInfo {
        case .code(let value):
            code = value
            status = nil
        case .httpConnectionFailed(let httpStatusCode),
             .responseStreamConnectionFailed(let httpStatusCode),
             .responseStreamDisconnected(let httpStatusCode),
             .responseTooManyFailedAttempts(let httpStatusCode):
            code = nil
            status = httpStatusCode
        case .activeTurnNotSteerable:
            return .accountConflict(error.message)
        case .unknown:
            code = nil
            status = nil
        case nil:
            code = nil
            status = nil
        }

        switch code {
        case .contextWindowExceeded, .cyberPolicy, .badRequest, .sandboxError:
            return .badRequest(error.message)
        case .unauthorized:
            return .authentication(error.message)
        case .usageLimitExceeded:
            return .quotaExceeded(error.message)
        case .serverOverloaded:
            return .overloaded(error.message)
        case .internalServerError, .threadRollbackFailed, .other, nil:
            break
        }

        switch status {
        case 400: return .badRequest(error.message)
        case 401, 403: return .authentication(error.message)
        case 429: return .quotaExceeded(error.message)
        case 503: return .overloaded(error.message)
        case 408, 504: return .timeout(error.message)
        default: return .runtime(error.message)
        }
    }

    private static func renderPrompt(messages: [HelperChatMessage]) -> String {
        let transcript = messages.map { message in
            "[\(message.role.capitalized)]\n\(message.content)"
        }.joined(separator: "\n\n")
        return """
        Continue this conversation and reply as the assistant. Return only the assistant's next message with no extra framing.

        \(transcript)
        """
    }

    private static func openBrowser(_ url: URL) throws {
        #if os(macOS)
        guard NSWorkspace.shared.open(url) else { throw CodexRuntimeError.browserOpenFailed }
        #else
        throw CodexRuntimeError.browserOpenFailed
        #endif
    }
}

private enum InternalTurnStartError: Error {
    case staleThread
}

private final class ChatTurnContext: @unchecked Sendable {
    let threadID: String
    private let lock = NSLock()
    private var storedTurnID: String?

    init(threadID: String) { self.threadID = threadID }

    var turnID: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedTurnID
    }

    func setTurnID(_ value: String) {
        lock.lock()
        storedTurnID = value
        lock.unlock()
    }
}

enum CodexRuntimeError: LocalizedError, Sendable {
    case badRequest(String)
    case authentication(String)
    case quotaExceeded(String)
    case overloaded(String)
    case accountConflict(String)
    case browserOpenFailed
    case responseTooLarge
    case invalidResponse(String)
    case timeout(String)
    case runtime(String)

    var errorDescription: String? {
        switch self {
        case .badRequest(let message), .authentication(let message), .quotaExceeded(let message),
             .overloaded(let message), .accountConflict(let message), .invalidResponse(let message),
             .timeout(let message), .runtime(let message): return message
        case .browserOpenFailed: return "Unable to open the ChatGPT login URL in a browser."
        case .responseTooLarge: return "Codex response exceeded the configured size limit."
        }
    }
}
