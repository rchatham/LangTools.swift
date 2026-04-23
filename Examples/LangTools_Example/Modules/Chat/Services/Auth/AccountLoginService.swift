import Anthropic
import Foundation
import OpenAI

public enum AccountLoginError: LocalizedError, Equatable {
    case notImplemented(AccountLoginProvider)

    public var errorDescription: String? {
        switch self {
        case .notImplemented(let provider):
            switch provider {
            case .openAI:
                return "OpenAI OAuth is not implemented in this branch yet. Use an API key for now."
            case .claudeCode:
                return "Claude Code login is not implemented in this branch yet. Use an Anthropic API key for now."
            }
        }
    }
}

public protocol AccountLoginService {
    func beginLogin(for provider: AccountLoginProvider) async throws -> AccountSession
    func refreshSession(_ session: AccountSession) async throws -> AccountSession
    func logout(provider: AccountLoginProvider) async throws
    func fetchAccessibleModels(for provider: AccountLoginProvider) async throws -> [String]
}

public final class StubAccountLoginService: AccountLoginService {
    public init() {}

    public func beginLogin(for provider: AccountLoginProvider) async throws -> AccountSession {
        throw AccountLoginError.notImplemented(provider)
    }

    public func refreshSession(_ session: AccountSession) async throws -> AccountSession {
        throw AccountLoginError.notImplemented(session.provider)
    }

    public func logout(provider: AccountLoginProvider) async throws {
        _ = provider
    }

    public func fetchAccessibleModels(for provider: AccountLoginProvider) async throws -> [String] {
        switch provider {
        case .openAI:
            return OpenAI.Model.chatModels.map(\.rawValue)
        case .claudeCode:
            return Anthropic.Model.activeCases.map(\.rawValue)
        }
    }

}
