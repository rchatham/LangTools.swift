import Foundation
import Network

struct LocalHelperServer {
    let host: String
    let port: UInt16
    let bearerToken: String
    let queue = DispatchQueue(label: "LangToolsCLI.LocalHelperServer")
    private let connectionLimiter: HelperConnectionLimiter

    static let maximumHeaderBytes = 32 * 1_024
    static let maximumBodyBytes = 4 * 1_048_576
    static let maximumConcurrentConnections = 32
    static let requestReadTimeout: Duration = .seconds(10)

    init(host: String, port: UInt16, bearerToken: String) {
        self.host = host
        self.port = port
        self.bearerToken = bearerToken
        self.connectionLimiter = HelperConnectionLimiter(limit: Self.maximumConcurrentConnections)
    }

    func run() async throws {
        guard Self.loopbackHosts.contains(host.lowercased()) else {
            throw HelperServerError.nonLoopbackHost(host)
        }
        guard bearerToken.isEmpty == false else {
            throw HelperServerError.emptyBearerToken
        }
        guard let listenerPort = NWEndpoint.Port(rawValue: port) else {
            throw HelperServerError.invalidPort(port)
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: listenerPort)
        let listener = try NWListener(using: parameters)
        let startup = ServerStartup()
        listener.newConnectionHandler = { connection in
            self.handle(connection: connection)
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                startup.succeed(host: self.host, port: self.port)
            case .failed(let error):
                startup.fail(error)
            default:
                break
            }
        }
        listener.start(queue: queue)

