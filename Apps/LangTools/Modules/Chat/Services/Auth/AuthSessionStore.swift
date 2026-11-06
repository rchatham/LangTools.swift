import Foundation
import KeychainAccess
import ToolKit

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

    /// Sessions share the service's cached `SecretVault` with API keys, so
    /// reading them costs at most one Keychain access per launch.
    private let vault: SecretVault
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(keychain: Keychain = Keychain(service: "com.reidchatham.LangTools_Example"), vault: SecretVault? = nil) {
        self.vault = vault ?? SecretVault.shared(service: keychain.service)
    }

    public func save(_ session: AccountSession) throws {
        let data = try encoder.encode(session)
        guard let json = String(data: data, encoding: .utf8) else {
            throw AuthSessionStoreError.encodingFailed
        }
        try vault.setValue(json, forKey: key(for: session.provider))
    }

    public func session(for provider: AccountLoginProvider) throws -> AccountSession? {
        guard let json = try vault.value(forKey: key(for: provider)) else {
            return nil
        }
        guard let data = json.data(using: .utf8) else {
            throw AuthSessionStoreError.decodingFailed
        }
        return try decoder.decode(AccountSession.self, from: data)
    }

    /// Whether a session is stored, without reading it from the Keychain.
    public func hasSession(for provider: AccountLoginProvider) -> Bool {
        vault.contains(key(for: provider))
    }

    public func removeSession(for provider: AccountLoginProvider) throws {
        try vault.removeValue(forKey: key(for: provider))
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
