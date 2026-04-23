import Foundation

public enum AccountLoginProvider: String, Codable, CaseIterable, Identifiable, Equatable {
    case openAI
    case claudeCode

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .claudeCode: return "Claude Code"
        }
    }

    public var service: APIService {
        switch self {
        case .openAI: return .openAI
        case .claudeCode: return .anthropic
        }
    }

    public var startPathComponent: String {
        switch self {
        case .openAI:
            return "openai"
        case .claudeCode:
            return "claude-code"
        }
    }
}

public enum ProviderCredential: Codable, Equatable {
    case apiKey(service: APIService)
    case accountSession(provider: AccountLoginProvider)
}

public struct AccountSession: Codable, Equatable, Identifiable {
    public let id: UUID
    public let provider: AccountLoginProvider
    public let accountIdentifier: String
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?
    public let accessibleModelIDs: [String]
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        provider: AccountLoginProvider,
        accountIdentifier: String,
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Date? = nil,
        accessibleModelIDs: [String] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.provider = provider
        self.accountIdentifier = accountIdentifier
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.accessibleModelIDs = accessibleModelIDs
        self.createdAt = createdAt
    }

    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }
}

public enum ProviderAuthStatus: Equatable {
    case notConfigured
    case apiKeyConfigured
    case accountConnected(AccountLoginProvider)
    case apiKeyAndAccount(AccountLoginProvider)
}

public struct ProviderAccessState: Equatable {
    public let service: APIService
    public let authStatus: ProviderAuthStatus
    public let availableModels: [Model]
    public let accountIdentifier: String?

    public init(
        service: APIService,
        authStatus: ProviderAuthStatus,
        availableModels: [Model],
        accountIdentifier: String? = nil
    ) {
        self.service = service
        self.authStatus = authStatus
        self.availableModels = availableModels
        self.accountIdentifier = accountIdentifier
    }

    public var hasAPIKey: Bool {
        switch authStatus {
        case .apiKeyConfigured, .apiKeyAndAccount:
            return true
        default:
            return false
        }
    }

    public var hasAccountSession: Bool {
        switch authStatus {
        case .accountConnected, .apiKeyAndAccount:
            return true
        default:
            return false
        }
    }

    public var statusDescription: String {
        switch authStatus {
        case .notConfigured:
            return "Not configured"
        case .apiKeyConfigured:
            return "API key saved"
        case .accountConnected(let provider):
            if let accountIdentifier {
                return "Connected via \(provider.displayName) as \(accountIdentifier)"
            }
            return "Connected via \(provider.displayName)"
        case .apiKeyAndAccount(let provider):
            if let accountIdentifier {
                return "API key + \(provider.displayName) account (\(accountIdentifier))"
            }
            return "API key + \(provider.displayName) account"
        }
    }
}

public extension APIService {
    var accountLoginProvider: AccountLoginProvider? {
        switch self {
        case .openAI: return .openAI
        case .anthropic: return .claudeCode
        default: return nil
        }
    }
}
