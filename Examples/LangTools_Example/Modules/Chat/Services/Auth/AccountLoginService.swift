import Anthropic
import Foundation
import OpenAI

public enum AccountLoginError: LocalizedError, Equatable {
    case unsupportedPlatform
    case cancelled
    case missingCallbackURL
    case unableToStartBrowserSession
    case invalidCallbackURL
    case missingAuthorizationCode
    case stateMismatch
    case unsupportedProviderInCallback
    case callbackError(String)
    case loginAlreadyInProgress
    case missingStoredSession(AccountLoginProvider)
    case sessionExchangeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            return "Browser-based account login is not supported on this platform."
        case .cancelled:
            return "Sign-in was cancelled."
        case .missingCallbackURL:
            return "The sign-in flow did not return a callback URL."
        case .unableToStartBrowserSession:
            return "Unable to start the browser-based sign-in flow."
        case .invalidCallbackURL:
            return "The sign-in callback URL was invalid."
        case .missingAuthorizationCode:
            return "The sign-in callback did not include an authorization code."
        case .stateMismatch:
            return "The sign-in callback could not be verified. Please try again."
        case .unsupportedProviderInCallback:
            return "The sign-in callback referenced an unsupported provider."
        case .callbackError(let message):
            return message
        case .loginAlreadyInProgress:
            return "Another account login is already in progress."
        case .missingStoredSession(let provider):
            return "No stored \(provider.displayName) account session was found."
        case .sessionExchangeFailed(let message):
            return message
        }
    }
}

public struct AuthRedirectPayload: Equatable {
    public let provider: AccountLoginProvider
    public let code: String
    public let state: String
}

public protocol AccountLoginService {
    func beginLogin(for provider: AccountLoginProvider) async throws -> AccountSession
    func handleRedirect(_ url: URL) async throws -> AccountSession
    func refreshSession(_ session: AccountSession) async throws -> AccountSession
    func logout(provider: AccountLoginProvider) async throws
    func fetchAccessibleModels(for provider: AccountLoginProvider) async throws -> [String]
}

public protocol AccountLoginBackendClientProtocol {
    func loginStartURL(for provider: AccountLoginProvider, state: String) -> URL
    func exchange(provider: AccountLoginProvider, payload: AuthRedirectPayload) async throws -> AccountSession
    func logout(provider: AccountLoginProvider, session: AccountSession?) async throws
    func fetchAccessibleModels(for provider: AccountLoginProvider, session: AccountSession?) async throws -> [String]
}

public final class BrowserAccountLoginService: AccountLoginService {
    public static let shared = BrowserAccountLoginService()

    private let coordinator: AccountLoginCoordinating
    private let backendClient: AccountLoginBackendClientProtocol
    private let sessionStore: AuthSessionStore
    private let configuration: AccountBackendConfiguration

    private var pendingProvider: AccountLoginProvider?
    private var pendingState: String?

    public init(
        coordinator: AccountLoginCoordinating = AccountLoginCoordinator.shared,
        backendClient: AccountLoginBackendClientProtocol? = nil,
        sessionStore: AuthSessionStore = .shared,
        configuration: AccountBackendConfiguration = AccountBackendConfiguration()
    ) {
        self.coordinator = coordinator
        self.sessionStore = sessionStore
        self.configuration = configuration
        self.backendClient = backendClient ?? AccountLoginBackendClient(configuration: configuration)
    }

    public func beginLogin(for provider: AccountLoginProvider) async throws -> AccountSession {
        if pendingProvider != nil || pendingState != nil {
            throw AccountLoginError.loginAlreadyInProgress
        }

        let state = UUID().uuidString
        pendingProvider = provider
        pendingState = state

        defer {
            pendingProvider = nil
            pendingState = nil
        }

        let loginURL = backendClient.loginStartURL(for: provider, state: state)
        let callbackURL = try await coordinator.startLogin(
            at: loginURL,
            callbackScheme: AccountBackendConfiguration.callbackScheme,
            provider: provider
        )
        return try await handleRedirect(callbackURL)
    }

    public func handleRedirect(_ url: URL) async throws -> AccountSession {
        guard let expectedProvider = pendingProvider,
              let expectedState = pendingState
        else {
            throw AccountLoginError.loginAlreadyInProgress
        }

        let payload = try Self.parseRedirect(url, expectedProvider: expectedProvider, expectedState: expectedState)
        return try await backendClient.exchange(provider: expectedProvider, payload: payload)
    }

    public func refreshSession(_ session: AccountSession) async throws -> AccountSession {
        let models = try await backendClient.fetchAccessibleModels(for: session.provider, session: session)
        return AccountSession(
            id: session.id,
            provider: session.provider,
            accountIdentifier: session.accountIdentifier,
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            expiresAt: session.expiresAt,
            accessibleModelIDs: models,
            createdAt: session.createdAt
        )
    }

