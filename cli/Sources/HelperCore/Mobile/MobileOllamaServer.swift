import Foundation
import Network
import HelperLink

/// Separate TLS-only mobile server. No desktop token or privileged desktop router is referenced here.
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
    private let relayLifetime: Duration
    private let sendTimeout: Duration
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
         sendTimeout: Duration = MobileOllamaServer.sendTimeout, onReady: @escaping @Sendable (UInt16) -> Void) {
        self.host = host; self.port = port; self.identity = identity; self.devices = devices
        self.upstream = upstream; self.onReady = onReady
        self.relayLifetime = relayLifetime; self.sendTimeout = sendTimeout
    }

    public func run() async throws {
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
        switch path {
        case "/v1/mobile/health", "/v1/ollama/api/version", "/v1/ollama/api/tags", "/v1/ollama/api/ps": return "GET"
        case "/v1/mobile/pair", "/v1/ollama/api/chat", "/v1/ollama/api/generate", "/v1/ollama/api/pull": return "POST"
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
                let response = try await devices.redeem(payload)
                try await session.send(HTTPResponseEncoder.fixed(status: .ok, body: String(decoding: JSONEncoder().encode(response), as: UTF8.self)))
                return
            }
            guard let device = await devices.authenticate(request.authorizationBearerToken), device.capabilities == ["ollama"] else {
                try await session.send(HTTPResponseEncoder.fixed(status: .unauthorized, body: Self.errorBody("Unauthorized or revoked device."))); return
            }
            session.setDeviceID(device.id)
            // Close the authentication/revocation race before upstream work starts.
            guard await devices.authenticate(request.authorizationBearerToken) != nil else { throw MobileHelperError.invalidPairing }
            if request.path == "/v1/mobile/health" {
                let response = MobileHelperHealthResponse(helperID: identity.helperID)
                try await session.send(HTTPResponseEncoder.fixed(status: .ok, body: String(decoding: JSONEncoder().encode(response), as: UTF8.self)))
                return
            }
            var upstreamRequest = URLRequest(url: upstream.appendingPathComponent(String(request.path.dropFirst("/v1/ollama/".count))))
            upstreamRequest.httpMethod = request.method
            upstreamRequest.httpBody = request.method == "POST" ? request.body : nil
            upstreamRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            upstreamRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            upstreamRequest.timeoutInterval = 120
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForResource = 300
            configuration.httpMaximumConnectionsPerHost = Self.maximumConnections
            configuration.connectionProxyDictionary = [:]
            configuration.urlCache = nil
            let delegate = NoMobileRedirects()
            let client = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            session.setUpstreamClient(client)
            defer { client.invalidateAndCancel() }
            // Authorization and all incoming hop-by-hop headers deliberately stay on the LAN side.
            let (bytes, response) = try await client.bytes(for: upstreamRequest, delegate: delegate)
            guard let http = response as? HTTPURLResponse, !(300...399).contains(http.statusCode),
                  (http.value(forHTTPHeaderField: "Content-Encoding") ?? "identity").lowercased() == "identity"
            else { throw MobileHelperError.upstreamRejected }
            let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "application/json").lowercased()
            let ndjson = contentType.contains("ndjson") || contentType.contains("jsonl")
            let limit = ndjson ? Self.maximumStreamBytes : Self.maximumJSONBytes
            let header = "HTTP/1.1 \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))\r\nContent-Type: \(ndjson ? "application/x-ndjson" : "application/json")\r\nCache-Control: no-store\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
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
                    guard await devices.authenticate(request.authorizationBearerToken) != nil else { throw MobileHelperError.invalidPairing }
                    try await session.send(HTTPResponseEncoder.chunk(buffer))
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            if !buffer.isEmpty { try await session.send(HTTPResponseEncoder.chunk(buffer)) }
            try await session.send(HTTPResponseEncoder.terminalChunk)
        } catch {
            // Before headers: explicit HTTP error. After headers: abort, never manufacture successful NDJSON completion.
            if !sentHeaders, !Task.isCancelled {
                let status: HTTPStatus
                if error is DecodingError || error is MobileHelperLinkError { status = .badRequest }
                else if case MobileHelperError.invalidPairing = error { status = .unauthorized }
                else { status = .serviceUnavailable }
                do { try await session.send(HTTPResponseEncoder.fixed(status: status, body: Self.errorBody("The helper could not complete this request."))) }
                catch { /* The disconnected peer cannot receive an error response. */ }
            }
        }
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
        snapshot.0?.cancel(); snapshot.1?.invalidateAndCancel(); connection.cancel(); lease.release()
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
