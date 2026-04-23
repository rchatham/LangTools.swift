import Anthropic
import Foundation
import OpenAI

public protocol AccountLoginService {
    func beginLogin(for provider: AccountLoginProvider) async throws -> AccountSession
    func refreshSession(_ session: AccountSession) async throws -> AccountSession
    func logout(provider: AccountLoginProvider) async throws
    func fetchAccessibleModels(for provider: AccountLoginProvider) async throws -> [String]
}

public final class StubAccountLoginService: AccountLoginService {
    public init() {}

    public func beginLogin(for provider: AccountLoginProvider) async throws -> AccountSession {
        let models = try await fetchAccessibleModels(for: provider)
        return AccountSession(
            provider: provider,
            accountIdentifier: defaultIdentifier(for: provider),
            accessToken: "stub-\(provider.rawValue)-token",
            accessibleModelIDs: models
        )
    }

    public func refreshSession(_ session: AccountSession) async throws -> AccountSession {
        AccountSession(
            id: session.id,
            provider: session.provider,
            accountIdentifier: session.accountIdentifier,
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            expiresAt: session.expiresAt,
            accessibleModelIDs: try await fetchAccessibleModels(for: session.provider),
            createdAt: session.createdAt
        )
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

    private func defaultIdentifier(for provider: AccountLoginProvider) -> String {
        switch provider {
        case .openAI: return "openai-account"
        case .claudeCode: return "claude-code-account"
        }
    }
}
