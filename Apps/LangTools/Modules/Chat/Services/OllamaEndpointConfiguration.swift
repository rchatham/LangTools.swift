import Foundation
import Agents
import LangTools
import Ollama

/// Thread-safe, persisted source of truth for the Ollama server and its model cache.
public final class OllamaEndpointConfiguration: @unchecked Sendable {
    public struct Snapshot: Equatable, Sendable {
        public let baseURL: URL?
        public let validationError: ValidationError?
        public let revision: UInt64
        public let helperID: String?
        public let helperName: String?
        let helper: MobileHelperConnection?
        let helperError: MobileHelperError?
        let directSession: URLSession?
        public var isHelper: Bool { helperID != nil }
        var cacheScope: String? {
            guard baseURL != nil, validationError == nil, helperError == nil else { return nil }
            return helperID.map { "helper:\($0)" } ?? baseURL?.absoluteString
        }

        public static func == (lhs: Snapshot, rhs: Snapshot) -> Bool {
            lhs.baseURL == rhs.baseURL && lhs.validationError == rhs.validationError && lhs.revision == rhs.revision && lhs.helperID == rhs.helperID
        }

        public func actionableError(_ error: Error) -> Error {
            isHelper ? MobileHelperError.actionable(error, session: helper?.session) : error
        }

        /// Captures the validated destination and retains its transport lease without exposing credentials.
        public func makeToolchain() throws -> LangToolchain {
            try makeToolchain(directSession: directSession)
        }

        func makeToolchain(directSession: URLSession?) throws -> LangToolchain {
            var toolchain = LangToolchain()
            toolchain.register(CapturedOllama(provider: try provider(directSession: directSession)))
            return toolchain
        }

        public func makeAgentContext(model: Ollama.Model, messages: [Ollama.Message], eventHandler: @escaping (AgentEvent) -> Void) throws -> AgentContext {
            try makeAgentContext(model: model, messages: messages, eventHandler: eventHandler, directSession: directSession)
        }

        func makeAgentContext(model: Ollama.Model, messages: [Ollama.Message], eventHandler: @escaping (AgentEvent) -> Void, directSession: URLSession?) throws -> AgentContext {
            AgentContext(langTool: CapturedOllama(provider: try provider(directSession: directSession)), model: model, messages: messages, eventHandler: eventHandler)
        }

        func provider(directSession: URLSession?) throws -> Ollama {
            if let helperError { throw helperError }
            if let validationError { throw validationError }
            guard let baseURL else { throw MobileHelperError.disconnected }
            if let helper {
                return Ollama(baseURL: baseURL, apiKey: helper.credential.token, sessionLease: helper.sessionLease)
            }
            guard !isHelper else { throw MobileHelperError.disconnected }
            guard let directSession else { throw ValidationError.invalidURL }
            return Ollama(baseURL: baseURL, session: directSession)
        }
    }

    public enum ValidationError: LocalizedError, Equatable, Sendable {
        case empty
        case invalidURL
        case unsupportedScheme
        case missingHost
        case credentialsNotAllowed
        case queryNotAllowed
        case fragmentNotAllowed
        case pathNotAllowed
        case invalidPort
        case unsafeHTTPHost

        public var errorDescription: String? {
            switch self {
            case .empty:
                return "Enter an Ollama server URL."
            case .invalidURL:
                return "Enter a valid Ollama server URL, such as http://localhost:11434 or https://ollama.example.com."
            case .unsupportedScheme:
                return "The Ollama server URL must use http or https."
            case .missingHost:
                return "The Ollama server URL must include a host name or IP address."
            case .credentialsNotAllowed:
                return "The Ollama server URL cannot include a username or password."
            case .queryNotAllowed:
                return "The Ollama server URL cannot include a query."
            case .fragmentNotAllowed:
                return "The Ollama server URL cannot include a fragment."
            case .pathNotAllowed:
                return "Enter the Ollama base URL without /api or another path."
            case .invalidPort:
                return "The Ollama server URL contains an invalid port."
            case .unsafeHTTPHost:
                return "HTTP is only allowed for localhost Ollama servers. Use HTTPS for remote servers."
            }
        }
    }

    public static let shared = OllamaEndpointConfiguration()
    public static let defaultBaseURL = URL(string: "http://localhost:11434")!

    static let endpointKey = "ollamaServerUrl"
    static let modelsByEndpointKey = "ollamaModelsByEndpoint"

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var baseURL: URL?
    private var validationError: ValidationError?
    private var revision: UInt64 = 0
    private var helperID: String?
    private var helperName: String?
    private var helper: MobileHelperConnection?
    private var helperError: MobileHelperError?
    private let credentialStore: any MobileHelperCredentialStoring
    private let syntheticDirectSession: URLSession?
    static let helperSelectionKey = "ollamaSelectedMobileHelperID"

    public convenience init(userDefaults: UserDefaults = .standard) {
        self.init(userDefaults: userDefaults, credentialStore: MobileHelperCredentialStore.shared)
    }