    public func logout(provider: AccountLoginProvider) async throws {
        let session = try sessionStore.session(for: provider)
        try await backendClient.logout(provider: provider, session: session)
    }

    public func fetchAccessibleModels(for provider: AccountLoginProvider) async throws -> [String] {
        let session = try sessionStore.session(for: provider)
        return try await backendClient.fetchAccessibleModels(for: provider, session: session)
    }

    public static func parseRedirect(_ url: URL, expectedProvider: AccountLoginProvider, expectedState: String) throws -> AuthRedirectPayload {
        guard url.scheme == AccountBackendConfiguration.callbackScheme else {
            throw AccountLoginError.invalidCallbackURL
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        guard pathComponents.count >= 2,
              pathComponents[0] == "callback",
              let provider = AccountLoginProvider(rawValue: pathComponents[1])
        else {
            throw AccountLoginError.unsupportedProviderInCallback
        }

        guard provider == expectedProvider else {
            throw AccountLoginError.unsupportedProviderInCallback
        }

        if let error = components?.queryItems?.first(where: { $0.name == "error" })?.value {
            let description = components?.queryItems?.first(where: { $0.name == "error_description" })?.value
            throw AccountLoginError.callbackError(description ?? error)
        }

        guard let state = components?.queryItems?.first(where: { $0.name == "state" })?.value,
              state == expectedState
        else {
            throw AccountLoginError.stateMismatch
        }

        guard let code = components?.queryItems?.first(where: { $0.name == "code" })?.value,
              code.isEmpty == false
        else {
            throw AccountLoginError.missingAuthorizationCode
        }

        return AuthRedirectPayload(provider: provider, code: code, state: state)
    }
}

public final class AccountLoginBackendClient: AccountLoginBackendClientProtocol {
    private let configuration: AccountBackendConfiguration
    private let urlSession: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        configuration: AccountBackendConfiguration = AccountBackendConfiguration(),
        urlSession: URLSession = .shared
    ) {
        self.configuration = configuration
        self.urlSession = urlSession
    }

    public func loginStartURL(for provider: AccountLoginProvider, state: String) -> URL {
        configuration.loginStartURL(for: provider, state: state)
    }

    public func exchange(provider: AccountLoginProvider, payload: AuthRedirectPayload) async throws -> AccountSession {
        let requestBody = SessionExchangeRequest(
            code: payload.code,
            state: payload.state,
            redirectURI: configuration.callbackURL(for: provider).absoluteString
        )

        var request = URLRequest(url: configuration.exchangeURL(for: provider))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(requestBody)

        let (data, response) = try await urlSession.data(for: request)
        try validate(response: response, data: data)

        let sessionResponse = try decoder.decode(SessionExchangeResponse.self, from: data)
        return AccountSession(
            provider: provider,
            accountIdentifier: sessionResponse.accountIdentifier,
            accessToken: sessionResponse.accessToken,
            refreshToken: sessionResponse.refreshToken,
            expiresAt: sessionResponse.expiresAt,
            accessibleModelIDs: sessionResponse.accessibleModelIDs,
            createdAt: Date()
        )
    }

    public func logout(provider: AccountLoginProvider, session: AccountSession?) async throws {
        var request = URLRequest(url: configuration.logoutURL(for: provider))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let session {
            request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        }

        let (_, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            throw AccountLoginError.sessionExchangeFailed("Failed to log out of \(provider.displayName).")
        }
    }

    public func fetchAccessibleModels(for provider: AccountLoginProvider, session: AccountSession?) async throws -> [String] {
        guard let session else {
            throw AccountLoginError.missingStoredSession(provider)
        }

        var request = URLRequest(url: configuration.baseURL.appending(path: "/auth/\(provider.startPathComponent)/models"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await urlSession.data(for: request)
        try validate(response: response, data: data)
        return try decoder.decode(AccessibleModelsResponse.self, from: data).models
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AccountLoginError.sessionExchangeFailed("Invalid auth server response.")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Auth server returned status \(httpResponse.statusCode)."
            throw AccountLoginError.sessionExchangeFailed(message)
        }
    }
}

private struct SessionExchangeRequest: Codable {
    let code: String
    let state: String
    let redirectURI: String
}

private struct SessionExchangeResponse: Codable {
    let accountIdentifier: String
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    let accessibleModelIDs: [String]
}

private struct AccessibleModelsResponse: Codable {
    let models: [String]
}

public final class StubAccountLoginService: AccountLoginService {
    public init() {}

    public func beginLogin(for provider: AccountLoginProvider) async throws -> AccountSession {
        throw AccountLoginError.sessionExchangeFailed("\(provider.displayName) login is not configured.")
    }

    public func handleRedirect(_ url: URL) async throws -> AccountSession {
        _ = url
        throw AccountLoginError.invalidCallbackURL
    }

    public func refreshSession(_ session: AccountSession) async throws -> AccountSession {
        throw AccountLoginError.missingStoredSession(session.provider)
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
