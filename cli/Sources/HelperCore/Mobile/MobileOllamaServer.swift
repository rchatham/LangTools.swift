import Foundation
import Network
import HelperLink

/// Separate TLS-only mobile server. No desktop token or login/logout/admin router is exposed.
public final class MobileOllamaServer: @unchecked Sendable {
    public static let defaultPort: UInt16 = 8086
    public static let maximumConnections = 8
    public static let maximumNDJSONLineBytes = 1_048_576
    public static let maximumJSONBytes = 16 * 1_048_576
    public static let maximumStreamBytes = 256 * 1_048_576
    public static let sendTimeout: Duration = .seconds(15)
    public static let relayLifetime: Duration = .seconds(300)
    private let host: String
    private let port: UInt16
    private let identity: MobileTLSIdentity
    private let devices: MobileDeviceStore
    private let upstream: URL
    private let accountRoutes: AccountRouteHandlers
    private let configurationLock = NSLock()
    private var configuredCapabilities: [String] = ["ollama"]
    private var configuredClaudeURL: URL?
    private var started = false
    private let relayLifetime: Duration
    private let sendTimeout: Duration
    private let responseByteLimits: ResponseByteLimits

    /// Internal injection keeps boundary tests on the real relay loop without allocating production-sized bodies.
    struct ResponseByteLimits: Sendable {
        let jsonBytes: Int
        let streamBytes: Int
        static let production = ResponseByteLimits(jsonBytes: MobileOllamaServer.maximumJSONBytes,
                                                  streamBytes: MobileOllamaServer.maximumStreamBytes)
    }

    var activeConnectionCount: Int { limiter.activeCount }
    private let onReady: @Sendable (UInt16) -> Void
    private let queue = DispatchQueue(label: "LangToolsHelper.MobileTLS")
    private let sessions = MobileSessions()
    private let limiter = HelperConnectionLimiter(limit: maximumConnections)

    public convenience init(host: String, port: UInt16 = MobileOllamaServer.defaultPort, identity: MobileTLSIdentity,
                            devices: MobileDeviceStore, onReady: @escaping @Sendable (UInt16) -> Void = { _ in }) {
        self.init(host: host, port: port, identity: identity, devices: devices,
                  upstream: URL(string: "http://127.0.0.1:11434")!, onReady: onReady)
    }

    /// Injection is internal and only used by tests; mobile requests cannot choose an upstream.
    init(host: String, port: UInt16, identity: MobileTLSIdentity, devices: MobileDeviceStore,
         upstream: URL, relayLifetime: Duration = MobileOllamaServer.relayLifetime,
         sendTimeout: Duration = MobileOllamaServer.sendTimeout,
         responseByteLimits: ResponseByteLimits = .production,
         accountRoutes: AccountRouteHandlers = AccountRouteHandlers(),
         onReady: @escaping @Sendable (UInt16) -> Void) {
        self.host = host; self.port = port; self.identity = identity; self.devices = devices
        self.upstream = upstream; self.onReady = onReady; self.accountRoutes = accountRoutes
        self.relayLifetime = relayLifetime; self.sendTimeout = sendTimeout
        self.responseByteLimits = responseByteLimits
    }

    /// Explicit Mac opt-in. Configuration is immutable once listening; changing it requires a drained restart.
    public func configure(capabilities: [String], claudeBackendURL: URL? = nil) async throws {
        guard MobileHelperCapabilities.isValid(capabilities),
              !capabilities.contains("claude") || claudeBackendURL != nil else { throw MobileHelperError.upstreamRejected }
        if let claudeBackendURL { _ = try MobileClaudeRelay.validatedOrigin(claudeBackendURL) }
        try configurationLock.withLock {
            guard !started else { throw MobileHelperError.upstreamRejected }
            configuredCapabilities = capabilities
            configuredClaudeURL = claudeBackendURL
        }
        try await devices.setPairingCapabilities(capabilities)
    }

    private var capabilities: [String] { configurationLock.withLock { configuredCapabilities } }
    private var claudeBackendURL: URL? { configurationLock.withLock { configuredClaudeURL } }