    init(userDefaults: UserDefaults, credentialStore: any MobileHelperCredentialStoring, directSession: URLSession? = nil) {
        defaults = userDefaults
        self.credentialStore = credentialStore
        syntheticDirectSession = directSession
        if let persisted = userDefaults.object(forKey: Self.endpointKey) {
            if let value = persisted as? String {
                do { baseURL = try Self.validate(value) }
                catch { validationError = (error as? ValidationError) ?? .invalidURL }
            } else { validationError = .invalidURL }
        } else {
            baseURL = Self.defaultBaseURL
        }
        helperID = userDefaults.string(forKey: Self.helperSelectionKey)
        helperName = userDefaults.string(forKey: "ollamaSelectedMobileHelperName")
        if let helperID {
            do {
                if let saved = try credentialStore.load(helperID: helperID) {
                    helper = MobileHelperConnection(credential: saved)
                } else { helperError = .disconnected }
            } catch { helperError = .persistence("The saved helper could not be loaded.") }
        }
    }

    public func snapshot() -> Snapshot { lock.withLock { snapshotLocked() } }

    public var directBaseURL: URL? { lock.withLock { synchronizeDirectLocked(); return baseURL } }
    public var directValidationError: ValidationError? { lock.withLock { synchronizeDirectLocked(); return validationError } }

    /// Validate persistence for each new operation/currentness check. Never rewrite
    /// rejected input or retarget already captured capabilities. Dormant direct
    /// settings do not invalidate a selected helper's authority.
    private func synchronizeDirectLocked() {
        var resolvedURL: URL?
        var resolvedError: ValidationError?
        if let persisted = defaults.object(forKey: Self.endpointKey) {
            if let value = persisted as? String {
                do { resolvedURL = try Self.validate(value) }
                catch { resolvedError = (error as? ValidationError) ?? .invalidURL }
            } else { resolvedError = .invalidURL }
        } else { resolvedURL = Self.defaultBaseURL }
        guard resolvedURL != baseURL || resolvedError != validationError else { return }
        baseURL = resolvedURL
        validationError = resolvedError
        if helperID == nil { revision &+= 1 }
    }

    private func snapshotLocked() -> Snapshot {
        synchronizeDirectLocked()
        return Snapshot(baseURL: helperID != nil ? helper?.credential.endpoint.appendingPathComponent("v1/ollama") : baseURL,
            validationError: helperID != nil ? nil : validationError,
            revision: revision, helperID: helperID, helperName: helper?.credential.name ?? helperName,
            helper: helper, helperError: helperError,
            directSession: helperID == nil && baseURL != nil && validationError == nil
                ? (syntheticDirectSession ?? LoopbackURLSession.shared) : nil)
    }

    /// Call only after pinned pairing and matching authenticated health verification.
    func selectHelper(_ connection: MobileHelperConnection) throws {
        try connection.credential.validate()
        try credentialStore.save(connection.credential)
        lock.withLock {
            helper = connection
            helperID = connection.credential.helperID
            helperName = connection.credential.name
            defaults.set(helperName, forKey: "ollamaSelectedMobileHelperName")
            helperError = nil
            revision &+= 1
            defaults.set(helperID, forKey: Self.helperSelectionKey)
        }
    }

    /// Disconnect is fail-closed, not an implicit switch to direct HTTP.
    public func disconnectHelper() throws {
        try lock.withLock {
            if let helperID { try credentialStore.remove(helperID: helperID) }
            helper = nil
            helperError = .disconnected
            revision &+= 1
        }
    }

    public func useDirect() {
        lock.withLock {
            helper = nil
            helperID = nil
            helperError = nil
            revision &+= 1
            defaults.removeObject(forKey: Self.helperSelectionKey)
        }
    }

    public func isCurrent(_ snapshot: Snapshot) -> Bool {
        lock.withLock { snapshot == snapshotLocked() }
    }

    @discardableResult
    public func update(_ value: String) throws -> Snapshot {
        let validated = try Self.validate(value)
        return lock.withLock {
            if validated != baseURL || validationError != nil || helperID != nil {
                baseURL = validated
                validationError = nil
                revision &+= 1
            }
            helper = nil
            helperID = nil
            helperError = nil
            defaults.removeObject(forKey: Self.helperSelectionKey)
            defaults.set(validated.absoluteString, forKey: Self.endpointKey)
            return snapshotLocked()
        }
    }

    public func cachedModels() -> [Ollama.Model] {
        lock.withLock {
            let snapshot = snapshotLocked()
            return snapshot.cacheScope.map { cachedModelsLocked(for: $0) } ?? []
        }
    }

    public func cachedModels(for snapshot: Snapshot) -> [Ollama.Model] {
        lock.withLock {
            guard snapshot == snapshotLocked(), let scope = snapshot.cacheScope else { return [] }
            return cachedModelsLocked(for: scope)
        }
    }