        try await startup.waitUntilReady()
        while true {
            try await Task.sleep(nanoseconds: 86_400_000_000_000)
        }
    }

    private static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

    private func handle(connection: NWConnection) {
        guard let lease = connectionLimiter.acquire() else {
            connection.cancel()
            return
        }
        let session = HelperConnectionSession(connection: connection, lease: lease)
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled:
                Task { await session.cancelRoute() }
            default:
                break
            }
        }
        connection.start(queue: queue)
        Task {
            await session.startReadDeadline(after: Self.requestReadTimeout) {
                await self.respond(
                    session: session,
                    status: .requestTimeout,
                    body: Self.errorBody("Request read timed out.")
                )
            }
        }
        receiveRequest(session: session, accumulated: Data())
    }

    private func receiveRequest(session: HelperConnectionSession, accumulated: Data) {
        session.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { data, _, isComplete, error in
            var requestData = accumulated
            if let data { requestData.append(data) }

            switch HTTPRequest.parse(from: requestData) {
            case .request(let request):
                guard SecureTokenComparison.matches(
                    expected: self.bearerToken,
                    provided: request.authorizationBearerToken
                ) else {
                    self.scheduleResponse(session: session, status: .unauthorized, body: Self.errorBody("Unauthorized."))
                    return
                }
                Task {
                    await session.beginRoute {
                        await self.route(request: request, session: session)
                    }
                }
            case .failure(let status, let message):
                self.scheduleResponse(session: session, status: status, body: Self.errorBody(message))
            case .incomplete:
                if error != nil || isComplete {
                    self.scheduleResponse(
                        session: session,
                        status: .badRequest,
                        body: Self.errorBody("Malformed or incomplete request.")
                    )
                } else {
                    self.receiveRequest(session: session, accumulated: requestData)
                }
            }
        }
    }

    private func route(request: HTTPRequest, session: HelperConnectionSession) async {
        do {
            if let routingError = Self.routeErrorStatus(method: request.method, path: request.path) {
                let message = routingError == .notFound ? "Not found." : "Method not allowed."
                await respond(session: session, status: routingError, body: Self.errorBody(message))
                return
            }
            if request.path.hasPrefix("/v1/account/conversations/") {
                guard let conversationID = Self.conversationID(fromCleanupPath: request.path) else {
                    throw CodexRuntimeError.badRequest("A valid conversation UUID is required.")
                }
                await CodexRuntimeService.shared.endConversation(id: conversationID)
                await respond(session: session, status: .noContent, body: "")
                return
            }

            switch request.path {
            case "/health":
                let body = try Self.jsonBody(HelperHealthResponse(status: "ok", version: 1))
                await respond(session: session, status: .ok, body: body)
            case "/v1/auth/status":
                let body = try Self.jsonBody(try await authStatusResponse())
                await respond(session: session, status: .ok, body: body)
            case "/v1/models/codex":
                let body = try Self.jsonBody(HelperModelsResponse(models: try await AuthCLI.openAIAccessibleModelIDs()))
                await respond(session: session, status: .ok, body: body)
            case "/v1/auth/login":
                let payload = try JSONDecoder().decode(HelperAuthRequest.self, from: request.body)
                guard Self.isOpenAI(payload.provider) else {
                    throw CodexRuntimeError.badRequest("Only openAI is currently supported.")
                }
                let body = try Self.jsonBody(try await AuthCLI.loginOpenAI())
                await respond(session: session, status: .ok, body: body)
            case "/v1/auth/logout":
                let payload = try JSONDecoder().decode(HelperAuthRequest.self, from: request.body)
                guard Self.isOpenAI(payload.provider) else {
                    throw CodexRuntimeError.badRequest("Only openAI is currently supported.")
                }
                try await AuthCLI.logoutOpenAI()
                let body = try Self.jsonBody(HelperHealthResponse(status: "ok", version: 1))
                await respond(session: session, status: .ok, body: body)
            case "/v1/account/chat/completions":
                let payload = try JSONDecoder().decode(HelperChatRequest.self, from: request.body)
                try Self.validateChatPayload(payload)
                if payload.stream {
                    await streamChat(payload, session: session)
                } else {
                    let content = try await OpenAIAccountChatCommand.performChat(
                        modelID: payload.model,
                        messages: payload.messages,
                        codexHomeOverride: nil,
                        conversationID: payload.conversationID
                    )
                    let body = try Self.jsonBody(HelperChatResponse(content: content))
                    await respond(session: session, status: .ok, body: body)
                }
            default:
                await respond(session: session, status: .notFound, body: Self.errorBody("Not found."))
            }
        } catch {
            await respond(
                session: session,
                status: Self.httpStatus(for: error),
                body: Self.errorBody(error.localizedDescription)
            )
        }
    }

    private func streamChat(_ payload: HelperChatRequest, session: HelperConnectionSession) async {
        do {
            try await session.send(HTTPResponseEncoder.chunkedHeader(status: .ok))
            let stream = await CodexRuntimeService.shared.chatStream(
                model: payload.model,
                messages: payload.messages,
                conversationID: payload.conversationID
            )
            do {
                for try await event in stream {
                    let wireEvent: HelperChatStreamEvent
                    switch event {
                    case .delta(let value): wireEvent = .delta(value)
                    case .complete(let value): wireEvent = .complete(value)
                    }
                    try await session.send(try HTTPResponseEncoder.ndjsonChunk(wireEvent))
                }
            } catch is CancellationError {
                guard Task.isCancelled == false else { throw CancellationError() }
                let failure = HelperChatStreamEvent.failure("Request cancelled.")
                try await session.send(try HTTPResponseEncoder.ndjsonChunk(failure))
            } catch {
                let failure = HelperChatStreamEvent.failure(error.localizedDescription)
                try await session.send(try HTTPResponseEncoder.ndjsonChunk(failure))
            }
            try await session.send(HTTPResponseEncoder.terminalChunk)
            await session.finish()
        } catch {
            await session.cancelRoute()
        }
    }

    private func scheduleResponse(session: HelperConnectionSession, status: HTTPStatus, body: String) {
        Task {
            await session.beginRoute {
                await respond(session: session, status: status, body: body)
            }
        }
    }

    private func respond(session: HelperConnectionSession, status: HTTPStatus, body: String) async {
        do { try await session.send(HTTPResponseEncoder.fixed(status: status, body: body)) }
        catch { /* The peer disconnected; no response can be delivered. */ }
        await session.finish()
    }

    private func authStatusResponse() async throws -> HelperAuthStatusResponse {
        do {
            let status = try await CodexRuntimeService.shared.accountStatus()
            return HelperAuthStatusResponse(
                provider: "openAI",
                authenticated: status.authenticated,
                accountIdentifier: status.accountIdentifier,
                expiresAt: nil,
                accessibleModelIDs: status.authenticated ? try await AuthCLI.openAIAccessibleModelIDs() : nil
            )
        } catch CodexAppServerError.unavailable {
            return unauthenticatedStatusResponse()
        } catch CodexAppServerError.exited {
            return unauthenticatedStatusResponse()
        }
    }

    private func unauthenticatedStatusResponse() -> HelperAuthStatusResponse {
        HelperAuthStatusResponse(
            provider: "openAI",
            authenticated: false,
            accountIdentifier: nil,
            expiresAt: nil,
            accessibleModelIDs: nil
        )
    }

    private static func isOpenAI(_ provider: String) -> Bool {
        provider == "openAI" || provider == "openai"
    }

    private static func validateChatPayload(_ payload: HelperChatRequest) throws {
        guard isOpenAI(payload.provider) else {
            throw CodexRuntimeError.badRequest("Only openAI is currently supported.")
        }
        let supportedRoles: Set<String> = ["system", "user", "assistant", "tool"]
        guard payload.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              payload.messages.isEmpty == false,
              payload.messages.allSatisfy({ supportedRoles.contains($0.role.lowercased()) })
        else {
            throw CodexRuntimeError.badRequest("A model and valid chat messages are required.")
        }
    }

    static func routeErrorStatus(method: String, path: String) -> HTTPStatus? {
        if path.hasPrefix("/v1/account/conversations/") {
            return method == "DELETE" ? nil : .methodNotAllowed
        }
        guard let allowedMethod = allowedMethod(for: path) else { return .notFound }
        return method == allowedMethod ? nil : .methodNotAllowed
    }

    private static func allowedMethod(for path: String) -> String? {
        switch path {
        case "/health", "/v1/auth/status", "/v1/models/codex": return "GET"
        case "/v1/auth/login", "/v1/auth/logout", "/v1/account/chat/completions": return "POST"
        default: return nil
        }
    }

    static func conversationID(fromCleanupPath path: String) -> UUID? {
        let prefix = "/v1/account/conversations/"
        guard path.hasPrefix(prefix) else { return nil }
        let value = String(path.dropFirst(prefix.count))
        guard value.isEmpty == false, value.contains("/") == false else { return nil }
        return UUID(uuidString: value)
    }

    static func httpStatus(for error: Error) -> HTTPStatus {
        if error is DecodingError || error is CancellationError { return .badRequest }
        if let runtimeError = error as? CodexRuntimeError {
            switch runtimeError {
            case .badRequest: return .badRequest
            case .authentication: return .unauthorized
            case .quotaExceeded: return .tooManyRequests
            case .overloaded: return .serviceUnavailable
            case .accountConflict: return .conflict
            case .timeout: return .gatewayTimeout
            case .responseTooLarge: return .payloadTooLarge
            case .browserOpenFailed, .invalidResponse, .runtime: return .internalServerError
            }
        }
        if let appServerError = error as? CodexAppServerError {
            switch appServerError {
            case .invalidRequest: return .badRequest
            case .timeout: return .gatewayTimeout
            default: break
            }
        }
        return .internalServerError
    }

    private static func jsonBody<T: Encodable>(_ payload: T) throws -> String {
        let data = try HTTPResponseEncoder.makeJSONEncoder().encode(payload)
        return String(decoding: data, as: UTF8.self)
    }

    private static func errorBody(_ message: String) -> String {
        (try? jsonBody(HelperErrorResponse(error: message))) ?? "{\"error\":\"Unknown error.\"}"
    }
}

