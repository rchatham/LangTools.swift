import Anthropic
#if canImport(CryptoKit)
import CryptoKit
#endif
import Foundation
import OpenAI
#if os(macOS)
import AppKit
#endif
#if os(iOS)
import UIKit
#endif

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
    func loginStartURL(for provider: AccountLoginProvider, state: String, codeChallenge: String?, redirectURI: String?) -> URL
    func exchange(provider: AccountLoginProvider, payload: AuthRedirectPayload, codeVerifier: String?, redirectURI: String?) async throws -> AccountSession
    func refresh(session: AccountSession) async throws -> AccountSession
    func logout(provider: AccountLoginProvider, session: AccountSession?) async throws
    func fetchAccessibleModels(for provider: AccountLoginProvider, session: AccountSession?) async throws -> [String]
}

public final class BrowserAccountLoginService: AccountLoginService {
    public static let shared = BrowserAccountLoginService()

    private let coordinator: AccountLoginCoordinating
    private let backendClient: AccountLoginBackendClientProtocol
    private let sessionStore: AuthSessionStore
    private let configuration: AccountBackendConfiguration
    private let cliBridge: CLIAccountSessionBridge

    private struct PendingLogin {
        let provider: AccountLoginProvider
        let state: String
        let codeVerifier: String?
        let redirectURI: String?
    }

    private var pendingLogin: PendingLogin?

    public init(
        coordinator: AccountLoginCoordinating = AccountLoginCoordinator.shared,
        backendClient: AccountLoginBackendClientProtocol? = nil,
        sessionStore: AuthSessionStore = .shared,
        configuration: AccountBackendConfiguration = AccountBackendConfiguration(),
        cliBridge: CLIAccountSessionBridge = CLIAccountSessionBridge()
    ) {
        self.coordinator = coordinator
        self.sessionStore = sessionStore
        self.configuration = configuration
        self.cliBridge = cliBridge
        self.backendClient = backendClient ?? AccountLoginBackendClient(configuration: configuration)
    }

    public func beginLogin(for provider: AccountLoginProvider) async throws -> AccountSession {
        if pendingLogin != nil {
            throw AccountLoginError.loginAlreadyInProgress
        }

        if provider == .openAI {
            return try await cliBridge.loginOpenAI()
        }

        let pkce = provider == .openAI ? PKCEChallenge() : nil
        let state = Self.randomState()

        pendingLogin = PendingLogin(provider: provider, state: state, codeVerifier: pkce?.codeVerifier, redirectURI: nil)

        defer {
            pendingLogin = nil
        }

        let loginURL = backendClient.loginStartURL(for: provider, state: state, codeChallenge: pkce?.codeChallenge, redirectURI: nil)
        let callbackURL = try await coordinator.startLogin(
            at: loginURL,
            callbackScheme: AccountBackendConfiguration.callbackScheme,
            provider: provider
        )
        return try await handleRedirect(callbackURL)
    }

    public func handleRedirect(_ url: URL) async throws -> AccountSession {
        guard let pendingLogin else {
            throw AccountLoginError.loginAlreadyInProgress
        }

        let payload = try Self.parseRedirect(url, expectedProvider: pendingLogin.provider, expectedState: pendingLogin.state)
        return try await backendClient.exchange(
            provider: pendingLogin.provider,
            payload: payload,
            codeVerifier: pendingLogin.codeVerifier,
            redirectURI: pendingLogin.redirectURI
        )
    }

    public func refreshSession(_ session: AccountSession) async throws -> AccountSession {
        let refreshedSession: AccountSession
        if session.provider == .openAI, session.needsRefresh {
            refreshedSession = try await backendClient.refresh(session: session)
        } else {
            refreshedSession = session
        }

        let models = try await backendClient.fetchAccessibleModels(for: refreshedSession.provider, session: refreshedSession)
        return AccountSession(
            id: refreshedSession.id,
            provider: refreshedSession.provider,
            accountIdentifier: refreshedSession.accountIdentifier,
            accessToken: refreshedSession.accessToken,
            refreshToken: refreshedSession.refreshToken,
            idToken: refreshedSession.idToken,
            tokenType: refreshedSession.tokenType,
            expiresAt: refreshedSession.expiresAt,
            accessibleModelIDs: models,
            createdAt: refreshedSession.createdAt
        )
    }