    public func run() async throws {
        configurationLock.withLock { started = true }
        try await devices.setPairingCapabilities(capabilities)
        guard MobileLANInterface.available().contains(where: { $0.address == host }),
              upstream.scheme == "http", upstream.host == "127.0.0.1", upstream.user == nil,
              upstream.password == nil, upstream.query == nil, upstream.fragment == nil, upstream.path.isEmpty,
              devices.helperID == identity.helperID else { throw MobileHelperError.invalidInterface }
        let parameters = NWParameters(tls: try identity.tlsOptions(), tcp: NWProtocolTCP.Options())
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        let events = AsyncThrowingStream<Void, Error> { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard let actualPort = listener.port?.rawValue else {
                        continuation.finish(throwing: MobileHelperError.invalidInterface); return
                    }
                    self.onReady(actualPort)
                    continuation.yield(())
                case .failed(let error): continuation.finish(throwing: error)
                case .cancelled: continuation.finish()
                default: break
                }
            }
            listener.newConnectionHandler = { connection in
                self.accept(connection, actualPort: listener.port?.rawValue ?? self.port)
            }
            listener.start(queue: self.queue)
        }
        do {
            try await withTaskCancellationHandler {
                for try await _ in events { try Task.checkCancellation() }
            } onCancel: {
                listener.cancel()
                self.sessions.cancelAll()
            }
        } catch {
            listener.cancel()
            sessions.cancelAll()
            await sessions.drain()
            listener.stateUpdateHandler = nil
            listener.newConnectionHandler = nil
            throw error
        }
        listener.cancel()
        sessions.cancelAll()
        await sessions.drain()
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
    }

    public func revokeDevice(_ id: String) async throws {
        try await devices.revoke(id)
        sessions.cancel(deviceID: id)
    }

    static func allowedMethod(for path: String) -> String? {
        if LocalHelperServer.conversationID(fromCleanupPath: path) != nil { return "DELETE" }
        switch path {
        case "/v1/mobile/health", "/v1/ollama/api/version", "/v1/ollama/api/tags", "/v1/ollama/api/ps",
             "/v1/models/codex", "/v1/account/status", "/v1/claude/models": return "GET"
        case "/v1/mobile/pair", "/v1/ollama/api/chat", "/v1/ollama/api/generate", "/v1/ollama/api/pull",
             "/v1/account/chat/completions", "/v1/claude/chat/completions": return "POST"
        default: return nil
        }
    }

    private func accept(_ connection: NWConnection, actualPort: UInt16) {
        guard let lease = limiter.acquire() else { connection.cancel(); return }
        let session = MobileConnection(connection: connection, lease: lease, sendTimeout: sendTimeout)
        guard sessions.register(session) else { session.cancel(); return }
        connection.stateUpdateHandler = { state in
            switch state { case .failed, .cancelled: session.cancel(); default: break }
        }
        connection.start(queue: queue)
        session.start { [self] in
            defer { sessions.remove(session.id) }
            await serve(session, authority: "\(host):\(actualPort)")
        }
    }

    private func serve(_ session: MobileConnection, authority: String) async {
        var sentHeaders = false
        let lifetime = Task {
            do { try await Task.sleep(for: relayLifetime); session.cancel() }
            catch { /* The route completed or was cancelled. */ }
        }
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(10)); session.cancel() }
            catch { /* The read completed or connection ended. */ }
        }
        defer { deadline.cancel(); lifetime.cancel(); session.finish() }
        do {
            var accumulated = Data()
            let request: HTTPRequest
            while true {
                let part = try await session.receive(maximum: 64 * 1024)
                accumulated.append(part)
                switch MobileHTTPParser.parse(accumulated, authority: authority) {
                case .incomplete: continue
                case .failure(let status, let message):
                    try await session.send(HTTPResponseEncoder.fixed(status: status, body: Self.errorBody(message)))
                    return
                case .request(let parsed): request = parsed
                }
                break
            }
            deadline.cancel()
            // Detect downstream EOF/disconnect (or pipelined data) even while the upstream is quiet.
            session.monitorDisconnect()
            guard let method = Self.allowedMethod(for: request.path) else {
                try await session.send(HTTPResponseEncoder.fixed(status: .notFound, body: Self.errorBody("Not found."))); return
            }
            guard request.method == method else {
                try await session.send(HTTPResponseEncoder.fixed(status: .methodNotAllowed, body: Self.errorBody("Method not allowed."))); return
            }
            if request.path == "/v1/mobile/pair" {
                guard request.body.count <= 2048 else {
                    try await session.send(HTTPResponseEncoder.fixed(status: .payloadTooLarge, body: Self.errorBody("Pairing request too large."))); return
                }
                let payload = try JSONDecoder().decode(MobileHelperPairingRequest.self, from: request.body)
                try payload.validate()
                let response = try await devices.redeem(payload, capabilities: capabilities)
                try await session.send(HTTPResponseEncoder.fixed(status: .ok, body: String(decoding: JSONEncoder().encode(response), as: UTF8.self)))
                return
            }
            let capability = Self.requiredCapability(for: request.path)
            guard let device = await authorizedDevice(request.authorizationBearerToken, capability: capability) else {
                try await session.send(HTTPResponseEncoder.fixed(status: .unauthorized, body: Self.errorBody("Unauthorized or revoked device."))); return
            }
            session.setDeviceID(device.id)
            // Close the authentication/revocation race before upstream work starts.
            guard await authorizedDevice(request.authorizationBearerToken, capability: capability) != nil else { throw MobileHelperError.invalidPairing }
            if request.path == "/v1/mobile/health" {
                let effective = capabilities.filter { device.capabilities.contains($0) }
                let response = MobileHelperHealthResponse(helperID: identity.helperID, capabilities: effective)
                try await session.send(HTTPResponseEncoder.fixed(status: .ok, body: String(decoding: JSONEncoder().encode(response), as: UTF8.self)))
                return
            }
            if capability == "codex" {
                let writer = MobileAccountWriter(session: session, devices: devices, token: request.authorizationBearerToken,
                    limits: responseByteLimits)
                if request.path == "/v1/models/codex" {
                    try await writer.fixed(try await accountRoutes.models())
                } else if request.path == "/v1/account/status" {
                    try await writer.fixed(try await accountRoutes.status())
                } else if let id = LocalHelperServer.conversationID(fromCleanupPath: request.path) {
                    await accountRoutes.endConversation(Self.scopedConversation(id, deviceID: device.id))
                    try await writer.noContent()
                } else {
                    let payload = try AccountRouteHandlers.decodeChat(request.body)
                    let conversationID = payload.conversationID.map { Self.scopedConversation($0, deviceID: device.id) }
                    if payload.stream {
                        try await writer.begin()
                        sentHeaders = true
                        try await accountRoutes.streamEvents(payload, conversationID: conversationID, sanitizeErrors: true) {
                            try await writer.event($0)
                        }
                        try await writer.end()
                    } else {
                        try await writer.fixed(try await accountRoutes.chat(payload, conversationID: conversationID))
                    }
                }
                return
            }
            let isClaude = capability == "claude"
            var upstreamRequest: URLRequest
            if isClaude {
                guard let origin = claudeBackendURL else { throw MobileHelperError.upstreamRejected }
                // No issued device credential can be smuggled through the account-token channel.
                guard await devices.authenticate(request.headers["x-langtools-account-token"]) == nil else {
                    throw MobileHelperError.invalidPairing
                }
                upstreamRequest = try MobileClaudeRelay.request(request, origin: origin)
            } else {
                upstreamRequest = URLRequest(url: upstream.appendingPathComponent(String(request.path.dropFirst("/v1/ollama/".count))))
                upstreamRequest.httpMethod = request.method
                upstreamRequest.httpBody = request.method == "POST" ? request.body : nil
            }
            upstreamRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            upstreamRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            upstreamRequest.timeoutInterval = 120
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForResource = 300
            configuration.httpMaximumConnectionsPerHost = Self.maximumConnections
            configuration.connectionProxyDictionary = [:]
            configuration.urlCache = nil
            configuration.urlCredentialStorage = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            let delegate = NoMobileRedirects()
            let client = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            session.setUpstreamClient(client)
            defer { client.invalidateAndCancel() }
            // Authorization and all incoming hop-by-hop headers deliberately stay on the LAN side.
            let (bytes, response) = try await client.bytes(for: upstreamRequest, delegate: delegate)
            guard let http = response as? HTTPURLResponse, !(300...399).contains(http.statusCode),
                  (http.value(forHTTPHeaderField: "Content-Encoding") ?? "identity").lowercased() == "identity"
            else { throw MobileHelperError.upstreamRejected }
            // External errors may echo either credential. Never relay their bodies or headers.
            guard !isClaude || (200...299).contains(http.statusCode) else { throw MobileHelperError.upstreamRejected }
            let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "application/json").lowercased()
            let ndjson = contentType.contains("ndjson") || contentType.contains("jsonl")
            guard !isClaude || contentType.contains("json") else { throw MobileHelperError.upstreamRejected }
            let limit = ndjson ? responseByteLimits.streamBytes : responseByteLimits.jsonBytes
            let header = "HTTP/1.1 \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))\r\nContent-Type: \(ndjson ? "application/x-ndjson" : "application/json")\r\nCache-Control: no-store\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
            if isClaude {
                // Claude's external error events may include echoed credentials even with HTTP 200.
                // Buffer at most one bounded line (or one bounded non-stream JSON body) for validation,
                // while still awaiting every downstream send for backpressure.
                var buffer = Data()
                var total = 0
                var outputBytes = 0
                var terminalEvent = false
                if ndjson {
                    try await session.send(Data(header.utf8))
                    sentHeaders = true
                }
                for try await byte in bytes {
                    try Task.checkCancellation()
                    total += 1
                    guard total <= limit else { throw MobileHelperError.responseTooLarge }
                    buffer.append(byte)
                    if ndjson {
                        guard buffer.count <= Self.maximumNDJSONLineBytes + 1 else { throw MobileHelperError.responseTooLarge }
                        if byte == 10 {
                            guard !terminalEvent else { throw MobileHelperError.upstreamRejected }
                            let data = try MobileClaudeRelay.sanitizedJSON(Data(buffer.dropLast()),
                                accountToken: request.headers["x-langtools-account-token"], deviceToken: request.authorizationBearerToken, event: true)
                            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                            terminalEvent = ["error", "complete"].contains(object?["type"] as? String ?? "")
                            var line = data
                            line.append(10)
                            outputBytes += line.count
                            guard outputBytes <= limit else { throw MobileHelperError.responseTooLarge }
                            guard await authorizedDevice(request.authorizationBearerToken, capability: capability) != nil else { throw MobileHelperError.invalidPairing }
                            try await session.send(HTTPResponseEncoder.chunk(line))
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                }
                guard await authorizedDevice(request.authorizationBearerToken, capability: capability) != nil else { throw MobileHelperError.invalidPairing }
                if ndjson {
                    // Do not invent a newline or complete event for an interrupted external stream.
                    guard buffer.isEmpty else { throw MobileHelperError.upstreamRejected }
                } else {
                    let data = try MobileClaudeRelay.sanitizedJSON(buffer,
                        accountToken: request.headers["x-langtools-account-token"], deviceToken: request.authorizationBearerToken, event: false)
                    try await session.send(Data(header.utf8))
                    sentHeaders = true
                    if !data.isEmpty { try await session.send(HTTPResponseEncoder.chunk(data)) }
                }
                try await session.send(HTTPResponseEncoder.terminalChunk)
                return
            }
            try await session.send(Data(header.utf8))
            sentHeaders = true
            var buffer = Data()
            var total = 0
            var lineBytes = 0
            for try await byte in bytes {
                try Task.checkCancellation()
                total += 1
                lineBytes = byte == 10 ? 0 : lineBytes + 1
                guard total <= limit, !ndjson || lineBytes <= Self.maximumNDJSONLineBytes else { throw MobileHelperError.responseTooLarge }
                buffer.append(byte)
                if buffer.count >= 4096 || (ndjson && byte == 10) {
                    guard await authorizedDevice(request.authorizationBearerToken, capability: capability) != nil else { throw MobileHelperError.invalidPairing }
                    try await session.send(HTTPResponseEncoder.chunk(buffer))
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            guard await authorizedDevice(request.authorizationBearerToken, capability: capability) != nil else { throw MobileHelperError.invalidPairing }
            if !buffer.isEmpty { try await session.send(HTTPResponseEncoder.chunk(buffer)) }
            try await session.send(HTTPResponseEncoder.terminalChunk)
        } catch {
            // Before headers: explicit HTTP error. After headers: abort, never manufacture successful NDJSON completion.
            if !sentHeaders, !Task.isCancelled {
                let status: HTTPStatus
                if error is DecodingError || error is MobileHelperLinkError { status = .badRequest }
                else if case MobileHelperError.invalidPairing = error { status = .unauthorized }
                else if error is CodexRuntimeError || error is CodexAppServerError { status = LocalHelperServer.httpStatus(for: error) }
                else { status = .serviceUnavailable }
                do { try await session.send(HTTPResponseEncoder.fixed(status: status, body: Self.errorBody("The helper could not complete this request."))) }
                catch { /* The disconnected peer cannot receive an error response. */ }
            }
        }
    }

    private static func requiredCapability(for path: String) -> String? {
        if path.hasPrefix("/v1/ollama/") { return "ollama" }
        if path.hasPrefix("/v1/claude/") { return "claude" }
        if path == "/v1/models/codex" || path.hasPrefix("/v1/account/") { return "codex" }
        return nil
    }

    private func authorizedDevice(_ token: String?, capability: String?) async -> MobileDevice? {
        guard let device = await devices.authenticate(token) else { return nil }
        if let capability {
            guard capabilities.contains(capability), device.capabilities.contains(capability) else { return nil }
        } else {
            guard capabilities.contains(where: { device.capabilities.contains($0) }) else { return nil }
        }
        return device
    }

    /// Prevent a device-selected UUID from targeting another phone's or the desktop's workspace.
    private static func scopedConversation(_ id: UUID, deviceID: String) -> UUID {
        let hex = digest(Data(("mobile-codex/" + deviceID + "/" + id.uuidString).utf8))
        let bytes = Array(hex.prefix(32))
        let value = String(bytes[0..<8]) + "-" + String(bytes[8..<12]) + "-" + String(bytes[12..<16])
            + "-" + String(bytes[16..<20]) + "-" + String(bytes[20..<32])
        return UUID(uuidString: value)!
    }

    private static func errorBody(_ message: String) -> String {
        // Messages are fixed server strings; never include tokens, raw QR codes or upstream bodies.
        String(decoding: (try? JSONEncoder().encode(["error": message])) ?? Data("{}".utf8), as: UTF8.self)
    }
}

/// Reuse only the bounded structural HTTP parser, not the desktop router or its auth logic.
/// Normalize Host after checking the exact numeric LAN authority; desktop's parser stays unchanged.
enum MobileHTTPParser {
    static func parse(_ data: Data, authority: String) -> HTTPRequestParseResult {
        guard let range = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > 32 * 1024 ? .failure(.requestHeaderFieldsTooLarge, "Headers too large.") : .incomplete
        }
        guard range.upperBound <= 32 * 1024, let text = String(data: data[..<range.lowerBound], encoding: .utf8) else {
            return .failure(.badRequest, "Malformed headers.")
        }
        var lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first, let target = first.split(separator: " ").dropFirst().first,
              !target.contains("?"), !target.contains("%") else { return .failure(.badRequest, "Only exact route paths are supported.") }
        let hostIndices = lines.indices.filter { lines[$0].lowercased().hasPrefix("host:") }
        guard hostIndices.count == 1, let index = hostIndices.first,
              String(lines[index].dropFirst(5)).trimmingCharacters(in: .whitespaces) == authority else {
            return .failure(.badRequest, "Unexpected Host header.")
        }
        lines[index] = "Host: localhost"
        let normalized = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8) + data[range.upperBound...]
        return HTTPRequest.parse(from: normalized)
    }
}