enum HTTPStatus: String, Equatable, Sendable {
    case ok = "200 OK"
    case noContent = "204 No Content"
    case badRequest = "400 Bad Request"
    case unauthorized = "401 Unauthorized"
    case notFound = "404 Not Found"
    case methodNotAllowed = "405 Method Not Allowed"
    case requestTimeout = "408 Request Timeout"
    case conflict = "409 Conflict"
    case lengthRequired = "411 Length Required"
    case payloadTooLarge = "413 Payload Too Large"
    case tooManyRequests = "429 Too Many Requests"
    case requestHeaderFieldsTooLarge = "431 Request Header Fields Too Large"
    case internalServerError = "500 Internal Server Error"
    case serviceUnavailable = "503 Service Unavailable"
    case gatewayTimeout = "504 Gateway Timeout"
}

enum HTTPRequestParseResult {
    case incomplete
    case request(HTTPRequest)
    case failure(HTTPStatus, String)
}

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    var authorizationBearerToken: String? {
        guard let authorization = headers["authorization"] else { return nil }
        let parts = authorization.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].lowercased() == "bearer", parts[1].isEmpty == false else { return nil }
        return String(parts[1])
    }

    static func parse(from data: Data) -> HTTPRequestParseResult {
        let separator = Data("\r\n\r\n".utf8)
        guard let separatorRange = data.range(of: separator) else {
            return data.count > LocalHelperServer.maximumHeaderBytes
                ? .failure(.requestHeaderFieldsTooLarge, "Request headers exceed the size limit.")
                : .incomplete
        }
        guard separatorRange.upperBound <= LocalHelperServer.maximumHeaderBytes else {
            return .failure(.requestHeaderFieldsTooLarge, "Request headers exceed the size limit.")
        }
        let headData = data[..<separatorRange.lowerBound]
        guard headData.contains(0) == false, let head = String(data: headData, encoding: .utf8) else {
            return .failure(.badRequest, "Malformed request headers.")
        }
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, requestLine.contains("\n") == false else {
            return .failure(.badRequest, "Malformed request line.")
        }
        let requestParts = requestLine.components(separatedBy: " ")
        guard requestParts.count == 3,
              isToken(requestParts[0]),
              requestParts[0] == requestParts[0].uppercased(),
              requestParts[1].hasPrefix("/"),
              requestParts[1].contains("#") == false,
              requestParts[1].unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }),
              requestParts[2] == "HTTP/1.1"
        else {
            return .failure(.badRequest, "Malformed HTTP/1.1 request line.")
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard line.isEmpty == false,
                  line.first != " " && line.first != "\t",
                  line.contains("\n") == false,
                  let colon = line.firstIndex(of: ":")
            else { return .failure(.badRequest, "Malformed header line.") }
            let rawName = String(line[..<colon])
            guard isToken(rawName) else { return .failure(.badRequest, "Malformed header name.") }
            let name = rawName.lowercased()
            guard headers[name] == nil else { return .failure(.badRequest, "Duplicate header fields are not accepted.") }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard value.unicodeScalars.allSatisfy({ $0.value == 9 || ($0.value >= 32 && $0.value != 127) }) else {
                return .failure(.badRequest, "Malformed header value.")
            }
            headers[name] = value
        }
        guard let host = headers["host"], host.isEmpty == false else {
            return .failure(.badRequest, "A Host header is required.")
        }
        guard headers["transfer-encoding"] == nil else {
            return .failure(.badRequest, "Inbound transfer encoding is not supported.")
        }

        let requiresLength = ["POST", "PUT", "PATCH"].contains(requestParts[0])
        let contentLength: Int
        if let value = headers["content-length"] {
            guard value.isEmpty == false,
                  value.allSatisfy(\.isNumber),
                  let parsed = Int(value)
            else { return .failure(.badRequest, "Invalid Content-Length header.") }
            contentLength = parsed
        } else if requiresLength {
            return .failure(.lengthRequired, "Content-Length is required.")
        } else {
            contentLength = 0
        }
        guard contentLength <= LocalHelperServer.maximumBodyBytes else {
            return .failure(.payloadTooLarge, "Request body exceeds the size limit.")
        }

        let bodyStart = separatorRange.upperBound
        let receivedBodyBytes = data.count - bodyStart
        guard receivedBodyBytes >= contentLength else { return .incomplete }
        guard receivedBodyBytes == contentLength else {
            return .failure(.badRequest, "Trailing or pipelined request bytes are not accepted.")
        }
        let target = requestParts[1]
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target
        return .request(HTTPRequest(
            method: requestParts[0],
            path: path,
            headers: headers,
            body: data.subdata(in: bodyStart..<data.count)
        ))
    }

    private static func isToken(_ value: String) -> Bool {
        let allowed = "!#$%&'*+-.^_`|~"
        return value.isEmpty == false && value.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57)
                || (scalar.value >= 65 && scalar.value <= 90)
                || (scalar.value >= 97 && scalar.value <= 122)
                || allowed.unicodeScalars.contains(scalar)
        }
    }
}

