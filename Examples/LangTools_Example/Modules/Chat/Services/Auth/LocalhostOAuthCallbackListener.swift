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
    private var completedURL: URL?
    private var finishTask: Task<Void, Never>?

    public init(
        preferredPorts: [UInt16] = [1455, 1456, 1457, 1458, 1459],
        host: String = "localhost",
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
        finishTask?.cancel()
        finishTask = nil
        listener?.cancel()
        listener = nil
        continuation = nil
        completedURL = nil
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
            if self.completedURL != nil {
                self.respond(to: connection, success: true) {
                    connection.cancel()
                }
                return
            }

            let result: Result<URL, Error>
            let success: Bool
            if let data,
               let request = String(data: data, encoding: .utf8),
               let url = self.parseRequestURL(from: request) {
                result = .success(url)
                success = true
                self.completedURL = url
            } else {
                result = .failure(LocalhostOAuthCallbackListenerError.invalidCallbackRequest)
                success = false
            }

            self.respond(to: connection, success: success) {
                connection.cancel()
                if success {
                    self.finishTask?.cancel()
                    self.finishTask = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 15_000_000_000)
                        self?.stop()
                    }
                    Task {
                        await self.finish(with: result, keepListenerAlive: true)
                    }
                } else {
                    Task {
                        await self.finish(with: result)
                    }
                }
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

    private func respond(to connection: NWConnection, success: Bool, completion: @escaping () -> Void) {
        let body = success
            ? Self.callbackHTML(title: "OpenAI sign-in complete", message: "Your OpenAI account is connected. Return to LangTools Example to continue.", success: true)
            : Self.callbackHTML(title: "Authentication failed", message: "The callback could not be processed. You can close this tab and try again.", success: false)
        let response = "HTTP/1.1 \(success ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in completion() })
    }

    private static func callbackHTML(title: String, message: String, success: Bool) -> String {
        let accent = success ? "#1f8f4e" : "#b42318"
        let returnURL = "langtools-example-auth://auth/return"
        let returnButton = success
            ? "<a class=\"button\" href=\"\(returnURL)\">Return to LangTools Example</a>"
            : ""
        let hint = success
            ? "Your OpenAI account is connected in LangTools Example. You can close this tab if the app is already in front."
            : "If the app does not update automatically, switch back to it and check the latest status there."
        return """
        <!doctype html>
        <html lang=\"en\">
        <head>
          <meta charset=\"utf-8\">
          <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
          <title>\(title)</title>
          <style>
            :root { color-scheme: light dark; }
            body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 0; background: #f5f5f7; color: #111827; }
            .wrap { max-width: 560px; margin: 48px auto; padding: 24px; }
            .card { background: rgba(255,255,255,0.92); border-radius: 16px; padding: 24px; box-shadow: 0 10px 30px rgba(0,0,0,0.08); }
            .badge { display: inline-block; padding: 6px 10px; border-radius: 999px; background: \(accent); color: white; font-size: 12px; font-weight: 600; letter-spacing: 0.02em; }
            h1 { margin: 14px 0 8px; font-size: 28px; }
            p { margin: 0 0 12px; line-height: 1.5; color: #374151; }
            .hint { font-size: 14px; color: #6b7280; }
            .button { display: inline-block; margin: 8px 0 14px; padding: 11px 16px; border-radius: 10px; background: \(accent); color: white; font-weight: 600; text-decoration: none; }
            .button:hover { opacity: 0.92; }
            @media (prefers-color-scheme: dark) {
              body { background: #111827; color: #f9fafb; }
              .card { background: rgba(31,41,55,0.92); box-shadow: none; }
              p { color: #d1d5db; }
              .hint { color: #9ca3af; }
            }
          </style>
        </head>
        <body>
          <div class=\"wrap\">
            <div class=\"card\">
              <div class=\"badge\">\(success ? "Success" : "Error")</div>
              <h1>\(title)</h1>
              <p>\(message)</p>
              \(returnButton)
              <p class=\"hint\">\(hint)</p>
            </div>
          </div>
        </body>
        </html>
        """
    }

    @MainActor
    private func finish(with result: Result<URL, Error>, keepListenerAlive: Bool = false) {
        guard let continuation else { return }
        self.continuation = nil
        if keepListenerAlive == false {
            stop()
        } else {
            timeoutTask?.cancel()
            timeoutTask = nil
        }
        switch result {
        case .success(let url): continuation.resume(returning: url)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }
}