/// One bounded send at a time. Device revocation is checked before headers, every event, and EOF.
private actor MobileAccountWriter {
    let session: MobileConnection
    let devices: MobileDeviceStore
    let token: String?
    let limits: MobileOllamaServer.ResponseByteLimits
    private var totalBytes = 0
    init(session: MobileConnection, devices: MobileDeviceStore, token: String?, limits: MobileOllamaServer.ResponseByteLimits) {
        self.session = session; self.devices = devices; self.token = token; self.limits = limits
    }
    private func authorize() async throws {
        try Task.checkCancellation()
        guard let device = await devices.authenticate(token), device.capabilities.contains("codex") else {
            throw MobileHelperError.invalidPairing
        }
    }
    func fixed<T: Encodable>(_ value: T) async throws {
        let data = try HTTPResponseEncoder.makeJSONEncoder().encode(value)
        guard data.count <= limits.jsonBytes else { throw MobileHelperError.responseTooLarge }
        try await authorize()
        try await session.send(HTTPResponseEncoder.fixed(status: .ok, body: String(decoding: data, as: UTF8.self)))
    }
    func noContent() async throws {
        try await authorize()
        try await session.send(HTTPResponseEncoder.fixed(status: .noContent, body: ""))
    }
    func begin() async throws {
        try await authorize()
        try await session.send(HTTPResponseEncoder.chunkedHeader(status: .ok))
    }
    func event(_ event: HelperChatStreamEvent) async throws {
        var data = try HTTPResponseEncoder.makeJSONEncoder().encode(event)
        guard data.count <= MobileOllamaServer.maximumNDJSONLineBytes else { throw MobileHelperError.responseTooLarge }
        data.append(10)
        totalBytes += data.count
        guard totalBytes <= limits.streamBytes else { throw MobileHelperError.responseTooLarge }
        try await authorize()
        try await session.send(HTTPResponseEncoder.chunk(data))
    }
    func end() async throws {
        try await authorize()
        try await session.send(HTTPResponseEncoder.terminalChunk)
    }
}

