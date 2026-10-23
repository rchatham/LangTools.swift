import Foundation
import Ollama

/// Thread-safe, persisted source of truth for the Ollama server and its model cache.
public final class OllamaEndpointConfiguration: @unchecked Sendable {
    public struct Snapshot: Equatable, Sendable {
        public let baseURL: URL
        public let revision: UInt64
        public let helperID: String?
        public let helperName: String?
        let helper: MobileHelperConnection?
        let helperError: MobileHelperError?
        public var isHelper: Bool { helperID != nil }
        var cacheScope: String { helperID.map { "helper:\($0)" } ?? baseURL.absoluteString }

        public static func == (lhs: Snapshot, rhs: Snapshot) -> Bool {
            lhs.baseURL == rhs.baseURL && lhs.revision == rhs.revision && lhs.helperID == rhs.helperID
        }

        public func actionableError(_ error: Error) -> Error {
            isHelper ? MobileHelperError.actionable(error, session: helper?.session) : error
        }

        func provider(directSession: URLSession) throws -> Ollama {
            if let helper, !helper.credential.capabilities.contains("ollama") { throw MobileHelperError.missingCapability("ollama") }
            if let helperError { throw helperError }
            if let helper {
                return Ollama(baseURL: baseURL, apiKey: helper.credential.token, sessionLease: helper.sessionLease)
            }
            guard !isHelper else { throw MobileHelperError.disconnected }
            return Ollama(baseURL: baseURL, session: directSession)
        }
    }

    public enum ValidationError: LocalizedError, Equatable {
        case empty
        case invalidURL
        case unsupportedScheme
        case missingHost
        case credentialsNotAllowed
        case queryNotAllowed
        case fragmentNotAllowed
        case pathNotAllowed
        case invalidPort

        public var errorDescription: String? {
            switch self {
            case .empty:
                return "Enter an Ollama server URL."
            case .invalidURL:
                return "Enter a valid Ollama server URL, such as http://192.168.1.10:11434."
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
            }
        }
    }

    public static let shared = OllamaEndpointConfiguration()
    public static let defaultBaseURL = URL(string: "http://localhost:11434")!

    static let endpointKey = "ollamaServerUrl"
    static let modelsByEndpointKey = "ollamaModelsByEndpoint"

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var baseURL: URL
    private var revision: UInt64 = 0
    private var helperID: String?
    private var helperName: String?
    private var helper: MobileHelperConnection?
    private var helperError: MobileHelperError?
    private let credentialStore: any MobileHelperCredentialStoring
    static let helperSelectionKey = "ollamaSelectedMobileHelperID"

    public convenience init(userDefaults: UserDefaults = .standard) {
        self.init(userDefaults: userDefaults, credentialStore: MobileHelperCredentialStore.shared)
    }

    init(userDefaults: UserDefaults, credentialStore: any MobileHelperCredentialStoring) {
        defaults = userDefaults
        self.credentialStore = credentialStore
        if let persisted = userDefaults.string(forKey: Self.endpointKey),
           let validated = try? Self.validate(persisted) {
            baseURL = validated
            if persisted != validated.absoluteString {
                userDefaults.set(validated.absoluteString, forKey: Self.endpointKey)
            }
        } else {
            baseURL = Self.defaultBaseURL
            userDefaults.set(Self.defaultBaseURL.absoluteString, forKey: Self.endpointKey)
        }
        helperID = userDefaults.string(forKey: Self.helperSelectionKey)
        helperName = userDefaults.string(forKey: "ollamaSelectedMobileHelperName")
        if let helperID, !defaults.bool(forKey: "ollamaMobileHelperDisconnected") {
            do {
                if let saved = try credentialStore.load(helperID: helperID) {
                    try saved.validate()
                    guard saved.capabilities.contains("ollama") else { throw MobileHelperError.missingCapability("ollama") }
                    helper = MobileHelperConnection(credential: saved)
                } else { helperError = .disconnected }
            } catch { helperError = error as? MobileHelperError ?? .persistence(error.localizedDescription) }
        } else if helperID != nil { helperError = .disconnected }
    }

    public func snapshot() -> Snapshot { lock.withLock { snapshotLocked() } }

    public var directBaseURL: URL { lock.withLock { baseURL } }

    private func snapshotLocked() -> Snapshot {
        Snapshot(baseURL: helper?.credential.endpoint.appendingPathComponent("v1/ollama") ?? baseURL,
            revision: revision, helperID: helperID, helperName: helper?.credential.name ?? helperName,
            helper: helper, helperError: helperError)
    }

    /// Call only after pinned pairing and matching authenticated health verification.
    func selectHelper(_ connection: MobileHelperConnection, persistCredential: Bool = true) throws {
        try connection.credential.validate()
        guard connection.credential.capabilities.contains("ollama") else { throw MobileHelperError.missingCapability("ollama") }
        if persistCredential { try credentialStore.save(connection.credential) }
        lock.withLock {
            helper = connection
            helperID = connection.credential.helperID
            helperName = connection.credential.name
            defaults.set(false, forKey: "ollamaMobileHelperDisconnected")
            defaults.set(helperName, forKey: "ollamaSelectedMobileHelperName")
            helperError = nil
            revision &+= 1
            defaults.set(helperID, forKey: Self.helperSelectionKey)
        }
    }

    /// Disconnect is fail-closed, not an implicit switch to direct HTTP.
    public func disconnectHelper() throws {
        try lock.withLock {
            var removalError: Error?
            if let helperID {
                do { try credentialStore.remove(helperID: helperID) } catch { removalError = error }
            }
            defaults.set(true, forKey: "ollamaMobileHelperDisconnected")
            helper = nil
            helperError = .disconnected
            revision &+= 1
            if let removalError { throw removalError }
        }
    }

    /// A replacement pairing with account-only grants cannot keep a prior
    /// Ollama connection/catalog usable under the same helper identity.
    func rejectMissingOllamaGrant(helperID: String) {
        lock.withLock {
            guard self.helperID == helperID else { return }
            helper = nil
            helperError = .missingCapability("ollama")
            defaults.set(true, forKey: "ollamaMobileHelperDisconnected")
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
            if validated != baseURL || helperID != nil {
                baseURL = validated
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
            return snapshot.helperError == nil ? cachedModelsLocked(for: snapshot.cacheScope) : []
        }
    }

    public func cachedModels(for snapshot: Snapshot) -> [Ollama.Model] {
        lock.withLock { snapshot.helperError == nil ? cachedModelsLocked(for: snapshot.cacheScope) : [] }
    }

    /// Saves discovery results only while the endpoint snapshot is still current.
    @discardableResult
    public func storeModels(_ models: [Ollama.Model], for snapshot: Snapshot) -> Bool {
        lock.withLock {
            guard snapshot == snapshotLocked() else { return false }
            var modelsByEndpoint = defaults.dictionary(forKey: Self.modelsByEndpointKey) as? [String: [String]] ?? [:]
            modelsByEndpoint[snapshot.cacheScope] = models.map(\.rawValue)
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
        guard components.path.isEmpty || components.path == "/" else {
            throw ValidationError.pathNotAllowed
        }

        // URLComponents reports nil for both an absent and a malformed port, so
        // inspect the authority when a colon follows the host (excluding IPv6 brackets).
        if hasInvalidPort(in: trimmed, components: components) {
            throw ValidationError.invalidPort
        }

        var canonical = components
        canonical.scheme = scheme.lowercased()
        canonical.path = ""
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