    public func logout(provider: AccountLoginProvider) async throws {
        if provider == .openAI {
            try await cliBridge.logoutOpenAI()
            return
        }

        let session = try sessionStore.session(for: provider)
        try await backendClient.logout(provider: provider, session: session)
    }

    public func fetchAccessibleModels(for provider: AccountLoginProvider) async throws -> [String] {
        let session = try sessionStore.session(for: provider)
        return try await backendClient.fetchAccessibleModels(for: provider, session: session)
    }

    public static func parseRedirect(_ url: URL, expectedProvider: AccountLoginProvider, expectedState: String) throws -> AuthRedirectPayload {
        if expectedProvider == .openAI {
            return try parseOpenAILocalhostRedirect(url, expectedState: expectedState)
        }

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

    private static func parseOpenAILocalhostRedirect(_ url: URL, expectedState: String) throws -> AuthRedirectPayload {
        guard url.scheme == "http", url.path == "/auth/callback" else {
            throw AccountLoginError.invalidCallbackURL
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
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

        return AuthRedirectPayload(provider: .openAI, code: code, state: state)
    }

    private static func openBrowser(at url: URL) throws {
        #if os(macOS)
        guard NSWorkspace.shared.open(url) else {
            throw AccountLoginError.unableToStartBrowserSession
        }
        #elseif os(iOS)
        Task { @MainActor in
            await UIApplication.shared.open(url)
        }
        #else
        throw AccountLoginError.unsupportedPlatform
        #endif
    }

    private static func randomState() -> String {
        PKCEChallenge.randomURLSafeString(length: 32)
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

    public func loginStartURL(for provider: AccountLoginProvider, state: String, codeChallenge: String?, redirectURI: String?) -> URL {
        switch provider {
        case .openAI:
            return OpenAIOAuthConfiguration.authorizeURL(
                state: state,
                codeChallenge: codeChallenge ?? "",
                redirectURI: redirectURI ?? configuration.callbackURL(for: provider).absoluteString
            )
        case .claudeCode:
            return configuration.loginStartURL(for: provider, state: state)
        }
    }

    public func exchange(provider: AccountLoginProvider, payload: AuthRedirectPayload, codeVerifier: String?, redirectURI: String?) async throws -> AccountSession {
        switch provider {
        case .openAI:
            guard let codeVerifier else {
                throw AccountLoginError.sessionExchangeFailed("Missing OpenAI PKCE verifier.")
            }

            let requestBody = OpenAITokenRequest.authorizationCode(
                code: payload.code,
                codeVerifier: codeVerifier,
                redirectURI: redirectURI ?? configuration.callbackURL(for: provider).absoluteString
            )

            var request = URLRequest(url: OpenAIOAuthConfiguration.tokenURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(requestBody)

            let (data, response) = try await urlSession.data(for: request)
            try validate(response: response, data: data)

            let tokenResponse = try decoder.decode(OpenAITokenResponse.self, from: data)
            return tokenResponse.accountSession(provider: provider)
        case .claudeCode:
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
    }

    public func refresh(session: AccountSession) async throws -> AccountSession {
        switch session.provider {
        case .openAI:
            guard let refreshToken = session.refreshToken else {
                throw AccountLoginError.sessionExchangeFailed("No refresh token is available for the OpenAI session.")
            }

            var request = URLRequest(url: OpenAIOAuthConfiguration.tokenURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(OpenAITokenRequest.refreshToken(refreshToken: refreshToken))

            let (data, response) = try await urlSession.data(for: request)
            try validate(response: response, data: data)

            let tokenResponse = try decoder.decode(OpenAITokenResponse.self, from: data)
            return tokenResponse.accountSession(provider: session.provider, fallback: session)
        case .claudeCode:
            let models = try await fetchAccessibleModels(for: session.provider, session: session)
            return AccountSession(
                id: session.id,
                provider: session.provider,
                accountIdentifier: session.accountIdentifier,
                accessToken: session.accessToken,
                refreshToken: session.refreshToken,
                idToken: session.idToken,
                tokenType: session.tokenType,
                expiresAt: session.expiresAt,
                accessibleModelIDs: models,
                createdAt: session.createdAt
            )
        }
    }

    public func logout(provider: AccountLoginProvider, session: AccountSession?) async throws {
        switch provider {
        case .openAI:
            return
        case .claudeCode:
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
    }

    public func fetchAccessibleModels(for provider: AccountLoginProvider, session: AccountSession?) async throws -> [String] {
        switch provider {
        case .openAI:
            return OpenAI.Model.codex.map(\.rawValue)
        case .claudeCode:
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

private enum OpenAIOAuthConfiguration {
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let scope = "openid openai profile email offline_access"
    static let authorizeEndpoint = URL(string: "https://auth.openai.com/oauth/authorize")!
    static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!

    static func authorizeURL(state: String, codeChallenge: String, redirectURI: String) -> URL {
        var components = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "id_token_add_organizations", value: "true")
        ]
        return components.url!
    }
}

private struct PKCEChallenge {
    let codeVerifier: String
    let codeChallenge: String

    init() {
        let verifier = Self.randomURLSafeString(length: 64)
        self.codeVerifier = verifier
        self.codeChallenge = Self.sha256Base64URL(verifier)
    }

    static func randomURLSafeString(length: Int) -> String {
        let bytes = (0..<length).map { _ in UInt8.random(in: 0...255) }
        let allowed = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return String(bytes.map { allowed[Int($0) % allowed.count] })
    }

    private static func sha256Base64URL(_ value: String) -> String {
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: Data(value.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        #else
        return value
        #endif
    }
}

private struct OpenAITokenRequest: Codable {
    let grantType: String
    let clientID: String
    let code: String?
    let codeVerifier: String?
    let redirectURI: String?
    let refreshToken: String?

    static func authorizationCode(code: String, codeVerifier: String, redirectURI: String) -> Self {
        Self(
            grantType: "authorization_code",
            clientID: OpenAIOAuthConfiguration.clientID,
            code: code,
            codeVerifier: codeVerifier,
            redirectURI: redirectURI,
            refreshToken: nil
        )
    }

    static func refreshToken(refreshToken: String) -> Self {
        Self(
            grantType: "refresh_token",
            clientID: OpenAIOAuthConfiguration.clientID,
            code: nil,
            codeVerifier: nil,
            redirectURI: nil,
            refreshToken: refreshToken
        )
    }

    enum CodingKeys: String, CodingKey {
        case grantType = "grant_type"
        case clientID = "client_id"
        case code
        case codeVerifier = "code_verifier"
        case redirectURI = "redirect_uri"
        case refreshToken = "refresh_token"
    }
}

private struct OpenAITokenResponse: Codable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let tokenType: String?
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
    }

    func accountSession(provider: AccountLoginProvider, fallback: AccountSession? = nil) -> AccountSession {
        let now = Date()
        let expiry = expiresIn.map { now.addingTimeInterval(TimeInterval($0)) }
        let accountIdentifier = fallback?.accountIdentifier ?? "OpenAI Account"
        return AccountSession(
            id: fallback?.id ?? UUID(),
            provider: provider,
            accountIdentifier: accountIdentifier,
            accessToken: accessToken,
            refreshToken: refreshToken ?? fallback?.refreshToken,
            idToken: idToken ?? fallback?.idToken,
            tokenType: tokenType ?? fallback?.tokenType,
            expiresAt: expiry ?? fallback?.expiresAt,
            accessibleModelIDs: fallback?.accessibleModelIDs ?? [],
            createdAt: fallback?.createdAt ?? now
        )
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
        throw AccountLoginError.invalidCallbackURL
    }

    public func refreshSession(_ session: AccountSession) async throws -> AccountSession {
        throw AccountLoginError.missingStoredSession(session.provider)
    }

    public func logout(provider: AccountLoginProvider) async throws {}

    public func fetchAccessibleModels(for provider: AccountLoginProvider) async throws -> [String] {
        switch provider {
        case .openAI:
            return OpenAI.Model.codex.map(\.rawValue)
        case .claudeCode:
            return Anthropic.Model.activeCases.map(\.rawValue)
        }
    }
}
