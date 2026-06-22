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
    public let idToken: String?
    public let tokenType: String?
    public let expiresAt: Date?
    public let accessibleModelIDs: [String]
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        provider: AccountLoginProvider,
        accountIdentifier: String,
        accessToken: String,
        refreshToken: String? = nil,
        idToken: String? = nil,
        tokenType: String? = nil,
        expiresAt: Date? = nil,
        accessibleModelIDs: [String] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.provider = provider
        self.accountIdentifier = accountIdentifier
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.tokenType = tokenType
        self.expiresAt = expiresAt
        self.accessibleModelIDs = accessibleModelIDs
        self.createdAt = createdAt
    }

    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }

    public var needsRefresh: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date().addingTimeInterval(5 * 60)
    }
}

extension AccountSession: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "AccountSession(id: \(id), provider: \(provider), accountIdentifier: \(accountIdentifier), accessToken: <redacted>)"
    }
    public var debugDescription: String { description }
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

    public var badgeTitle: String {
        switch authStatus {
        case .notConfigured:
            return "Not Connected"
        case .apiKeyConfigured:
            return "API Key"
        case .accountConnected:
            return "Account"
        case .apiKeyAndAccount:
            return "API Key + Account"
        }
    }

    public var authSummary: String {
        switch service {
        case .openAI:
            return "Add an API key for API requests or sign in with OpenAI to unlock account-based model access."
        case .anthropic:
            return "Add an Anthropic API key or sign in with Claude Code for account-based access."
        case .xAI, .gemini:
            return "Add an API key to enable this provider."
        case .ollama:
            return "Local models do not require sign-in."
        case .serper:
            return "Add a Serper API key for search."
        }
    }
}

public extension ProviderAuthStatus {
    var isConfigured: Bool {
        self != .notConfigured
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
