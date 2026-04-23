import Foundation
import KeychainAccess

public final class AuthSessionStore {
    public static let shared = AuthSessionStore()

    private let keychain: Keychain
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(keychain: Keychain = Keychain(service: "com.reidchatham.LangTools_Example")) {
        self.keychain = keychain
    }

    public func save(_ session: AccountSession) throws {
        let data = try encoder.encode(session)
        guard let json = String(data: data, encoding: .utf8) else {
            throw AuthSessionStoreError.encodingFailed
        }
        try keychain.set(json, key: key(for: session.provider))
    }

    public func session(for provider: AccountLoginProvider) throws -> AccountSession? {
        guard let json = try keychain.getString(key(for: provider)) else {
            return nil
        }
        guard let data = json.data(using: .utf8) else {
            throw AuthSessionStoreError.decodingFailed
        }
        return try decoder.decode(AccountSession.self, from: data)
    }

    public func removeSession(for provider: AccountLoginProvider) throws {
        try keychain.remove(key(for: provider))
    }

    public func allSessions() throws -> [AccountSession] {
        try AccountLoginProvider.allCases.compactMap { try session(for: $0) }
    }

    func key(for provider: AccountLoginProvider) -> String {
        "\(provider.rawValue):accountSession"
    }
}

public enum AuthSessionStoreError: Error {
    case encodingFailed
    case decodingFailed
}
