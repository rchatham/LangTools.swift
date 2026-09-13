import Foundation

private final class ProcessChunkPump: @unchecked Sendable {
    let stream: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let queue: DispatchQueue

    init(label: String) {
        var captured: AsyncStream<Data>.Continuation!
        self.stream = AsyncStream { captured = $0 }
        self.continuation = captured
        self.queue = DispatchQueue(label: label)
    }

    func yield(_ data: Data) {
        queue.async { self.continuation.yield(data) }
    }

    func finish() {
        queue.async { self.continuation.finish() }
    }
}

actor CodexAppServerClient {
    typealias CommandResolver = @Sendable () throws -> ResolvedCodexCommand

    private struct PendingRequest {
        let continuation: CheckedContinuation<Data, Error>
        let timeoutTask: Task<Void, Never>
    }

    private struct NotificationWaiter {
        let id: UUID
        let matches: @Sendable (Data) -> Bool
        let continuation: CheckedContinuation<CodexServerNotification, Error>
        let timeoutTask: Task<Void, Never>
    }

    private struct NotificationSubscriptionState {
        let methods: Set<String>
        var buffered: [CodexServerNotification] = []
        var waiter: NotificationWaiter?
    }

    private let commandResolver: CommandResolver
    private let environment: [String: String]
    private let defaultTimeout: Duration
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutBuffer = Data()
    private var pending: [Int: PendingRequest] = [:]
    private var notificationSubscriptions: [UUID: NotificationSubscriptionState] = [:]
    private var nextRequestID = 1
    private var isInitialized = false
    private var isStarting = false
    private var startupWaiters: [CheckedContinuation<Void, Error>] = []
    private var shuttingDown = false
    private var stderrTail = ""
    private var processGeneration: UUID?
    private var stdoutPump: ProcessChunkPump?
    private var stderrPump: ProcessChunkPump?
    private var stdoutReaderTask: Task<Void, Never>?
    private var stderrReaderTask: Task<Void, Never>?

    init(
        commandResolver: @escaping CommandResolver = { try OpenAIAccountChatCommand.resolveCodexCommand() },
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaultTimeout: Duration = .seconds(30)
    ) {
        self.commandResolver = commandResolver
        self.environment = environment
        self.defaultTimeout = defaultTimeout
    }

    func request<Params: Encodable, Response: Decodable>(
        method: String,
        params: Params,
        timeout: Duration? = nil,
        cancelOnTaskCancellation: Bool = true
    ) async throws -> Response {
        try await ensureStarted()
        let paramsData = try JSONEncoder().encode(params)
        let paramsObject = try JSONSerialization.jsonObject(with: paramsData)
        let data = try await sendRequest(
            method: method,
            params: paramsObject,
            timeout: timeout ?? defaultTimeout,
            cancelOnTaskCancellation: cancelOnTaskCancellation
        )
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw CodexAppServerError.invalidResponse("Unable to decode \(method) response: \(error.localizedDescription)")
        }
    }

    func subscribeToNotifications(methods: Set<String>) -> CodexNotificationSubscription {
        let subscription = CodexNotificationSubscription(id: UUID())
        notificationSubscriptions[subscription.id] = NotificationSubscriptionState(methods: methods)
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
        if let index = state.buffered.firstIndex(where: { matching($0.params) }) {
            let notification = state.buffered.remove(at: index)
            notificationSubscriptions[subscription.id] = state
            return notification
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

    func restart() async throws {
        shutdownProcess(error: CodexAppServerError.restarted)
        try await ensureStarted()
    }

    func shutdown() {
        shuttingDown = true
        shutdownProcess(error: CodexAppServerError.shutdown)
    }

    private func ensureStarted() async throws {
        if isInitialized, let process, process.isRunning { return }
        if isStarting {
            try await withCheckedThrowingContinuation { startupWaiters.append($0) }
            return
        }

        isStarting = true
        shuttingDown = false
        if process != nil || stdinHandle != nil || stdoutBuffer.isEmpty == false {
            shutdownProcess(error: CodexAppServerError.restarted)
        }
        do {
            try launchProcess()
            let params = CodexInitializeParams(
                clientInfo: .init(name: "langtools-cli", title: "LangTools CLI", version: "1"),
                capabilities: .init(
                    experimentalApi: false,
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
                cancelOnTaskCancellation: true
            )
            _ = try JSONDecoder().decode(CodexInitializeResponse.self, from: responseData)
            try writeJSONObject(["method": "initialized"])
            isInitialized = true
            isStarting = false
            let waiters = startupWaiters
            startupWaiters.removeAll()
            waiters.forEach { $0.resume() }
        } catch {
            isStarting = false
            shutdownProcess(error: error)
            let waiters = startupWaiters
            startupWaiters.removeAll()
            waiters.forEach { $0.resume(throwing: error) }
            throw error
        }
    }

    private func launchProcess() throws {
        let command = try commandResolver()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments + ["app-server", "--listen", "stdio://"]

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
        let stdoutPump = ProcessChunkPump(label: "LangToolsCLI.CodexAppServer.stdout")
        let stderrPump = ProcessChunkPump(label: "LangToolsCLI.CodexAppServer.stderr")
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

    private func sendRequest(
        method: String,
        params: Any,
        timeout: Duration,
        cancelOnTaskCancellation: Bool
    ) async throws -> Data {
        guard let process, process.isRunning else { throw CodexAppServerError.unavailable }
        let requestID = nextRequestID
        nextRequestID += 1

        let operation = {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    await self?.failPending(id: requestID, error: CodexAppServerError.timeout(method))
                }
                self.pending[requestID] = PendingRequest(continuation: continuation, timeoutTask: timeoutTask)
                do {
                    try self.writeJSONObject(["id": requestID, "method": method, "params": params])
                } catch {
                    self.failPending(id: requestID, error: error)
                }
            }
        }
        guard cancelOnTaskCancellation else {
            return try await operation()
        }
        return try await withTaskCancellationHandler(operation: operation) {
            Task { [weak self] in
                await self?.failPending(id: requestID, error: CancellationError())
            }
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
            let line = stdoutBuffer[..<newline]
            stdoutBuffer.removeSubrange(...newline)
            guard line.isEmpty == false else { continue }
            handleLine(Data(line))
        }
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
            guard var state = notificationSubscriptions[subscriptionID], state.methods.contains(method) else { continue }
            if let waiter = state.waiter, waiter.matches(paramsData) {
                state.waiter = nil
                notificationSubscriptions[subscriptionID] = state
                waiter.timeoutTask.cancel()
                waiter.continuation.resume(returning: notification)
            } else {
                state.buffered.append(notification)
                notificationSubscriptions[subscriptionID] = state
            }
        }
    }

    private func declineServerRequest(_ request: [String: Any]) {
        guard let id = request["id"] else { return }
        let method = request["method"] as? String ?? "unknown"
        let result: [String: Any]?
        switch method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            result = ["decision": "decline"]
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
    case transport(String)
    case invalidResponse(String)
    case invalidRequest(String)
    case server(code: Int?, message: String)
    case timeout(String)
    case exited(status: Int32, stderr: String)
    case restarted
    case shutdown

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Codex CLI is not available. Install it, put `codex` on PATH, or set LANGTOOLS_CODEX_PATH."
        case .transport(let message): return "Codex app-server transport failed: \(message)"
        case .invalidResponse(let message): return "Codex app-server returned an invalid response: \(message)"
        case .invalidRequest(let message), .server(_, let message): return message
        case .timeout(let method): return "Codex app-server timed out while waiting for \(method)."
        case .exited(let status, _):
            return "Codex app-server exited with status \(status)."
        case .restarted: return "Codex app-server restarted."
        case .shutdown: return "Codex app-server shut down."
        }
    }
}
