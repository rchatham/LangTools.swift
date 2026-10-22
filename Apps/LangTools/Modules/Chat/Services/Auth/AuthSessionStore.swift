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

    private let keychain: Keychain?
    private let syntheticSecrets: (any KeychainSecretStoring)?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(keychain: Keychain = Keychain(service: "com.reidchatham.LangTools_Example")) {
        self.keychain = keychain
        syntheticSecrets = nil
    }

    /// Internal store seam for synthetic tests; production still uses Keychain unchanged.
    init(secretStore: any KeychainSecretStoring) {
        keychain = nil
        syntheticSecrets = secretStore
    }

    public func save(_ session: AccountSession) throws {
        let data = try encoder.encode(session)
        guard let json = String(data: data, encoding: .utf8) else {
            throw AuthSessionStoreError.encodingFailed
        }
        if let syntheticSecrets { try syntheticSecrets.setSecret(json, forKey: key(for: session.provider)) }
        else { try keychain?.set(json, key: key(for: session.provider)) }
    }

    public func session(for provider: AccountLoginProvider) throws -> AccountSession? {
        let stored = try syntheticSecrets?.readSecret(forKey: key(for: provider)) ?? keychain?.getString(key(for: provider))
        guard let json = stored else {
            return nil
        }
        guard let data = json.data(using: .utf8) else {
            throw AuthSessionStoreError.decodingFailed
        }
        return try decoder.decode(AccountSession.self, from: data)
    }

    public func removeSession(for provider: AccountLoginProvider) throws {
        if let syntheticSecrets { try syntheticSecrets.removeSecret(forKey: key(for: provider)) }
        else { try keychain?.remove(key(for: provider)) }
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
