import Foundation
import Network

public enum LocalhostOAuthCallbackListenerError: LocalizedError, Equatable {
    case listenerStartupFailed
    case callbackTimedOut
    case invalidCallbackRequest

    public var errorDescription: String? {
        switch self {
        case .listenerStartupFailed:
            return "Unable to start the localhost OAuth callback listener."
        case .callbackTimedOut:
            return "Timed out waiting for the OAuth callback."
        case .invalidCallbackRequest:
            return "The OAuth callback request was invalid."
        }
    }
}

public final class LocalhostOAuthCallbackListener {
    private let preferredPorts: [UInt16]
    private let path: String
    private let host: String
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "LocalhostOAuthCallbackListener")
    private var continuation: CheckedContinuation<URL, Error>?
    private var timeoutTask: Task<Void, Never>?

    public init(
        preferredPorts: [UInt16] = [1455, 1456, 1457, 1458, 1459],
        host: String = "127.0.0.1",
        path: String = "/auth/callback"
    ) {
        self.preferredPorts = preferredPorts
        self.host = host
        self.path = path
    }

    deinit {
        stop()
    }

    public func start(timeout: TimeInterval = 180) async throws -> URL {
        let port = try startListener()
        let callbackURL = URL(string: "http://\(host):\(port)\(path)")!
        scheduleTimeout(after: timeout)
        return callbackURL
    }

    public func waitForCallback() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    public func stop() {
        timeoutTask?.cancel()
        timeoutTask = nil
        listener?.cancel()
        listener = nil
        continuation = nil
    }

    private func scheduleTimeout(after timeout: TimeInterval) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            guard timeout > 0 else { return }
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await self?.finish(with: .failure(LocalhostOAuthCallbackListenerError.callbackTimedOut))
        }
    }

    private func startListener() throws -> UInt16 {
        for preferredPort in preferredPorts {
            do {
                let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: preferredPort)!)
                self.listener = listener
                listener.newConnectionHandler = { [weak self] connection in
                    self?.handle(connection: connection)
                }
                listener.start(queue: queue)
                return preferredPort
            } catch {
                continue
            }
        }

        throw LocalhostOAuthCallbackListenerError.listenerStartupFailed
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else { return }
            let result: Result<URL, Error>
            if let data,
               let request = String(data: data, encoding: .utf8),
               let url = self.parseRequestURL(from: request) {
                result = .success(url)
                self.respond(to: connection, success: true)
            } else {
                result = .failure(LocalhostOAuthCallbackListenerError.invalidCallbackRequest)
                self.respond(to: connection, success: false)
            }

            connection.cancel()
            Task {
                await self.finish(with: result)
            }
        }
    }

    private func parseRequestURL(from request: String) -> URL? {
        guard let requestLine = request.split(separator: "\r\n").first else {
            return nil
        }

        let components = requestLine.split(separator: " ")
        guard components.count >= 2 else {
            return nil
        }

        let requestPath = String(components[1])
        guard requestPath.hasPrefix(path) else {
            return nil
        }

        return URL(string: "http://\(host)\(requestPath)")
    }

    private func respond(to connection: NWConnection, success: Bool) {
        let body = success
            ? "<html><body><h1>Authentication complete</h1><p>You can return to the app.</p></body></html>"
            : "<html><body><h1>Authentication failed</h1><p>You can close this window and try again.</p></body></html>"
        let response = "HTTP/1.1 \(success ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in })
    }

    @MainActor
    private func finish(with result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        stop()
        switch result {
        case .success(let url): continuation.resume(returning: url)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }
}