enum HTTPResponseEncoder {
    static func makeJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static let terminalChunk = Data("0\r\n\r\n".utf8)

    static func fixed(status: HTTPStatus, body: String) -> Data {
        let bodyData = Data(body.utf8)
        let header = "HTTP/1.1 \(status.rawValue)\r\nContent-Type: application/json; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        return Data(header.utf8) + bodyData
    }

    static func chunkedHeader(status: HTTPStatus) -> Data {
        Data("HTTP/1.1 \(status.rawValue)\r\nContent-Type: application/x-ndjson; charset=utf-8\r\nCache-Control: no-store\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n".utf8)
    }

    static func ndjsonChunk<T: Encodable>(_ value: T) throws -> Data {
        var payload = try makeJSONEncoder().encode(value)
        payload.append(UInt8(ascii: "\n"))
        return chunk(payload)
    }

    static func chunk(_ payload: Data) -> Data {
        var framed = Data(String(payload.count, radix: 16).utf8)
        framed.append(Data("\r\n".utf8))
        framed.append(payload)
        framed.append(Data("\r\n".utf8))
        return framed
    }
}

final class HelperConnectionLimiter: @unchecked Sendable {
    let limit: Int
    private let lock = NSLock()
    private var active = 0

    init(limit: Int) {
        precondition(limit > 0)
        self.limit = limit
    }

