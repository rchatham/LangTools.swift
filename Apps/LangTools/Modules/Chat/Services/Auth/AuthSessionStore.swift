import Foundation
import KeychainAccess

public final class AuthSessionStore {
    /// Returns the shared instance. When a validated fixture environment is
    /// active the instance uses the fixture-isolated Keychain service;
    /// otherwise it uses the ordinary app service.
    public static var shared: AuthSessionStore {
        if ChatUITestEnvironment.isFixtureActive {
            return fixtureInstance
        }
        return ordinaryInstance
    }

    /// The ordinary app Keychain service.
    private static let ordinaryInstance = AuthSessionStore(
        keychain: Keychain(service: "com.reidchatham.LangTools_Example")
    )

    /// The fixture-isolated Keychain service.
    private static let fixtureInstance = AuthSessionStore(
        keychain: Keychain(service: ChatUITestEnvironment.fixtureKeychainService)
    )

    private let secrets: any KeychainSecretStoring
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lock = NSLock()
    private var revisions: [AccountLoginProvider: UInt64] = [:]

    struct Snapshot {
        let session: AccountSession?
        let revision: UInt64
    }
    func revision(for provider: AccountLoginProvider) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return revisions[provider] ?? 0
    }

    public init(keychain: Keychain = Keychain(service: "com.reidchatham.LangTools_Example")) {
        self.secrets = KeychainService(keychain: keychain)
    }

    /// Isolated storage seam for tests and hosts with their own secure store.
    public init(secretStore: any KeychainSecretStoring) {
        secrets = secretStore
    }

    public func save(_ session: AccountSession) throws {
        lock.lock(); defer { lock.unlock() }
        let data = try encoder.encode(session)
        guard let json = String(data: data, encoding: .utf8) else {
            throw AuthSessionStoreError.encodingFailed
        }
        try secrets.setSecret(json, forKey: key(for: session.provider))
        revisions[session.provider, default: 0] &+= 1
    }

    public func session(for provider: AccountLoginProvider) throws -> AccountSession? {
        try snapshot(for: provider).session
    }

    func snapshot(for provider: AccountLoginProvider) throws -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        guard let json = try secrets.readSecret(forKey: key(for: provider)) else {
            return Snapshot(session: nil, revision: revisions[provider] ?? 0)
        }
        guard let data = json.data(using: .utf8) else {
            throw AuthSessionStoreError.decodingFailed
        }
        return Snapshot(session: try decoder.decode(AccountSession.self, from: data), revision: revisions[provider] ?? 0)
    }

    public func removeSession(for provider: AccountLoginProvider) throws {
        lock.lock(); defer { lock.unlock() }
        try secrets.removeSecret(forKey: key(for: provider))
        revisions[provider, default: 0] &+= 1
    }

    public func allSessions() throws -> [AccountSession] {
        try AccountLoginProvider.allCases.compactMap { try session(for: $0) }
    }

    private func key(for provider: AccountLoginProvider) -> String {
        "\(provider.rawValue):accountSession"
    }
}

public enum AuthSessionStoreError: Error {
    case encodingFailed
    case decodingFailed
}
