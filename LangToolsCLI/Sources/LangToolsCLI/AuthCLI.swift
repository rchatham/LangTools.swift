import Foundation
import Network
#if canImport(CryptoKit)
import CryptoKit
#endif
#if os(macOS)
import AppKit
#endif

struct AuthCLI {
    static func run(arguments: [String]) async throws {
        let command = try AuthSubcommand(arguments: arguments)
        switch command {
        case .login(let provider):
            try await AuthCommands().login(provider: provider)
        case .exportSession(let provider, let format):
            try AuthCommands().exportSession(provider: provider, format: format)
        case .status(let provider, let format):
            try AuthCommands().status(provider: provider, format: format)
        case .logout(let provider):
            try AuthCommands().logout(provider: provider)
        }
    }

    static let usage = """
    Usage:
      LangToolsCLI auth login openai
      LangToolsCLI auth export-session openai --format json
      LangToolsCLI auth status openai --format json
      LangToolsCLI auth logout openai
    """
}

private enum AuthSubcommand {
    case login(Provider)
    case exportSession(Provider, OutputFormat)
    case status(Provider, OutputFormat)
    case logout(Provider)

    init(arguments: [String]) throws {
        guard let command = arguments.first else {
            throw CLIError.usage(AuthCLI.usage)
        }
        let remaining = Array(arguments.dropFirst())
        switch command {
        case "login":
            self = .login(try Provider(arguments: remaining))
        case "export-session":
            self = .exportSession(try Provider(arguments: remaining), try OutputFormat(arguments: remaining))
        case "status":
            self = .status(try Provider(arguments: remaining), try OutputFormat(arguments: remaining))
        case "logout":
            self = .logout(try Provider(arguments: remaining))
        default:
            throw CLIError.usage(AuthCLI.usage)
        }
    }
}

private enum Provider: String {
    case openai

    init(arguments: [String]) throws {
        guard let first = arguments.first, let provider = Provider(rawValue: first.lowercased()) else {
            throw CLIError.usage(AuthCLI.usage)
        }
        self = provider
    }
}

private enum OutputFormat: String {
    case json

    init(arguments: [String]) throws {
        if let index = arguments.firstIndex(of: "--format"), arguments.indices.contains(index + 1), let format = OutputFormat(rawValue: arguments[index + 1].lowercased()) {
            self = format
            return
        }
        self = .json
    }
}

private enum CLIError: LocalizedError {
    case usage(String)
    case unsupportedProvider
    case missingSession
    case invalidCallback
    case missingAuthorizationCode
    case stateMismatch
    case callbackError(String)
    case browserOpenFailed
    case listenerFailed(String?)
    case tokenExchangeFailed(String)

    var errorDescription: String? {
        switch self {
        case .usage(let text): return text
        case .unsupportedProvider: return "Only 'openai' is currently supported."
        case .missingSession: return "No stored OpenAI session was found."
        case .invalidCallback: return "Invalid OAuth callback URL."
        case .missingAuthorizationCode: return "OAuth callback was missing an authorization code."
        case .stateMismatch: return "OAuth callback state mismatch."
        case .callbackError(let message): return message
        case .browserOpenFailed: return "Unable to open the browser for OpenAI login."
        case .listenerFailed(let details):
            let base = "Unable to start the localhost OAuth callback listener on localhost:1455. Another app or an older LangTools helper may still be using that port. Quit the other app or stop the old helper, then try again."
            guard let details, details.isEmpty == false else { return base }
            return "\(base)\n\n\(details)"
        case .tokenExchangeFailed(let message): return message
        }
    }
}

private struct StoredAccountSession: Codable {
    let provider: String
    let accountIdentifier: String
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let tokenType: String?
    let expiresAt: Date?
    let accessibleModelIDs: [String]
    let createdAt: Date
    let id: UUID
}

private struct AuthCommands {
    private let store = SessionStore()
    private let auth = OpenAICLIAuthFlow()

    func login(provider: Provider) async throws {
        guard provider == .openai else { throw CLIError.unsupportedProvider }
        let session = try await auth.login()
        try store.save(session)
        print("Logged in to OpenAI as \(session.accountIdentifier)")
    }

    func exportSession(provider: Provider, format: OutputFormat) throws {
        guard provider == .openai else { throw CLIError.unsupportedProvider }
        let session = try store.load()
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(session)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }

    func status(provider: Provider, format: OutputFormat) throws {
        guard provider == .openai else { throw CLIError.unsupportedProvider }
        let session = try? store.load()
        switch format {
        case .json:
            let payload: [String: Any] = [
                "provider": provider.rawValue,
                "authenticated": session != nil,
                "accountIdentifier": session?.accountIdentifier as Any,
                "expiresAt": session?.expiresAt?.ISO8601Format() as Any
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }

    func logout(provider: Provider) throws {
        guard provider == .openai else { throw CLIError.unsupportedProvider }
        try store.remove()
        print("Logged out of OpenAI")
    }
}

private struct SessionStore {
    private let fileURL: URL

    init() {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".langtools", isDirectory: true)
            .appendingPathComponent("auth", isDirectory: true)
        self.fileURL = base.appendingPathComponent("openai-session.json")
    }

    func save(_ session: StoredAccountSession) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(session)
        try data.write(to: fileURL)
    }

    func load() throws -> StoredAccountSession {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw CLIError.missingSession
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(StoredAccountSession.self, from: Data(contentsOf: fileURL))
    }

    func remove() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}

private struct OpenAICLIAuthFlow {
    private let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private let authorizeURL = URL(string: "https://auth.openai.com/oauth/authorize")!
    private let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    private let logger = AuthDebugLogger.shared

    func login() async throws -> StoredAccountSession {
        let listener = LocalCallbackListener(port: 1455)
        let redirectURL = try await listener.start()
        logger.log("listener started redirectURL=\(redirectURL.absoluteString)")
        defer {
            logger.log("listener stopping")
            listener.stop()
        }

        let pkce = PKCEChallenge()
        let state = randomHex(bytes: 16)
        let authURL = makeAuthorizeURL(state: state, redirectURI: redirectURL.absoluteString, codeChallenge: pkce.codeChallenge)
        logger.log("opening browser authURL=\(authURL.absoluteString)")
        try openBrowser(url: authURL)
        let callback = try await listener.waitForCallback()
        logger.log("received callback url=\(callback.absoluteString)")
        let payload = try parseCallback(callback, expectedState: state)
        logger.log("parsed callback successfully state matched")
        let token = try await exchangeCode(code: payload.code, codeVerifier: pkce.codeVerifier, redirectURI: redirectURL.absoluteString)
        logger.log("token exchange succeeded")
        return token.toStoredSession()
    }

    private func makeAuthorizeURL(state: String, redirectURI: String, codeChallenge: String) -> URL {
        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: "openid profile email offline_access"),
            .init(name: "code_challenge", value: codeChallenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "originator", value: "opencode"),
            .init(name: "id_token_add_organizations", value: "true"),
            .init(name: "codex_cli_simplified_flow", value: "true")
        ]
        return components.url!
    }

    private func parseCallback(_ url: URL, expectedState: String) throws -> (code: String, state: String) {
        guard url.path == "/auth/callback" else { throw CLIError.invalidCallback }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let error = components?.queryItems?.first(where: { $0.name == "error" })?.value {
            let description = components?.queryItems?.first(where: { $0.name == "error_description" })?.value
            throw CLIError.callbackError(description ?? error)
        }
        guard let state = components?.queryItems?.first(where: { $0.name == "state" })?.value, state == expectedState else {
            throw CLIError.stateMismatch
        }
        guard let code = components?.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw CLIError.missingAuthorizationCode
        }
        return (code, state)
    }

    private func exchangeCode(code: String, codeVerifier: String, redirectURI: String) async throws -> TokenResponse {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = URLComponents.formEncoded([
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "code_verifier": codeVerifier,
            "redirect_uri": redirectURI
        ])
        request.httpBody = Data(body.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CLIError.tokenExchangeFailed("Invalid token response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Token exchange failed with status \(http.statusCode)"
            throw CLIError.tokenExchangeFailed(message)
        }
        let decoder = JSONDecoder()
        return try decoder.decode(TokenResponse.self, from: data)
    }

    private func randomHex(bytes: Int) -> String {
        Data((0..<bytes).map { _ in UInt8.random(in: 0...255) }).map { String(format: "%02x", $0) }.joined()
    }

    private func openBrowser(url: URL) throws {
        #if os(macOS)
        guard NSWorkspace.shared.open(url) else {
            throw CLIError.browserOpenFailed
        }
        #else
        throw CLIError.browserOpenFailed
        #endif
    }
}