    var activeCount: Int {
        lock.withLock { active }
    }

    func acquire() -> HelperConnectionLease? {
        lock.withLock {
            guard active < limit else { return nil }
            active += 1
            return HelperConnectionLease { [weak self] in self?.releaseOne() }
        }
    }

    private func releaseOne() {
        lock.withLock {
            precondition(active > 0)
            active -= 1
        }
    }
}

final class HelperConnectionLease: @unchecked Sendable {
    private let lock = NSLock()
    private var releaseAction: (@Sendable () -> Void)?

    init(releaseAction: @escaping @Sendable () -> Void) {
        self.releaseAction = releaseAction
    }

    func release() {
        let action = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { releaseAction = nil }
            return releaseAction
        }
        action?()
    }

    deinit { release() }
}

final class HelperRequestDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private let handler: @Sendable () -> Void
    private var active = true
    private var task: Task<Void, Never>?

    init(handler: @escaping @Sendable () -> Void) {
        self.handler = handler
    }

    func schedule(after duration: Duration) {
        lock.lock()
        guard active, task == nil else {
            lock.unlock()
            return
        }
        task = Task { [weak self] in
            do { try await Task.sleep(for: duration) }
            catch { return }
            self?.fire()
        }
        lock.unlock()
    }

    func fire() {
        lock.lock()
        guard active else {
            lock.unlock()
            return
        }
        active = false
        task = nil
        lock.unlock()
        handler()
    }

    func cancel() {
        lock.lock()
        guard active else {
            lock.unlock()
            return
        }
        active = false
        let task = task
        self.task = nil
        lock.unlock()
        task?.cancel()
    }

    deinit { cancel() }
}

