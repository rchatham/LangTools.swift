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
        let accent = success ? "#0D0D0D" : "#b42318"
        let titleColor = success ? "#0D0D0D" : "#b42318"
        let secondary = success ? "#5D5D5D" : "#7a271a"
        let returnURL = "langtools-example-auth://auth/return"
        let returnButton = success
            ? "<a class=\"button\" href=\"\(returnURL)\">Return to LangTools Example</a>"
            : ""
        let footer = success
            ? "You may now return to the app or close this page"
            : message
        return """
        <!doctype html>
        <html lang=\"en\">
        <head>
          <meta charset=\"utf-8\">
          <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
          <title>\(title)</title>
          <style>
            :root { color-scheme: light; }
            * { box-sizing: border-box; }
            body {
              margin: 0;
              min-height: 100vh;
              background: #ffffff;
              color: #0D0D0D;
              font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
            }
            .container {
              min-height: 100vh;
              display: flex;
              align-items: center;
              justify-content: center;
              padding: 32px;
            }
            .content {
              width: min(680px, 100%);
              display: flex;
              flex-direction: column;
              align-items: center;
              text-align: center;
              gap: 24px;
              margin-top: -10vh;
            }
            .logo {
              display: flex;
              align-items: center;
              justify-content: center;
              width: 128px;
              height: 128px;
              border-radius: 28px;
              border: 1px solid rgba(13, 13, 13, 0.10);
              box-shadow: 0 12px 32px rgba(0, 0, 0, 0.08);
              background: #ffffff;
            }
            .logo svg {
              width: 56px;
              height: 56px;
            }
            h1 {
              margin: 0;
              font-size: clamp(44px, 8vw, 64px);
              line-height: 1.05;
              font-weight: 400;
              color: \(titleColor);
              letter-spacing: -0.03em;
            }
            .message {
              margin: 0;
              font-size: 24px;
              line-height: 1.35;
              color: \(secondary);
            }
            .button {
              display: inline-flex;
              align-items: center;
              justify-content: center;
              min-height: 48px;
              padding: 12px 20px;
              border-radius: 999px;
              background: \(accent);
              color: #ffffff;
              text-decoration: none;
              font-size: 16px;
              font-weight: 510;
              line-height: 1;
            }
            .button:hover { opacity: 0.94; }
            @media (max-width: 640px) {
              .logo {
                width: 96px;
                height: 96px;
                border-radius: 22px;
              }
              .logo svg {
                width: 44px;
                height: 44px;
              }
              .message {
                font-size: 20px;
              }
            }
          </style>
        </head>
        <body>
          <div class=\"container\">
            <div class=\"content\">
              <div class=\"logo\" aria-hidden=\"true\">
                <svg xmlns=\"http://www.w3.org/2000/svg\" width=\"32\" height=\"32\" fill=\"none\" viewBox=\"0 0 32 32\"><path stroke=\"#000\" stroke-linecap=\"round\" stroke-width=\"2.484\" d=\"M22.356 19.797H17.17M9.662 12.29l1.979 3.576a.511.511 0 0 1-.005.504l-1.974 3.409M30.758 16c0 8.15-6.607 14.758-14.758 14.758-8.15 0-14.758-6.607-14.758-14.758C1.242 7.85 7.85 1.242 16 1.242c8.15 0 14.758 6.608 14.758 14.758Z\"/></svg>
              </div>
              <h1>\(title)</h1>
              <p class=\"message\">\(footer)</p>
              \(returnButton)
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