private struct TokenResponse: Codable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let tokenType: String?
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
    }

    func toStoredSession(now: Date = Date()) -> StoredAccountSession {
        StoredAccountSession(
            provider: "openAI",
            accountIdentifier: jwtAccountIdentifier(from: accessToken) ?? "OpenAI Account",
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            tokenType: tokenType,
            expiresAt: expiresIn.map { now.addingTimeInterval(TimeInterval($0)) },
            accessibleModelIDs: [],
            createdAt: now,
            id: UUID()
        )
    }

    private func jwtAccountIdentifier(from token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = object["https://api.openai.com/auth"] as? [String: Any],
              let accountID = auth["chatgpt_account_id"] as? String else {
            return nil
        }
        return accountID
    }
}

private final class LocalCallbackListener {
    private let port: UInt16
    private let host: String
    private let path: String
    private let queue = DispatchQueue(label: "LangToolsAuthCLI.LocalCallbackListener")
    private let logger = AuthDebugLogger.shared
    private var listener: NWListener?
    private var continuation: CheckedContinuation<URL, Error>?
    private var startContinuation: CheckedContinuation<URL, Error>?
    private var hasStarted = false
    private var completedURL: URL?
    private var finishWorkItem: DispatchWorkItem?

    init(port: UInt16, host: String = "localhost", path: String = "/auth/callback") {
        self.port = port
        self.host = host
        self.path = path
    }

    func start() async throws -> URL {
        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            logger.log("listener failed to bind port=\(port) error=\(error)")
            throw CLIError.listenerFailed(Self.listenerConflictDetails(for: port))
        }

        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.logger.log("listener port=\(port) state=\(String(describing: state))")
            switch state {
            case .ready:
                guard self.hasStarted == false else { return }
                self.hasStarted = true
                self.finishStart(.success(self.redirectURL))
            case .failed(let error):
                self.logger.log("listener port=\(port) failed error=\(error)")
                self.finishStart(.failure(CLIError.listenerFailed(Self.listenerConflictDetails(for: port))))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.logger.log("accepted connection endpoint=\(String(describing: connection.endpoint))")
            self?.handle(connection)
        }
        listener.start(queue: queue)

