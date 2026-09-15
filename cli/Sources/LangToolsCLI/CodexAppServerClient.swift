import Foundation

final class ProcessChunkPump: @unchecked Sendable {
    let stream: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private let onOverflow: @Sendable () -> Void
    private var stopped = false

    init(
        label _: String,
        maximumBufferedChunks: Int,
        onOverflow: @escaping @Sendable () -> Void
    ) {
        precondition(maximumBufferedChunks > 0)
        var captured: AsyncStream<Data>.Continuation!
        self.stream = AsyncStream(bufferingPolicy: .bufferingOldest(maximumBufferedChunks)) { captured = $0 }
        self.continuation = captured
        self.onOverflow = onOverflow
    }

    func yield(_ data: Data) {
        lock.lock()
        guard stopped == false else {
            lock.unlock()
            return
        }
        switch continuation.yield(data) {
        case .enqueued:
            lock.unlock()
        case .dropped:
            stopped = true
            lock.unlock()
            continuation.finish()
            onOverflow()
        case .terminated:
            stopped = true
            lock.unlock()
        @unknown default:
            stopped = true
            lock.unlock()
            continuation.finish()
            onOverflow()
        }
    }

    func finish() {
        lock.lock()
        guard stopped == false else {
            lock.unlock()
            return
        }
        stopped = true
        lock.unlock()
        continuation.finish()
    }
}

