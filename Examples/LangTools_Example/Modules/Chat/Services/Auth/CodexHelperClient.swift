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
    private let configurationProvider: () -> AccountBackendConfiguration
    private var configuration: AccountBackendConfiguration { configurationProvider() }
    private let urlSession: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        configuration: AccountBackendConfiguration? = nil,
        urlSession: URLSession = LoopbackURLSession.shared
    ) {
        self.configurationProvider = { configuration ?? AccountBackendConfiguration() }
        self.urlSession = urlSession
        self.decoder.dateDecodingStrategy = .iso8601
    }

    /// Allows tests to simulate a helper URL/token changing after construction.
    init(configurationProvider: @escaping () -> AccountBackendConfiguration, urlSession: URLSession) {
        self.configurationProvider = configurationProvider
        self.urlSession = urlSession
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func loginOpenAI() async throws -> AccountSession {
        _ = try await healthCheck()

        var request = try helperRequest(path: "/v1/auth/login")
        request.httpMethod = "POST"
        request.timeoutInterval = 330
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(HelperAuthRequest(provider: .openAI))

        let (data, _) = try await data(for: request)
        let session = try decoder.decode(AccountSession.self, from: data)
        guard session.provider == .openAI else {
            throw AccountLoginError.sessionExchangeFailed("Codex helper returned an unsafe account session.")
        }
        return session.canonicalized
    }

    public func logoutOpenAI() async throws {
        var request = try helperRequest(path: "/v1/auth/logout")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(HelperAuthRequest(provider: .openAI))
        _ = try await data(for: request)
    }

    public func statusOpenAI() async throws -> CodexHelperStatus {
        var request = try helperRequest(path: "/v1/auth/status")
        request.httpMethod = "GET"
        let (data, _) = try await data(for: request)
        return try decoder.decode(CodexHelperStatus.self, from: data)
    }

    public func listOpenAIModels() async throws -> [String] {
        var request = try helperRequest(path: "/v1/models/codex")
        request.httpMethod = "GET"
        let (data, _) = try await data(for: request)
        let response = try decoder.decode(CodexHelperModelsResponse.self, from: data)
        return AccountSession.normalizedModelIDs(response.models)
    }

    public func healthCheck() async throws -> HelperHealthStatus {
        var request = try helperRequest(path: "/health")
        request.httpMethod = "GET"
        let (data, _) = try await data(for: request)
        return try decoder.decode(HelperHealthStatus.self, from: data)
    }

    private func helperRequest(path: String) throws -> URLRequest {
        do {
            let route = try configuration.codexHelperRoute()
            var request = URLRequest(url: route.endpoint(path))
            request.setValue("Bearer \(route.credential.value)", forHTTPHeaderField: "Authorization")
            return request
        } catch let error as AccountBackendConfigurationError {
            let message: String
            if error == .missingCredential(.codexHelper) {
                message = "Enter the Codex helper token in Settings before signing in."
            } else {
                message = error.localizedDescription
            }
            throw AccountLoginError.sessionExchangeFailed(message)
        }
    }

    private func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AccountLoginError.sessionExchangeFailed("Invalid Codex helper response.")
            }
            guard (200..<300).contains(http.statusCode) else {
                let helperMessage = (try? decoder.decode(HelperErrorPayload.self, from: data).error)
                let message: String
                switch http.statusCode {
                case 400:
                    message = helperMessage ?? "Codex helper rejected the request as invalid."
                case 401:
                    message = helperMessage == "Unauthorized."
                        ? "Codex helper rejected the request. Check the helper token in Settings."
                        : helperMessage ?? "Codex helper returned status 401."
                case 409:
                    message = helperMessage ?? "A Codex sign-in is already in progress."
                case 504:
                    message = helperMessage ?? "Codex helper timed out. Try again."
                default:
                    message = helperMessage ?? "Codex helper returned status \(http.statusCode)."
                }
                throw AccountLoginError.sessionExchangeFailed(message)
            }
            return (data, http)
        } catch let error as AccountLoginError {
            throw error
        } catch let error as URLError {
            if error.code == .cannotConnectToHost || error.code == .networkConnectionLost || error.code == .timedOut {
                throw AccountLoginError.sessionExchangeFailed("Codex helper is not running. From the cli package, run: swift run LangToolsCLI serve")
            }
            throw AccountLoginError.sessionExchangeFailed(error.localizedDescription)
        } catch {
            throw AccountLoginError.sessionExchangeFailed(error.localizedDescription)
        }
    }
}

private struct HelperErrorPayload: Decodable {
    let error: String
}

private struct HelperAuthRequest: Codable {
    let provider: AccountLoginProvider
}
