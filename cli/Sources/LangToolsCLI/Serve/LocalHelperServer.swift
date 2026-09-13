import Foundation
import Network

struct LocalHelperServer {
    let host: String
    let port: UInt16
    let bearerToken: String
    let queue = DispatchQueue(label: "LangToolsCLI.LocalHelperServer")

    static let maximumRequestBytes = 4 * 1_048_576

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
                startup.succeed(host: self.host, port: self.port, token: self.bearerToken)
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
        connection.start(queue: queue)
        receiveRequest(connection: connection, accumulated: Data())
    }

    private func receiveRequest(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            var requestData = accumulated
            if let data { requestData.append(data) }

            if requestData.count > Self.maximumRequestBytes {
                self.respond(connection: connection, status: "413 Payload Too Large", body: Self.errorBody("Request exceeds the size limit."))
                return
            }
            if let request = HTTPRequest.parseComplete(from: requestData) {
                guard request.authorizationBearerToken == self.bearerToken else {
                    self.respond(connection: connection, status: "401 Unauthorized", body: Self.errorBody("Unauthorized."))
                    return
                }
                Task { await self.route(request: request, connection: connection) }
                return
            }
            if error != nil || isComplete {
                self.respond(connection: connection, status: "400 Bad Request", body: Self.errorBody("Malformed or incomplete request."))
                return
            }
            self.receiveRequest(connection: connection, accumulated: requestData)
        }
    }

    private func route(request: HTTPRequest, connection: NWConnection) async {
        do {
            switch (request.method, request.path) {
            case ("GET", "/health"):
                let body = try Self.jsonBody(HelperHealthResponse(status: "ok", version: 1))
                respond(connection: connection, status: "200 OK", body: body)
            case ("GET", "/v1/auth/status"):
                let body = try Self.jsonBody(try await authStatusResponse())
                respond(connection: connection, status: "200 OK", body: body)
            case ("GET", "/v1/models/codex"):
                let body = try Self.jsonBody(HelperModelsResponse(models: try await AuthCLI.openAIAccessibleModelIDs()))
                respond(connection: connection, status: "200 OK", body: body)
            case ("POST", "/v1/auth/login"):
                let payload = try JSONDecoder().decode(HelperAuthRequest.self, from: request.body)
                guard payload.provider == "openAI" || payload.provider == "openai" else {
                    respond(connection: connection, status: "400 Bad Request", body: Self.errorBody("Only openAI is currently supported."))
                    return
                }
                let session = try await AuthCLI.loginOpenAI()
                let body = try Self.jsonBody(session)
                respond(connection: connection, status: "200 OK", body: body)
            case ("POST", "/v1/auth/logout"):
                let payload = try JSONDecoder().decode(HelperAuthRequest.self, from: request.body)
                guard payload.provider == "openAI" || payload.provider == "openai" else {
                    respond(connection: connection, status: "400 Bad Request", body: Self.errorBody("Only openAI is currently supported."))
                    return
                }
                try await AuthCLI.logoutOpenAI()
                let body = try Self.jsonBody(HelperHealthResponse(status: "ok", version: 1))
                respond(connection: connection, status: "200 OK", body: body)
            case ("POST", "/v1/account/chat/completions"):
                let payload = try JSONDecoder().decode(HelperChatRequest.self, from: request.body)
                guard payload.provider == "openAI" || payload.provider == "openai" else {
                    respond(connection: connection, status: "400 Bad Request", body: Self.errorBody("Only openAI is currently supported."))
                    return
                }
                let supportedRoles: Set<String> = ["system", "user", "assistant", "tool"]
                guard payload.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                      payload.messages.isEmpty == false,
                      payload.messages.allSatisfy({ supportedRoles.contains($0.role.lowercased()) })
                else {
                    throw CodexRuntimeError.badRequest("A model and valid chat messages are required.")
                }
                let content = try await OpenAIAccountChatCommand.performChat(
                    modelID: payload.model,
                    messages: payload.messages.map { .init(role: $0.role, content: $0.content) },
                    codexHomeOverride: nil
                )
                let body = try Self.jsonBody(HelperChatResponse(content: content))
                respond(connection: connection, status: "200 OK", body: body)
            default:
                respond(connection: connection, status: "404 Not Found", body: Self.errorBody("Not found."))
            }
        } catch {
            respond(
                connection: connection,
                status: Self.httpStatus(for: error),
                body: Self.errorBody(error.localizedDescription)
            )
        }
    }

    private func respond(connection: NWConnection, status: String, body: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: application/json; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
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

    static func httpStatus(for error: Error) -> String {
        if error is DecodingError || error is CancellationError { return "400 Bad Request" }
        if let runtimeError = error as? CodexRuntimeError {
            switch runtimeError {
            case .badRequest: return "400 Bad Request"
            case .authentication: return "401 Unauthorized"
            case .quotaExceeded: return "429 Too Many Requests"
            case .overloaded: return "503 Service Unavailable"
            case .accountConflict: return "409 Conflict"
            case .timeout: return "504 Gateway Timeout"
            case .browserOpenFailed, .invalidResponse, .runtime: return "500 Internal Server Error"
            }
        }
        if let appServerError = error as? CodexAppServerError {
            switch appServerError {
            case .invalidRequest: return "400 Bad Request"
            case .timeout: return "504 Gateway Timeout"
            default: break
            }
        }
        return "500 Internal Server Error"
    }

    private static func jsonBody<T: Encodable>(_ payload: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        return String(decoding: data, as: UTF8.self)
    }

    private static func errorBody(_ message: String) -> String {
        (try? jsonBody(HelperErrorResponse(error: message))) ?? "{\"error\":\"Unknown error.\"}"
    }
}

enum HelperServerError: LocalizedError {
    case nonLoopbackHost(String)
    case emptyBearerToken
    case invalidPort(UInt16)

    var errorDescription: String? {
        switch self {
        case .nonLoopbackHost(let host):
            return "Refusing to bind helper to non-loopback host: \(host)"
        case .emptyBearerToken:
            return "Helper bearer token must not be empty."
        case .invalidPort(let port):
            return "Invalid helper port: \(port)"
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

    func succeed(host: String, port: UInt16, token: String) {
        finish(.success(())) {
            print("LangToolsCLI helper running")
            print("URL: http://\(host):\(port)")
            print("Token: \(token)")
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

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    var authorizationBearerToken: String? {
        guard let authorization = headers["authorization"] else { return nil }
        let prefix = "Bearer "
        guard authorization.hasPrefix(prefix) else { return nil }
        return String(authorization.dropFirst(prefix.count))
    }

    static func parseComplete(from data: Data) -> HTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let separatorRange = data.range(of: separator),
              let head = String(data: data[..<separatorRange.lowerBound], encoding: .utf8)
        else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        let contentLength: Int
        if let value = headers["content-length"] {
            guard let parsed = Int(value), parsed >= 0 else { return nil }
            contentLength = parsed
        } else {
            contentLength = 0
        }
        let bodyStart = separatorRange.upperBound
        guard data.count >= bodyStart + contentLength else { return nil }
        let body = data.subdata(in: bodyStart..<(bodyStart + contentLength))

        return HTTPRequest(
            method: String(requestParts[0]),
            path: String(requestParts[1]).components(separatedBy: "?").first ?? String(requestParts[1]),
            headers: headers,
            body: body
        )
    }
}
