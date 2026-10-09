import Foundation

/// Private paired route construction deliberately bypasses neither the strict
/// loopback gate nor TLS: a validated stored credential and its pin lease are required.
struct PairedAccountRoute {
    let snapshot: AccountTransportSelectionStore.Snapshot
    let connection: MobileHelperConnection
    let accountToken: String?

    init(snapshot: AccountTransportSelectionStore.Snapshot, session: AccountSession?) throws {
        connection = try snapshot.requireConnection()
        self.snapshot = snapshot
        if snapshot.provider == .openAI {
            if let session {
                guard session.provider == .openAI, session.accessToken == CodexSessionMarker.value else {
                    throw AccountBackendConfigurationError.credentialMismatch(.codexHelper)
                }
            }
            accountToken = nil
        } else {
            guard let session, session.provider == .claudeCode,
                  !session.isExpired, !session.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AccountBackendConfigurationError.missingCredential(.claudeCodeBackend)
            }
            accountToken = session.accessToken
        }
    }

    func request(path: String, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: connection.credential.endpoint.appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(connection.credential.token)", forHTTPHeaderField: "Authorization")
        if let accountToken { request.setValue(accountToken, forHTTPHeaderField: "X-LangTools-Account-Token") }
        return request
    }

    func data(for request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await connection.session.data(for: request,
                delegate: connection.session.delegate as? any URLSessionTaskDelegate)
            try validate(response)
            return data
        } catch { throw snapshot.actionableError(error) }
    }
    func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw MobileHelperError.accountUnavailable }
        switch response.statusCode {
        case 200..<300: return
        case 300..<400: throw MobileHelperError.redirectRejected
        case 401, 403: throw MobileHelperError.revoked
        default: throw MobileHelperError.accountUnavailable
        }
    }
}

struct PairedAccountCatalogClient {
    func discover(snapshot: AccountTransportSelectionStore.Snapshot, session: AccountSession?) async throws -> (models: [String], identifier: String?) {
        let route = try PairedAccountRoute(snapshot: snapshot, session: session)
        try await MobileHelperPairingClient.verifyHealth(credential: route.connection.credential, session: route.connection.session,
            requiredCapability: snapshot.provider == .openAI ? "codex" : "claude")
        let decoder = JSONDecoder()
        if snapshot.provider == .openAI {
            let statusData = try await route.data(for: route.request(path: "/v1/account/status"))
            let status = try decoder.decode(CodexHelperStatus.self, from: statusData)
            guard status.provider == "openAI", status.authenticated else { throw MobileHelperError.accountUnavailable }
            let modelsData = try await route.data(for: route.request(path: "/v1/models/codex"))
            let models = try decoder.decode(CodexHelperModelsResponse.self, from: modelsData)
            return (AccountSession.normalizedModelIDs(models.models), status.accountIdentifier)
        }
        let data = try await route.data(for: route.request(path: "/v1/claude/models"))
        let models = try decoder.decode(CodexHelperModelsResponse.self, from: data)
        return (models.models, session?.accountIdentifier)
    }
}