    /// Saves discovery results only while the endpoint snapshot is still current.
    @discardableResult
    public func storeModels(_ models: [Ollama.Model], for snapshot: Snapshot) -> Bool {
        lock.withLock {
            guard snapshot == snapshotLocked(), let scope = snapshot.cacheScope else { return false }
            var modelsByEndpoint = defaults.dictionary(forKey: Self.modelsByEndpointKey) as? [String: [String]] ?? [:]
            modelsByEndpoint[scope] = models.map(\.rawValue)
            defaults.set(modelsByEndpoint, forKey: Self.modelsByEndpointKey)
            return true
        }
    }

    public static func validate(_ value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ValidationError.empty }
        guard let components = URLComponents(string: trimmed), let scheme = components.scheme else {
            throw ValidationError.invalidURL
        }
        guard scheme.lowercased() == "http" || scheme.lowercased() == "https" else {
            throw ValidationError.unsupportedScheme
        }
        guard components.host?.isEmpty == false else { throw ValidationError.missingHost }
        guard components.user == nil, components.password == nil else {
            throw ValidationError.credentialsNotAllowed
        }
        guard components.query == nil, components.percentEncodedQuery == nil else {
            throw ValidationError.queryNotAllowed
        }
        guard components.fragment == nil, components.percentEncodedFragment == nil else {
            throw ValidationError.fragmentNotAllowed
        }
        if scheme.lowercased() == "http" {
            let host = components.host?.lowercased()
            guard ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) else {
                throw ValidationError.unsafeHTTPHost
            }
        }

        // URLComponents reports nil for both an absent and a malformed port, so
        // inspect the authority when a colon follows the host (excluding IPv6 brackets).
        if hasInvalidPort(in: trimmed, components: components) {
            throw ValidationError.invalidPort
        }

        var canonical = components
        canonical.scheme = scheme.lowercased()
        canonical.host = components.host?.lowercased()
        if canonical.percentEncodedPath == "/" { canonical.percentEncodedPath = "" }
        guard let url = canonical.url else { throw ValidationError.invalidURL }
        return url
    }

    private func cachedModelsLocked(for scope: String) -> [Ollama.Model] {
        let modelsByEndpoint = defaults.dictionary(forKey: Self.modelsByEndpointKey) as? [String: [String]] ?? [:]
        return (modelsByEndpoint[scope] ?? []).compactMap { Ollama.Model(rawValue: $0) }
    }

    private static func hasInvalidPort(in value: String, components: URLComponents) -> Bool {
        guard let authorityStart = value.range(of: "://")?.upperBound else { return true }
        let authority = value[authorityStart...].prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        let hostPort = authority.split(separator: "@", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let portText: Substring?
        if hostPort.hasPrefix("[") {
            guard let closingBracket = hostPort.firstIndex(of: "]") else { return true }
            let suffix = hostPort[hostPort.index(after: closingBracket)...]
            guard !suffix.isEmpty else { return false }
            guard suffix.first == ":" else { return true }
            portText = suffix.dropFirst()
        } else {
            let pieces = hostPort.split(separator: ":", omittingEmptySubsequences: false)
            guard pieces.count > 1 else { return false }
            guard pieces.count == 2 else { return true }
            portText = pieces.last
        }
        guard let portText, !portText.isEmpty,
              portText.allSatisfy(\.isNumber),
              let port = Int(portText), (1...65_535).contains(port),
              components.port == port
        else { return true }
        return false
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}

/// Private forwarding authority: the concrete provider (and its helper lease) cannot be
/// recovered or reconfigured by hosts consuming a captured snapshot capability.
private final class CapturedOllama: LangTools {
    typealias Model = Ollama.Model
    typealias ErrorResponse = Ollama.ErrorResponse
    private let provider: Ollama

    init(provider: Ollama) { self.provider = provider }
    var session: URLSession { provider.session }
    static var requestValidators: [(any LangToolsRequest) -> Bool] { Ollama.requestValidators }

    func prepare(request: some LangToolsRequest) throws -> URLRequest {
        try provider.prepare(request: request)
    }

    func perform<Request: LangToolsRequest>(request: Request) async throws -> Request.Response {
        try await provider.perform(request: request)
    }

    func perform<Request: LangToolsRequest>(request: Request, onResponse: @escaping (Request.Response) -> Void) async throws -> Request.Response {
        try await provider.perform(request: request, onResponse: onResponse)
    }

    func stream<Request: LangToolsStreamableRequest>(request: Request) -> AsyncThrowingStream<Request.Response, Error> {
        provider.stream(request: request)
    }

    static func decodeStream<T: Decodable>(_ buffer: String) throws -> T? {
        try Ollama.decodeStream(buffer)
    }

    static func chatRequest(model: any RawRepresentable, messages: [any LangToolsMessage], tools: [any LangToolsTool]?, responseSchema: JSONSchema?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> any LangToolsChatRequest {
        try Ollama.chatRequest(model: model, messages: messages, tools: tools, responseSchema: responseSchema, toolEventHandler: toolEventHandler)
    }
}
