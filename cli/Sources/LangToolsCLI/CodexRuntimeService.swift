import Foundation
#if os(macOS)
import AppKit
#endif

struct CodexAccountStatus: Sendable {
    let authenticated: Bool
    let accountIdentifier: String?
    let planType: String?
}

actor CodexRuntimeService {
    static let shared = CodexRuntimeService(client: CodexAppServerClient())
    static let sessionMarker = "langtools-codex-app-server-session-v1"

    typealias BrowserOpener = @Sendable (URL) throws -> Void

    private let client: CodexAppServerClient
    private let browserOpener: BrowserOpener
    private let loginCompletionTimeout: Duration
    private let turnCompletionTimeout: Duration
    private var loginInProgress = false

    init(
        client: CodexAppServerClient,
        browserOpener: @escaping BrowserOpener = { try CodexRuntimeService.openBrowser($0) },
        loginCompletionTimeout: Duration = .seconds(300),
        turnCompletionTimeout: Duration = .seconds(120)
    ) {
        self.client = client
        self.browserOpener = browserOpener
        self.loginCompletionTimeout = loginCompletionTimeout
        self.turnCompletionTimeout = turnCompletionTimeout
    }

    func accountStatus(refreshToken: Bool = false) async throws -> CodexAccountStatus {
        let response: CodexGetAccountResponse = try await client.request(
            method: "account/read",
            params: CodexGetAccountParams(refreshToken: refreshToken)
        )
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

    func login() async throws -> StoredAccountSession {
        guard loginInProgress == false else {
            throw CodexRuntimeError.accountConflict("A ChatGPT login is already in progress.")
        }
        loginInProgress = true
        defer { loginInProgress = false }

        let current: CodexGetAccountResponse = try await client.request(
            method: "account/read",
            params: CodexGetAccountParams(refreshToken: false)
        )
        if let account = current.account {
            guard case .chatgpt = account else {
                throw CodexRuntimeError.accountConflict("Codex already has a non-ChatGPT account configured.")
            }
            return try await makeSession(refreshToken: true)
        }

        let subscription = await client.subscribeToNotifications(methods: ["account/login/completed"])
        let response: CodexLoginAccountResponse
        do {
            response = try await client.request(
                method: "account/login/start",
                params: CodexChatGPTLoginParams(codexStreamlinedLogin: true),
                timeout: .seconds(30)
            )
        } catch {
            await client.cancelNotificationSubscription(subscription)
            throw error
        }
        guard case .chatgpt(let loginID, let authURLString) = response else {
            await client.cancelNotificationSubscription(subscription)
            throw CodexRuntimeError.invalidResponse("Codex did not return a ChatGPT browser login URL.")
        }

        do {
            guard let authURL = URL(string: authURLString), Self.isAllowedAuthURL(authURL) else {
                throw CodexRuntimeError.invalidResponse("Codex returned an unsafe ChatGPT browser login URL.")
            }
            try browserOpener(authURL)
            let notification = try await client.nextNotification(
                from: subscription,
                timeout: loginCompletionTimeout,
                matching: { data in
                    (try? JSONDecoder().decode(CodexAccountLoginCompletedNotification.self, from: data).loginId) == loginID
                }
            )
            let completed = try JSONDecoder().decode(CodexAccountLoginCompletedNotification.self, from: notification.params)
            guard completed.success else {
                throw CodexRuntimeError.authentication(completed.error ?? "ChatGPT login failed.")
            }
            let session = try await makeSession(refreshToken: true)
            await client.cancelNotificationSubscription(subscription)
            return session
        } catch {
            await client.cancelNotificationSubscription(subscription)
            await cancelLogin(loginID: loginID)
            throw error
        }
    }

    func logout() async throws {
        let before: CodexGetAccountResponse = try await client.request(
            method: "account/read",
            params: CodexGetAccountParams(refreshToken: false)
        )
        guard let account = before.account else { return }
        guard case .chatgpt = account else {
            throw CodexRuntimeError.accountConflict("Refusing to log out a non-ChatGPT Codex account.")
        }
        let _: CodexLogoutAccountResponse = try await client.request(
            method: "account/logout",
            params: CodexEmptyParams()
        )
        let after: CodexGetAccountResponse = try await client.request(
            method: "account/read",
            params: CodexGetAccountParams(refreshToken: false)
        )
        guard after.account == nil else {
            throw CodexRuntimeError.invalidResponse("Codex reported logout success but the account is still present.")
        }
    }

    func modelSlugs() async throws -> [String] {
        var cursor: String?
        var seenCursors = Set<String>()
        var seen = Set<String>()
        var models: [String] = []
        repeat {
            let response: CodexModelListResponse = try await client.request(
                method: "model/list",
                params: CodexModelListParams(cursor: cursor, limit: 100, includeHidden: false)
            )
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
        return models
    }

    func chat(model: String, messages: [HelperChatMessage]) async throws -> String {
        let slug = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard slug.isEmpty == false else { throw CodexRuntimeError.badRequest("A model slug is required.") }
        guard messages.isEmpty == false else { throw CodexRuntimeError.badRequest("At least one chat message is required.") }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("langtools-codex-chat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let thread: CodexThreadStartResponse = try await client.request(
            method: "thread/start",
            params: CodexThreadStartParams(
                model: slug,
                modelProvider: nil,
                cwd: directory.path,
                approvalPolicy: "never",
                sandbox: "read-only",
                config: [
                    "web_search": .string("disabled"),
                    "tools": .object(["web_search": .null]),
                    "features": .object([
                        "apps": .bool(false),
                        "browser_use": .bool(false),
                        "computer_use": .bool(false),
                        "plugins": .bool(false)
                    ])
                ],
                developerInstructions: "Reply to the conversation without invoking tools, commands, file access, network access, apps, plugins, or subagents.",
                multiAgentMode: "none",
                ephemeral: true,
                environments: [],
                dynamicTools: [],
                selectedCapabilityRoots: []
            )
        )

        let context = ChatTurnContext(threadID: thread.thread.id)
        let subscription = await client.subscribeToNotifications(
            methods: ["item/agentMessage/delta", "turn/completed", "error"]
        )
        do {
            let prompt = Self.renderPrompt(messages: messages)
            let started: CodexTurnStartResponse = try await client.request(
                method: "turn/start",
                params: CodexTurnStartParams(
                    threadId: thread.thread.id,
                    input: [.init(text: prompt)],
                    approvalPolicy: "never",
                    sandboxPolicy: ReadOnlySandboxPolicy(),
                    model: slug,
                    environments: [],
                    multiAgentMode: "none"
                ),
                cancelOnTaskCancellation: false
            )
            context.setTurnID(started.turn.id)
            try Task.checkCancellation()
            let response = try await collectResponse(
                subscription: subscription,
                threadID: thread.thread.id,
                turnID: started.turn.id
            )
            await client.cancelNotificationSubscription(subscription)
            return response
        } catch {
            await client.cancelNotificationSubscription(subscription)
            await interruptTurnIfAvailable(context)
            throw error
        }
    }

    func shutdown() async {
        await client.shutdown()
    }

    private func makeSession(refreshToken: Bool) async throws -> StoredAccountSession {
        let status = try await accountStatus(refreshToken: refreshToken)
        guard status.authenticated else {
            throw CodexRuntimeError.authentication("Codex did not report an authenticated ChatGPT account.")
        }
        return StoredAccountSession(
            provider: "openAI",
            accountIdentifier: status.accountIdentifier ?? "ChatGPT Account",
            accessToken: Self.sessionMarker,
            refreshToken: nil,
            idToken: nil,
            tokenType: nil,
            expiresAt: nil,
            accessibleModelIDs: try await modelSlugs(),
            createdAt: Date(),
            id: UUID()
        )
    }

    private func collectResponse(
        subscription: CodexNotificationSubscription,
        threadID: String,
        turnID: String
    ) async throws -> String {
        var content = ""
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
                content += try JSONDecoder().decode(CodexAgentMessageDeltaNotification.self, from: notification.params).delta
            case "error":
                let failure = try JSONDecoder().decode(CodexErrorNotification.self, from: notification.params)
                if failure.willRetry == false {
                    throw Self.mapTurnError(failure.error)
                }
            case "turn/completed":
                let completed = try JSONDecoder().decode(CodexTurnCompletedNotification.self, from: notification.params)
                switch completed.turn.status {
                case "completed":
                    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.isEmpty == false else {
                        throw CodexRuntimeError.invalidResponse("Codex completed the turn without an assistant response.")
                    }
                    return trimmed
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

    private func cancelLogin(loginID: String) async {
        let client = self.client
        await Task.detached {
            let _: CodexCancelLoginAccountResponse? = try? await client.request(
                method: "account/login/cancel",
                params: CodexCancelLoginAccountParams(loginId: loginID),
                timeout: .seconds(5)
            )
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
        Continue this conversation and reply as the assistant. Return only the assistant's next message with no extra framing. Do not use tools.

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
    case invalidResponse(String)
    case timeout(String)
    case runtime(String)

    var errorDescription: String? {
        switch self {
        case .badRequest(let message), .authentication(let message), .quotaExceeded(let message),
             .overloaded(let message), .accountConflict(let message), .invalidResponse(let message),
             .timeout(let message), .runtime(let message): return message
        case .browserOpenFailed: return "Unable to open the ChatGPT login URL in a browser."
        }
    }
}
