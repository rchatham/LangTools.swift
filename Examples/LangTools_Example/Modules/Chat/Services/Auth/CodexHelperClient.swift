import Foundation

public protocol CodexHelperClientProtocol {
    func loginOpenAI() async throws -> AccountSession
    func logoutOpenAI() async throws
    func statusOpenAI() async throws -> CodexHelperStatus
    func listOpenAIModels() async throws -> [String]
    func healthCheck() async throws -> HelperHealthStatus
}

public struct CodexHelperStatus: Codable, Equatable {
    public let provider: String
    public let authenticated: Bool
    public let accountIdentifier: String?
    public let expiresAt: String?
    public let accessibleModelIDs: [String]?
}

public struct HelperHealthStatus: Codable, Equatable {
    public let status: String
    public let version: Int
}

public struct CodexHelperModelsResponse: Codable, Equatable {
    public let models: [String]
}

public final class CodexHelperClient: CodexHelperClientProtocol {
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
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func loginOpenAI() async throws -> AccountSession {
        var request = URLRequest(url: configuration.codexHelperBaseURL.appending(path: "/v1/auth/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.codexHelperToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try encoder.encode(HelperAuthRequest(provider: .openAI))

        let (data, _) = try await data(for: request)
        return try decoder.decode(AccountSession.self, from: data)
    }

    public func logoutOpenAI() async throws {
        var request = URLRequest(url: configuration.codexHelperBaseURL.appending(path: "/v1/auth/logout"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.codexHelperToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try encoder.encode(HelperAuthRequest(provider: .openAI))
        _ = try await data(for: request)
    }

    public func statusOpenAI() async throws -> CodexHelperStatus {
        var request = URLRequest(url: configuration.codexHelperBaseURL.appending(path: "/v1/auth/status"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(configuration.codexHelperToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await data(for: request)
        _ = response
        return try decoder.decode(CodexHelperStatus.self, from: data)
    }

    public func listOpenAIModels() async throws -> [String] {
        var request = URLRequest(url: configuration.codexHelperBaseURL.appending(path: "/v1/models/codex"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(configuration.codexHelperToken)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await data(for: request)
        return try decoder.decode(CodexHelperModelsResponse.self, from: data).models
    }

    public func healthCheck() async throws -> HelperHealthStatus {
        var request = URLRequest(url: configuration.codexHelperBaseURL.appending(path: "/health"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(configuration.codexHelperToken)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await data(for: request)
        return try decoder.decode(HelperHealthStatus.self, from: data)
    }

    private func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AccountLoginError.sessionExchangeFailed("Invalid Codex helper response.")
            }
            guard (200..<300).contains(http.statusCode) else {
                if http.statusCode == 401 {
                    throw AccountLoginError.sessionExchangeFailed("Codex helper rejected the request. Check the helper token in Settings.")
                }
                let message = String(data: data, encoding: .utf8) ?? "Codex helper returned status \(http.statusCode)."
                throw AccountLoginError.sessionExchangeFailed(message)
            }
            return (data, http)
        } catch let error as AccountLoginError {
            throw error
        } catch let error as URLError {
            if error.code == .cannotConnectToHost || error.code == .networkConnectionLost || error.code == .timedOut {
                throw AccountLoginError.sessionExchangeFailed("Codex helper is not running. Start it with: cd /Users/reidchatham/Developer/App/LangTools-account-login/cli && swift run LangToolsCLI serve")
            }
            throw AccountLoginError.sessionExchangeFailed(error.localizedDescription)
        } catch {
            throw AccountLoginError.sessionExchangeFailed(error.localizedDescription)
        }
    }
}

private struct HelperAuthRequest: Codable {
    let provider: AccountLoginProvider
}