        return try await withCheckedThrowingContinuation { continuation in
            self.startContinuation = continuation
        }
    }

    func waitForCallback() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func stop() {
        finishWorkItem?.cancel()
        finishWorkItem = nil
        listener?.cancel()
        listener = nil
        continuation = nil
        startContinuation = nil
        hasStarted = false
        completedURL = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else { return }
            self.logger.log("receive completed bytes=\(data?.count ?? 0)")

            if let completedURL = self.completedURL {
                self.logger.log("serving cached success page for repeat request")
                self.respond(connection: connection, status: "200 OK", body: Self.callbackHTML(title: "OpenAI sign-in complete", message: "Your OpenAI sign-in was already received. Return to LangTools Example to continue.", success: true)) {
                    connection.cancel()
                }
                _ = completedURL
                return
            }

            guard let data,
                  let text = String(data: data, encoding: .utf8),
                  let requestLine = text.split(separator: "\r\n").first,
                  let requestTarget = requestLine.split(separator: " ").dropFirst().first,
                  let url = self.callbackURL(from: String(requestTarget))
            else {
                self.logger.log("invalid callback request raw=\(String(data: data ?? Data(), encoding: .utf8) ?? "<non-utf8>")")

                self.respond(connection: connection, status: "400 Bad Request", body: Self.callbackHTML(title: "Authentication failed", message: "The callback request was invalid. You can close this tab and try again.", success: false)) {
                    connection.cancel()
                }
                return
            }

            self.logger.log("requestLine=\(requestLine) parsedURL=\(url.absoluteString)")

            guard url.path == self.path else {
                self.respond(connection: connection, status: "404 Not Found", body: Self.callbackHTML(title: "Authentication failed", message: "The callback path was not recognized. You can close this tab and return to the app.", success: false)) {
                    connection.cancel()
                }
                return
            }

            self.completedURL = url
            self.respond(connection: connection, status: "200 OK", body: Self.callbackHTML(title: "OpenAI sign-in complete", message: "Your OpenAI account is connected. Return to LangTools Example to continue.", success: true)) {
                self.logger.log("response flushed; finishing auth immediately and keeping listener alive briefly for follow-up browser requests")
                connection.cancel()
                self.scheduleListenerShutdown()
                self.finish(.success(url), keepListenerAlive: true)
            }
        }
    }

    private var redirectURL: URL {
        URL(string: "http://\(host):\(port)\(path)")!
    }

    private func callbackURL(from requestTarget: String) -> URL? {
        if let absoluteURL = URL(string: requestTarget), absoluteURL.scheme != nil {
            return absoluteURL
        }
        return URL(string: "http://\(host)\(requestTarget)")
    }

    private static func listenerConflictDetails(for port: UInt16) -> String? {
        #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.isEmpty == false else { return nil }

            let lines = text.split(separator: "\n").map(String.init)
            guard lines.count >= 2 else {
                return "Port \(port) appears to already be in use."
            }

            let occupant = lines[1]
            if occupant.localizedCaseInsensitiveContains("LangTools") || occupant.localizedCaseInsensitiveContains("LangToolsAuthCLI") {
                return "Detected another LangTools listener already using port \(port):\n\(occupant)"
            }
            return "Detected an existing listener on port \(port):\n\(occupant)"
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    private func respond(connection: NWConnection, status: String, body: String, completion: @escaping () -> Void) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { error in
            if let error {
                AuthDebugLogger.shared.log("response send failed error=\(error)")
            } else {
                AuthDebugLogger.shared.log("response send completed status=\(status)")
            }
            completion()
        })
    }

    private static func callbackHTML(title: String, message: String, success: Bool) -> String {
        let accent = success ? "#1f8f4e" : "#b42318"
        let returnURL = "langtools-example-auth://auth/return"
        let returnButton = success
            ? "<a class=\"button\" href=\"\(returnURL)\">Return to LangTools Example</a>"
            : ""
        let successHint = success
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
              <p class=\"hint\">\(successHint)</p>
            </div>
          </div>
        </body>
        </html>
        """
    }

    private func finishStart(_ result: Result<URL, Error>) {
        guard let startContinuation else { return }
        self.startContinuation = nil
        switch result {
        case .success(let url):
            startContinuation.resume(returning: url)
        case .failure(let error):
            stop()
            startContinuation.resume(throwing: error)
        }
    }

    private func scheduleListenerShutdown() {
        finishWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.stop()
        }
        finishWorkItem = workItem
        queue.asyncAfter(deadline: .now() + 15, execute: workItem)
    }

    private func finish(_ result: Result<URL, Error>, keepListenerAlive: Bool = false) {
        guard let continuation else { return }
        self.continuation = nil
        if keepListenerAlive == false {
            stop()
        }
        switch result {
        case .success(let url): continuation.resume(returning: url)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }
}

private struct PKCEChallenge {
    let codeVerifier: String
    let codeChallenge: String

    init() {
        let verifier = Self.randomURLSafeString(length: 64)
        self.codeVerifier = verifier
        self.codeChallenge = Self.sha256Base64URL(verifier)
    }

    static func randomURLSafeString(length: Int) -> String {
        let bytes = (0..<length).map { _ in UInt8.random(in: 0...255) }
        let allowed = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return String(bytes.map { allowed[Int($0) % allowed.count] })
    }

    static func sha256Base64URL(_ value: String) -> String {
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: Data(value.utf8))
        return Data(digest)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        #else
        return value
        #endif
    }
}

private final class AuthDebugLogger {
    static let shared = AuthDebugLogger()

    private let fileURL: URL
    private let queue = DispatchQueue(label: "LangToolsAuthCLI.AuthDebugLogger")
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private init() {
        let logsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("LangTools", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        self.fileURL = logsDirectory.appendingPathComponent("LangToolsAuthCLI.log")
    }

    func log(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        if let data = line.data(using: .utf8) {
            queue.async {
                if FileManager.default.fileExists(atPath: self.fileURL.path) == false {
                    FileManager.default.createFile(atPath: self.fileURL.path, contents: data)
                    return
                }
                guard let handle = try? FileHandle(forWritingTo: self.fileURL) else { return }
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        }
        fputs(line, stderr)
    }
}

private extension URLComponents {
    static func formEncoded(_ values: [String: String]) -> String {
        var components = URLComponents()
        components.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.percentEncodedQuery ?? ""
    }
}