actor CodexAppServerClient {
    typealias CommandResolver = @Sendable () throws -> ResolvedCodexCommand
    typealias RequestTimeoutSleeper = @Sendable (String, Duration) async throws -> Void

    private struct PendingRequest {
        let continuation: CheckedContinuation<Data, Error>
        let timeoutTask: Task<Void, Never>
        let cancellationScope: UUID?
    }

    private struct StartupWaiter {
        let cancellationScope: UUID?
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct NotificationWaiter {
        let id: UUID
        let matches: @Sendable (Data) -> Bool
        let continuation: CheckedContinuation<CodexServerNotification, Error>
        let timeoutTask: Task<Void, Never>
    }

    private struct BufferedNotification {
        let notification: CodexServerNotification
        let byteCount: Int
    }

    private struct NotificationSubscriptionState {
        let methods: Set<String>
        let accepts: @Sendable (Data) -> Bool
        let maximumBufferedEvents: Int
        let maximumBufferedBytes: Int
        var buffered: [BufferedNotification] = []
        var bufferedByteCount = 0
        var waiter: NotificationWaiter?
        var terminalFailure: CodexAppServerError?
    }

    typealias WorkspaceRootProvider = @Sendable () -> URL?
    typealias CodexHomeProvider = @Sendable () -> String

    private let commandResolver: CommandResolver
    private let environment: [String: String]
    private let defaultTimeout: Duration
    private let requestTimeoutSleeper: RequestTimeoutSleeper
    private let workspaceRootProvider: WorkspaceRootProvider
    private let codexHomeProvider: CodexHomeProvider
    private var process: Process?
    private var seatbeltProfileURL: URL?
    private var stdinHandle: FileHandle?
    private var stdoutBuffer = Data()
    private var pending: [Int: PendingRequest] = [:]
    private var cancelledRequestScopes = Set<UUID>()
    private var notificationSubscriptions: [UUID: NotificationSubscriptionState] = [:]
    private var nextRequestID = 1
    private var isInitialized = false
    private var isStarting = false
    private var startupWaiters: [UUID: StartupWaiter] = [:]
    private var shuttingDown = false
    private var stderrTail = ""
    private var processGeneration: UUID?
    private var stdoutPump: ProcessChunkPump?
    private var stderrPump: ProcessChunkPump?
    private var stdoutReaderTask: Task<Void, Never>?
    private var stderrReaderTask: Task<Void, Never>?

    static let maximumBufferedNotificationEvents = 256
    static let maximumBufferedNotificationBytes = 1_048_576
    static let maximumStdoutNDJSONLineBytes = 1_048_576
    static let maximumBufferedProcessChunks = 256

    init(
        commandResolver: @escaping CommandResolver = { try OpenAIAccountChatCommand.resolveCodexCommand() },
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaultTimeout: Duration = .seconds(30),
        requestTimeoutSleeper: @escaping RequestTimeoutSleeper = { _, duration in
            try await Task.sleep(for: duration)
        },
        workspaceRootProvider: @escaping WorkspaceRootProvider = { nil },
        codexHomeProvider: CodexHomeProvider? = nil
    ) {
        self.commandResolver = commandResolver
        self.environment = environment
        self.defaultTimeout = defaultTimeout
        self.requestTimeoutSleeper = requestTimeoutSleeper
        self.workspaceRootProvider = workspaceRootProvider
        self.codexHomeProvider = codexHomeProvider ?? {
            CodexSeatbeltProfile.resolvedCodexHome(environment: ProcessInfo.processInfo.environment)
        }
    }

    func request<Params: Encodable, Response: Decodable>(
        method: String,
        params: Params,
        timeout: Duration? = nil,
        cancelOnTaskCancellation: Bool = true,
        cancellationScope: UUID? = nil
    ) async throws -> Response {
        try validateRequestScope(cancellationScope)
        try await ensureStarted(cancellationScope: cancellationScope)
        try validateRequestScope(cancellationScope)
        let paramsData = try JSONEncoder().encode(params)
        let paramsObject = try JSONSerialization.jsonObject(with: paramsData)
        let data = try await sendRequest(
            method: method,
            params: paramsObject,
            timeout: timeout ?? defaultTimeout,
            cancelOnTaskCancellation: cancelOnTaskCancellation,
            cancellationScope: cancellationScope
        )
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw CodexAppServerError.invalidResponse("Unable to decode \(method) response: \(error.localizedDescription)")
        }
    }

    func subscribeToNotifications(
        methods: Set<String>,
        accepts: @escaping @Sendable (Data) -> Bool = { _ in true },
        maximumBufferedEvents: Int = CodexAppServerClient.maximumBufferedNotificationEvents,
        maximumBufferedBytes: Int = CodexAppServerClient.maximumBufferedNotificationBytes
    ) -> CodexNotificationSubscription {
        let subscription = CodexNotificationSubscription(id: UUID())
        notificationSubscriptions[subscription.id] = NotificationSubscriptionState(
            methods: methods,
            accepts: accepts,
            maximumBufferedEvents: max(0, maximumBufferedEvents),
            maximumBufferedBytes: max(0, maximumBufferedBytes),
            terminalFailure: nil
        )
        return subscription
    }

    func nextNotification(
        from subscription: CodexNotificationSubscription,
        timeout: Duration? = nil,
        matching: @escaping @Sendable (Data) -> Bool = { _ in true }
    ) async throws -> CodexServerNotification {
        guard var state = notificationSubscriptions[subscription.id] else {
            throw CodexAppServerError.invalidResponse("Notification subscription is no longer active.")
        }
        if let terminalFailure = state.terminalFailure { throw terminalFailure }
        if let index = state.buffered.firstIndex(where: { matching($0.notification.params) }) {
            let buffered = state.buffered.remove(at: index)
            state.bufferedByteCount -= buffered.byteCount
            notificationSubscriptions[subscription.id] = state
            return buffered.notification
        }
        guard state.waiter == nil else {
            throw CodexAppServerError.invalidResponse("Notification subscription already has an active waiter.")
        }

        let waiterID = UUID()
        let waitDuration = timeout ?? defaultTimeout
        let description = state.methods.sorted().joined(separator: " or ")
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: waitDuration)
                    } catch {
                        return
                    }
                    await self?.failNotificationWaiter(
                        subscriptionID: subscription.id,
                        waiterID: waiterID,
                        error: CodexAppServerError.timeout(description)
                    )
                }
                state.waiter = NotificationWaiter(
                    id: waiterID,
                    matches: matching,
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
                notificationSubscriptions[subscription.id] = state
            }
        } onCancel: {
            Task { [weak self] in
                await self?.failNotificationWaiter(
                    subscriptionID: subscription.id,
                    waiterID: waiterID,
                    error: CancellationError()
                )
            }
        }
    }

    func cancelNotificationSubscription(_ subscription: CodexNotificationSubscription) {
        guard let state = notificationSubscriptions.removeValue(forKey: subscription.id) else { return }
        state.waiter?.timeoutTask.cancel()
        state.waiter?.continuation.resume(throwing: CancellationError())
    }

    func notificationBufferMetrics(
        for subscription: CodexNotificationSubscription
    ) -> (events: Int, bytes: Int, failed: Bool, waiting: Bool)? {
        guard let state = notificationSubscriptions[subscription.id] else { return nil }
        return (state.buffered.count, state.bufferedByteCount, state.terminalFailure != nil, state.waiter != nil)
    }

    func cancelRequests(in scope: UUID) {
        cancelledRequestScopes.insert(scope)
        let startupWaiterIDs = startupWaiters.compactMap { id, waiter in
            waiter.cancellationScope == scope ? id : nil
        }
        for waiterID in startupWaiterIDs {
            failStartupWaiter(id: waiterID, error: CancellationError())
        }
        let requestIDs = pending.compactMap { id, request in
            request.cancellationScope == scope ? id : nil
        }
        for requestID in requestIDs {
            failPending(id: requestID, error: CancellationError())
        }
    }

    func closeRequestCancellationScope(_ scope: UUID) {
        cancelledRequestScopes.remove(scope)
    }

    func initializedProcessGeneration() async throws -> UUID {
        try await ensureStarted()
        guard let processGeneration else { throw CodexAppServerError.unavailable }
        return processGeneration
    }

    func restart() async throws {
        guard shuttingDown == false else { throw CodexAppServerError.shutdown }
        shutdownProcess(error: CodexAppServerError.restarted)
        try await ensureStarted()
    }

    func shutdown() {
        shuttingDown = true
        shutdownProcess(error: CodexAppServerError.shutdown)
    }

    private func ensureStarted(cancellationScope: UUID? = nil) async throws {
        guard shuttingDown == false else { throw CodexAppServerError.shutdown }
        try validateRequestScope(cancellationScope)
        if isInitialized, let process, process.isRunning { return }

        let waiterID = UUID()
        let shouldStart = isStarting == false
        if shouldStart {
            isStarting = true
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard cancellationScope.map({ cancelledRequestScopes.contains($0) }) != true else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                startupWaiters[waiterID] = StartupWaiter(
                    cancellationScope: cancellationScope,
                    continuation: continuation
                )
                if shouldStart {
                    Task { [weak self] in
                        await self?.performStartup()
                    }
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.failStartupWaiter(id: waiterID, error: CancellationError())
            }
        }
        try validateRequestScope(cancellationScope)
    }

    private func performStartup() async {
        guard shuttingDown == false else {
            finishStartup(with: .failure(CodexAppServerError.shutdown))
            return
        }
        if process != nil || stdinHandle != nil || stdoutBuffer.isEmpty == false {
            shutdownProcess(error: CodexAppServerError.restarted)
        }
        do {
            try launchProcess()
            let params = CodexInitializeParams(
                clientInfo: .init(name: "langtools-cli", title: "LangTools CLI", version: "1"),
                capabilities: .init(
                    experimentalApi: true,
                    requestAttestation: false,
                    mcpServerOpenaiFormElicitation: false,
                    optOutNotificationMethods: nil
                )
            )
            let encoded = try JSONEncoder().encode(params)
            let object = try JSONSerialization.jsonObject(with: encoded)
            let responseData = try await sendRequest(
                method: "initialize",
                params: object,
                timeout: defaultTimeout,
                cancelOnTaskCancellation: false
            )
            let initialized = try JSONDecoder().decode(CodexInitializeResponse.self, from: responseData)
            guard initialized.platformOs.lowercased() == "macos" else {
                throw CodexAppServerError.unsupportedContainmentPlatform(initialized.platformOs)
            }
            try writeJSONObject(["method": "initialized"])
            isInitialized = true
            finishStartup(with: .success(()))
        } catch {
            shutdownProcess(error: error)
            finishStartup(with: .failure(error))
        }
    }

    private func finishStartup(with result: Result<Void, Error>) {
        isStarting = false
        let waiters = startupWaiters.values
        startupWaiters.removeAll()
        for waiter in waiters {
            waiter.continuation.resume(with: result)
        }
    }

    private func failStartupWaiter(id: UUID, error: Error) {
        guard let waiter = startupWaiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(throwing: error)
    }

    private func launchProcess() throws {
        let command = try commandResolver()
        let codexArguments = command.arguments + ["app-server", "--listen", "stdio://"]
        let process = Process()
        if let seatbelt = try makeSeatbeltLaunch(
            executable: command.executable,
            arguments: codexArguments
        ) {
            process.executableURL = URL(fileURLWithPath: seatbelt.sandboxExec)
            process.arguments = ["-f", seatbelt.profilePath, command.executable] + codexArguments
            // Run the Codex app-server with its working directory inside the
            // allowlisted workspace root, so it never reads the arbitrary
            // helper launch directory (e.g. the user's repo/home) to load
            // project config.
            process.currentDirectoryURL = seatbelt.workspaceURL
            seatbeltProfileURL = seatbelt.profileURL
        } else {
            process.executableURL = URL(fileURLWithPath: command.executable)
            process.arguments = codexArguments
        }

        var childEnvironment = environment
        if let override = childEnvironment["LANGTOOLS_CODEX_HOME"], override.isEmpty == false {
            childEnvironment["CODEX_HOME"] = override
        }
        childEnvironment["CODEX_INTERNAL_APP_SERVER_REMOTE_CONTROL_DISABLED"] = "1"
        process.environment = childEnvironment

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let generation = UUID()
        let stdoutPump = ProcessChunkPump(
            label: "LangToolsCLI.CodexAppServer.stdout",
            maximumBufferedChunks: Self.maximumBufferedProcessChunks,
            onOverflow: { [weak self] in
                Task { await self?.processChunkPumpOverflow(stream: "stdout", generation: generation) }
            }
        )
        let stderrPump = ProcessChunkPump(
            label: "LangToolsCLI.CodexAppServer.stderr",
            maximumBufferedChunks: Self.maximumBufferedProcessChunks,
            onOverflow: { [weak self] in
                Task { await self?.processChunkPumpOverflow(stream: "stderr", generation: generation) }
            }
        )
        stdoutReaderTask = Task { [weak self] in
            for await data in stdoutPump.stream {
                await self?.consumeStdout(data, generation: generation)
            }
            await self?.stdoutClosed(generation: generation)
        }
        stderrReaderTask = Task { [weak self] in
            for await data in stderrPump.stream {
                await self?.consumeStderr(data, generation: generation)
            }
        }
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            data.isEmpty ? stdoutPump.finish() : stdoutPump.yield(data)
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            data.isEmpty ? stderrPump.finish() : stderrPump.yield(data)
        }
        process.terminationHandler = { [weak self] exitedProcess in
            Task { await self?.processExited(exitedProcess) }
        }

        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            throw CodexAppServerError.unavailable
        }
        self.process = process
        processGeneration = generation
        self.stdoutPump = stdoutPump
        self.stderrPump = stderrPump
        stdinHandle = stdin.fileHandleForWriting
    }

    private struct SeatbeltLaunch {
        let sandboxExec: String
        let profilePath: String
        let profileURL: URL
        let workspaceURL: URL
    }

    private func makeSeatbeltLaunch(executable: String, arguments: [String]) throws -> SeatbeltLaunch? {
        guard let sandboxExec = CodexSeatbeltProfile.sandboxExecPath(),
              let workspaceRoot = workspaceRootProvider()
        else { return nil }
        let resolvedWorkspace = workspaceRoot.resolvingSymlinksInPath()
        // The child cwd is set to this directory; it must exist or the launch
        // fails, so fail closed with a clear error rather than a confusing
        // process failure.
        var workspaceIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedWorkspace.path, isDirectory: &workspaceIsDirectory),
              workspaceIsDirectory.boolValue
        else {
            throw CodexAppServerError.transport(
                "Codex workspace root is missing: \(resolvedWorkspace.path)"
            )
        }
        // Give the app-server a dedicated, empty working directory inside the
        // allowlisted root. Its own project-config scan must not traverse the
        // sibling conversation workspaces that share the root; per-turn work
        // happens in the conversation workspace set via thread/start.
        let appServerCWD = resolvedWorkspace
            .appendingPathComponent("app-server-cwd", isDirectory: true)
        try FileManager.default.createDirectory(
            at: appServerCWD,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        let inputs = CodexSeatbeltProfile.Inputs(
            codexExecutable: executable,
            codexExecutableArguments: Array(arguments.dropLast(3)),
            codexHome: codexHomeProvider(),
            workspaceRoot: resolvedWorkspace.path,
            codexRuntimeCache: CodexSeatbeltProfile.resolvedCodexRuntimeCache(environment: environment),
            homeDirectory: environment["HOME"] ?? ""
        )
        // A profile-write failure throws so the caller never launches the
        // Codex runtime without the intended OS-level read boundary.
        let profileURL = try CodexSeatbeltProfile().writeProfile(inputs: inputs)
        return SeatbeltLaunch(
            sandboxExec: sandboxExec,
            profilePath: profileURL.path,
            profileURL: profileURL,
            workspaceURL: appServerCWD
        )
    }

    private func sendRequest(
        method: String,
        params: Any,
        timeout: Duration,
        cancelOnTaskCancellation: Bool,
        cancellationScope: UUID? = nil
    ) async throws -> Data {
        try validateRequestScope(cancellationScope)
        guard let process, process.isRunning else { throw CodexAppServerError.unavailable }
        let requestID = nextRequestID
        nextRequestID += 1

        guard cancelOnTaskCancellation else {
            return try await registerPendingRequest(
                id: requestID,
                method: method,
                params: params,
                timeout: timeout,
                cancellationScope: cancellationScope
            )
        }
        return try await withTaskCancellationHandler {
            try await registerPendingRequest(
                id: requestID,
                method: method,
                params: params,
                timeout: timeout,
                cancellationScope: cancellationScope
            )
        } onCancel: {
            Task { [weak self] in
                await self?.failPending(id: requestID, error: CancellationError())
            }
        }
    }

    private func registerPendingRequest(
        id requestID: Int,
        method: String,
        params: Any,
        timeout: Duration,
        cancellationScope: UUID?
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = Task { [weak self, requestTimeoutSleeper = self.requestTimeoutSleeper] in
                do {
                    try await requestTimeoutSleeper(method, timeout)
                    try Task.checkCancellation()
                } catch {
                    return
                }
                await self?.failPending(id: requestID, error: CodexAppServerError.timeout(method))
            }
            guard cancellationScope.map({ cancelledRequestScopes.contains($0) }) != true else {
                timeoutTask.cancel()
                continuation.resume(throwing: CancellationError())
                return
            }
            pending[requestID] = PendingRequest(
                continuation: continuation,
                timeoutTask: timeoutTask,
                cancellationScope: cancellationScope
            )
            do {
                try writeJSONObject(["id": requestID, "method": method, "params": params])
            } catch {
                failPending(id: requestID, error: error)
            }
        }
    }

    private func validateRequestScope(_ scope: UUID?) throws {
        if let scope, cancelledRequestScopes.contains(scope) {
            throw CancellationError()
        }
    }

    private func writeJSONObject(_ object: [String: Any]) throws {
        guard let stdinHandle else { throw CodexAppServerError.unavailable }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        do {
            try stdinHandle.write(contentsOf: data)
        } catch {
            throw CodexAppServerError.transport(error.localizedDescription)
        }
    }

    private func consumeStdout(_ data: Data, generation: UUID) {
        guard processGeneration == generation else { return }
        stdoutBuffer.append(data)
        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineByteCount = stdoutBuffer.distance(from: stdoutBuffer.startIndex, to: newline)
            guard lineByteCount <= Self.maximumStdoutNDJSONLineBytes else {
                shutdownProcess(error: CodexAppServerError.invalidResponse("Codex app-server emitted an oversized NDJSON line."))
                return
            }
            let line = stdoutBuffer[..<newline]
            stdoutBuffer.removeSubrange(...newline)
            guard line.isEmpty == false else { continue }
            handleLine(Data(line))
            guard processGeneration == generation else { return }
        }
        guard stdoutBuffer.count <= Self.maximumStdoutNDJSONLineBytes else {
            shutdownProcess(error: CodexAppServerError.invalidResponse("Codex app-server emitted an oversized unterminated NDJSON line."))
            return
        }
    }

    private func processChunkPumpOverflow(stream: String, generation: UUID) {
        guard processGeneration == generation else { return }
        shutdownProcess(error: CodexAppServerError.transport("Codex app-server \(stream) buffering exceeded its limit."))
    }

    private func consumeStderr(_ data: Data, generation: UUID) {
        guard processGeneration == generation else { return }
        stderrTail.append(String(decoding: data, as: UTF8.self))
        if stderrTail.count > 16_384 {
            stderrTail = String(stderrTail.suffix(16_384))
        }
    }

    private func stdoutClosed(generation: UUID) {
        guard processGeneration == generation, shuttingDown == false else { return }
        if let process, process.isRunning == false {
            processExited(process)
        } else {
            shutdownProcess(error: CodexAppServerError.transport("Codex app-server closed stdout."))
        }
    }

    private func handleLine(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            shutdownProcess(error: CodexAppServerError.invalidResponse("Received malformed NDJSON from Codex app-server."))
            return
        }
        if let id = Self.integerID(object["id"]), object["method"] == nil {
            guard let request = pending.removeValue(forKey: id) else { return }
            request.timeoutTask.cancel()
            if let error = object["error"] as? [String: Any] {
                let message = error["message"] as? String ?? "Codex app-server request failed."
                let code = (error["code"] as? NSNumber)?.intValue
                if let code, [-32700, -32600, -32601, -32602].contains(code) {
                    request.continuation.resume(throwing: CodexAppServerError.invalidRequest(message))
                } else {
                    request.continuation.resume(throwing: CodexAppServerError.server(code: code, message: message))
                }
            } else if let result = object["result"] {
                do {
                    request.continuation.resume(returning: try JSONSerialization.data(withJSONObject: result))
                } catch {
                    request.continuation.resume(throwing: CodexAppServerError.invalidResponse(error.localizedDescription))
                }
            } else {
                request.continuation.resume(throwing: CodexAppServerError.invalidResponse("Missing result"))
            }
            return
        }

        if object["method"] is String, object["id"] != nil {
            declineServerRequest(object)
            return
        }

        guard let method = object["method"] as? String else { return }
        let params = object["params"] ?? [:]
        guard let paramsData = try? JSONSerialization.data(withJSONObject: params) else {
            shutdownProcess(error: CodexAppServerError.invalidResponse("Notification params were not valid JSON."))
            return
        }
        let notification = CodexServerNotification(method: method, params: paramsData)
        for subscriptionID in Array(notificationSubscriptions.keys) {
            guard var state = notificationSubscriptions[subscriptionID],
                  state.methods.contains(method),
                  state.terminalFailure == nil,
                  state.accepts(paramsData)
            else { continue }
            if let waiter = state.waiter, waiter.matches(paramsData) {
                state.waiter = nil
                notificationSubscriptions[subscriptionID] = state
                waiter.timeoutTask.cancel()
                waiter.continuation.resume(returning: notification)
                continue
            }

            let notificationBytes = data.count
            let exceedsEventLimit = state.buffered.count >= state.maximumBufferedEvents
            let exceedsByteLimit = notificationBytes > state.maximumBufferedBytes - state.bufferedByteCount
            if exceedsEventLimit || exceedsByteLimit {
                let failure = CodexAppServerError.invalidResponse("Notification subscription exceeded its buffer limits.")
                let waiter = state.waiter
                state.waiter = nil
                state.buffered.removeAll(keepingCapacity: false)
                state.bufferedByteCount = 0
                state.terminalFailure = failure
                notificationSubscriptions[subscriptionID] = state
                waiter?.timeoutTask.cancel()
                waiter?.continuation.resume(throwing: failure)
                continue
            }

            state.buffered.append(BufferedNotification(notification: notification, byteCount: notificationBytes))
            state.bufferedByteCount += notificationBytes
            notificationSubscriptions[subscriptionID] = state
        }
    }

    private func declineServerRequest(_ request: [String: Any]) {
        guard let id = request["id"] else { return }
        let method = request["method"] as? String ?? "unknown"
        let result: [String: Any]?
        switch method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            result = ["decision": "decline"]
        case "item/permissions/requestApproval":
            // Codex 0.142.0 requires PermissionsRequestApprovalResponse. Granting
            // neither profile fails closed while preserving the protocol's exact shape.
            result = [
                "permissions": ["fileSystem": NSNull(), "network": NSNull()],
                "scope": "turn",
                "strictAutoReview": NSNull()
            ]
        case "applyPatchApproval", "execCommandApproval":
            result = ["decision": "denied"]
        case "item/tool/requestUserInput":
            result = ["answers": [:]]
        case "mcpServer/elicitation/request":
            result = ["action": "decline", "content": NSNull(), "_meta": NSNull()]
        case "item/tool/call":
            result = ["contentItems": [], "success": false]
        default:
            result = nil
        }
        do {
            if let result {
                try writeJSONObject(["id": id, "result": result])
            } else {
                try writeJSONObject([
                    "id": id,
                    "error": ["code": -32601, "message": "Client declines unsupported server request: \(method)"]
                ])
            }
        } catch {
            shutdownProcess(error: error)
        }
    }

    private func failPending(id: Int, error: Error) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeoutTask.cancel()
        request.continuation.resume(throwing: error)
    }

    private func failNotificationWaiter(subscriptionID: UUID, waiterID: UUID, error: Error) {
        guard var state = notificationSubscriptions[subscriptionID],
              let waiter = state.waiter,
              waiter.id == waiterID
        else { return }
        state.waiter = nil
        notificationSubscriptions[subscriptionID] = state
        waiter.timeoutTask.cancel()
        waiter.continuation.resume(throwing: error)
    }

    private func processExited(_ exitedProcess: Process) {
        guard process === exitedProcess, shuttingDown == false else { return }
        let detail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
        shutdownProcess(error: CodexAppServerError.exited(status: exitedProcess.terminationStatus, stderr: detail))
    }

    private func shutdownProcess(error: Error) {
        let oldProcess = process
        process = nil
        isInitialized = false
        try? stdinHandle?.close()
        stdinHandle = nil
        processGeneration = nil
        stdoutBuffer.removeAll()
        stdoutPump?.finish()
        stderrPump?.finish()
        stdoutPump = nil
        stderrPump = nil
        stdoutReaderTask?.cancel()
        stderrReaderTask?.cancel()
        stdoutReaderTask = nil
        stderrReaderTask = nil
        oldProcess?.standardOutput.flatMap { $0 as? Pipe }?.fileHandleForReading.readabilityHandler = nil
        oldProcess?.standardError.flatMap { $0 as? Pipe }?.fileHandleForReading.readabilityHandler = nil
        if oldProcess?.isRunning == true { oldProcess?.terminate() }
        if let profileURL = seatbeltProfileURL {
            seatbeltProfileURL = nil
            try? FileManager.default.removeItem(at: profileURL)
        }

        let requests = pending.values
        pending.removeAll()
        requests.forEach {
            $0.timeoutTask.cancel()
            $0.continuation.resume(throwing: error)
        }
        let subscriptions = notificationSubscriptions.values
        notificationSubscriptions.removeAll()
        subscriptions.compactMap(\.waiter).forEach {
            $0.timeoutTask.cancel()
            $0.continuation.resume(throwing: error)
        }
    }

    private static func integerID(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }
}