private final class NoMobileRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

private final class MobileSessions: @unchecked Sendable {
    private let lock = NSLock()
    private var accepting = true
    private var values: [UUID: MobileConnection] = [:]
    func register(_ value: MobileConnection) -> Bool {
        lock.withLock { guard accepting else { return false }; values[value.id] = value; return true }
    }
    func remove(_ id: UUID) { _ = lock.withLock { values.removeValue(forKey: id) } }
    func cancelAll() {
        let snapshot = lock.withLock { accepting = false; return Array(values.values) }
        snapshot.forEach { $0.cancel() }
    }
    func cancel(deviceID: String) {
        let snapshot = lock.withLock { Array(values.values) }
        snapshot.filter { $0.deviceID == deviceID }.forEach { $0.cancel() }
    }
    func drain() async {
        while lock.withLock({ !values.isEmpty }) {
            do { try await Task.sleep(for: .milliseconds(20)) }
            catch { await Task.yield() }
        }
    }
}

private final class MobileConnection: @unchecked Sendable {
    let id = UUID()
    let connection: NWConnection
    private let lease: HelperConnectionLease
    private let sendTimeout: Duration
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var ended = false
    private var storedDeviceID: String?
    private var upstreamClient: URLSession?
    var deviceID: String? { lock.withLock { storedDeviceID } }
    init(connection: NWConnection, lease: HelperConnectionLease, sendTimeout: Duration) {
        self.connection = connection; self.lease = lease; self.sendTimeout = sendTimeout
    }
    func setDeviceID(_ id: String) { lock.withLock { storedDeviceID = id } }
    func start(_ operation: @escaping @Sendable () async -> Void) {
        lock.withLock {
            task = Task { await operation(); self.finish() }
            if ended { task?.cancel() }
        }
    }
    func setUpstreamClient(_ client: URLSession) {
        let shouldCancel = lock.withLock { upstreamClient = client; return ended }
        if shouldCancel { client.invalidateAndCancel() }
    }
    private var isEnded: Bool { lock.withLock { ended } }
    func cancel() {
        let snapshot = lock.withLock { ended = true; return (task, upstreamClient) }
        snapshot.0?.cancel(); snapshot.1?.invalidateAndCancel(); connection.cancel()
        // A rejected/not-yet-started connection owns no route work. Running routes keep their
        // slot until finish(), after shared account handlers have joined producer cleanup.
        if snapshot.0 == nil { lease.release() }
    }
    func finish() {
        let client = lock.withLock { ended = true; task = nil; defer { upstreamClient = nil }; return upstreamClient }
        client?.invalidateAndCancel(); connection.stateUpdateHandler = nil; connection.cancel(); lease.release()
    }
    func receive(maximum: Int) async throws -> Data {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, complete, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else { continuation.resume(throwing: complete ? URLError(.networkConnectionLost) : URLError(.badServerResponse)) }
            }
        }
    }
    func monitorDisconnect() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, _, _ in self?.cancel() }
    }
    func send(_ data: Data) async throws {
        try Task.checkCancellation()
        guard !isEnded else { throw CancellationError() }
        let deadline = Task {
            do { try await Task.sleep(for: sendTimeout); self.cancel() }
            catch { /* This send completed before its deadline. */ }
        }
        defer { deadline.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
        try Task.checkCancellation()
    }
}