enum SecureTokenComparison {
    static func matches(expected: String, provided: String?, maximumBytes: Int = HelperTokenLoader.maximumTokenBytes) -> Bool {
        guard let provided, maximumBytes >= 0 else { return false }
        let expectedBytes = Array(expected.utf8)
        let providedBytes = Array(provided.utf8)
        guard expectedBytes.count <= maximumBytes, providedBytes.count <= maximumBytes else { return false }

        var difference = UInt(expectedBytes.count ^ providedBytes.count)
        for index in 0..<maximumBytes {
            let expectedByte = index < expectedBytes.count ? expectedBytes[index] : 0
            let providedByte = index < providedBytes.count ? providedBytes[index] : 0
            difference |= UInt(expectedByte ^ providedByte)
        }
        return difference == 0
    }
}

private actor HelperConnectionSession {
    nonisolated let connection: NWConnection
    private let lease: HelperConnectionLease
    private var routeTask: Task<Void, Never>?
    private var readDeadline: HelperRequestDeadline?
    private var ended = false

    init(connection: NWConnection, lease: HelperConnectionLease) {
        self.connection = connection
        self.lease = lease
    }

    func startReadDeadline(
        after duration: Duration,
        onTimeout: @escaping @Sendable () async -> Void
    ) {
        guard ended == false, routeTask == nil, readDeadline == nil else { return }
        let deadline = HelperRequestDeadline { [weak self] in
            Task { await self?.beginRoute(onTimeout) }
        }
        readDeadline = deadline
        deadline.schedule(after: duration)
    }

    func beginRoute(_ operation: @escaping @Sendable () async -> Void) {
        guard ended == false, routeTask == nil else { return }
        readDeadline?.cancel()
        readDeadline = nil
        routeTask = Task { await operation() }
    }

    func send(_ data: Data) async throws {
        try Task.checkCancellation()
        guard ended == false else { throw CancellationError() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
        try Task.checkCancellation()
    }

    func cancelRoute() {
        guard ended == false else { return }
        ended = true
        readDeadline?.cancel()
        readDeadline = nil
        routeTask?.cancel()
        connection.cancel()
        lease.release()
    }

    func finish() {
        guard ended == false else { return }
        ended = true
        readDeadline?.cancel()
        readDeadline = nil
        connection.cancel()
        routeTask = nil
        lease.release()
    }
}

enum HelperServerError: LocalizedError {
    case nonLoopbackHost(String)
    case emptyBearerToken
    case invalidPort(UInt16)

    var errorDescription: String? {
        switch self {
        case .nonLoopbackHost(let host): return "Refusing to bind helper to non-loopback host: \(host)"
        case .emptyBearerToken: return "Helper bearer token must not be empty."
        case .invalidPort(let port): return "Invalid helper port: \(port)"
        }
    }
}

private final class ServerStartup: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func succeed(host: String, port: UInt16) {
        finish(.success(())) {
            print("LangToolsCLI helper running")
            print("URL: http://\(host):\(port)")
            print("Run until interrupted (Ctrl+C).")
        }
    }

    func fail(_ error: Error) {
        finish(.failure(error), sideEffect: {})
    }

    private func finish(_ result: Result<Void, Error>, sideEffect: () -> Void) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        sideEffect()
        continuation?.resume(with: result)
    }
}