struct CodexNotificationSubscription: Sendable {
    fileprivate let id: UUID
}

enum CodexAppServerError: LocalizedError, Sendable {
    case unavailable
    case unsupportedContainmentPlatform(String)
    case transport(String)
    case invalidResponse(String)
    case invalidRequest(String)
    case server(code: Int?, message: String)
    case timeout(String)
    case exited(status: Int32, stderr: String)
    case restarted
    case shutdown

    /// Maximum app-server stderr bytes embedded in a localized error message.
    /// The runtime stderr tail is already capped (16 KB); this keeps the
    /// user-facing error bounded. Measured in UTF-8 bytes because log sinks
    /// and UI layers budget bytes, not characters.
    static let maximumStderrDetailBytes = 2_048

    static func truncatedStderrDetail(_ stderr: String) -> String {
        let trimmed = sanitizeStderrDetail(stderr)
        guard trimmed.isEmpty == false else { return "" }
        var bytes = Array(trimmed.utf8)
        guard bytes.count > maximumStderrDetailBytes else { return trimmed }
        // The failure reason lives at the end of a crash log: keep the tail.
        bytes = Array(bytes.suffix(maximumStderrDetailBytes))
        // Drop continuation bytes of a multi-byte character split by the byte
        // boundary; a remaining partial start byte decodes to one replacement
        // character, which is stripped only as a leading artifact.
        var start = 0
        while start < bytes.count, bytes[start] & 0b1100_0000 == 0b1000_0000 { start += 1 }
        var detail = String(decoding: bytes[start...], as: UTF8.self)
        if detail.first == "\u{FFFD}" { detail.removeFirst() }
        if detail.isEmpty {
            // Nothing usable survived truncation; the caller falls back to the
            // plain status message.
            return ""
        }
        return "…" + detail + "[truncated]"
    }

    /// Replaces control characters (other than newlines) with spaces so
    /// embedded stderr cannot smuggle terminal escape sequences into logs or
    /// the UI, then collapses whitespace runs.
    private static func sanitizeStderrDetail(_ value: String) -> String {
        let replaced = String(value.map { character in
            let printable = character.unicodeScalars.allSatisfy { scalar in
                scalar.value >= 0x20 && !(0x7F...0x9F).contains(scalar.value)
            }
            return (character.isNewline || printable) ? character : " "
        })
        return replaced
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
    }

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Codex CLI is not available. Install it, put `codex` on PATH, or set LANGTOOLS_CODEX_PATH."
        case .unsupportedContainmentPlatform(let platform):
            return "Codex account chat containment is unsupported on app-server platform: \(platform)."
        case .transport(let message): return "Codex app-server transport failed: \(message)"
        case .invalidResponse(let message): return "Codex app-server returned an invalid response: \(message)"
        case .invalidRequest(let message), .server(_, let message): return message
        case .timeout(let method): return "Codex app-server timed out while waiting for \(method)."
        case .exited(let status, let stderr):
            let detail = Self.truncatedStderrDetail(stderr)
            if detail.isEmpty {
                return "Codex app-server exited with status \(status)."
            }
            return "Codex app-server exited with status \(status): \(detail)"
        case .restarted: return "Codex app-server restarted."
        case .shutdown: return "Codex app-server shut down."
        }
    }
}
