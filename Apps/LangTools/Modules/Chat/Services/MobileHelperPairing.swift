import Combine
import Foundation
import HelperLink

/// Pairing consent and subsequent authenticated grants must match the QR scope.
enum MobileHelperPairingScope {
    static func capabilities(_ payload: MobileHelperPairingPayload) throws -> [String] {
        try payload.validate()
        return payload.capabilities
    }
}

struct MobileHelperPairingClient {
    let sessionFactory: (URL, String) -> URLSession
    init(sessionFactory: @escaping (URL, String) -> URLSession = MobileHelperSessionDelegate.session) {
        self.sessionFactory = sessionFactory
    }

    func pair(_ payload: MobileHelperPairingPayload, deviceName: String) async throws -> MobileHelperConnection {
        _ = try MobileHelperPairingPayload.parse(payload.pairingURL())
        let offeredCapabilities = try MobileHelperPairingScope.capabilities(payload)
        let session = sessionFactory(payload.endpoint, payload.fingerprint)
        do {
            var request = URLRequest(url: payload.endpoint.appendingPathComponent("v1/mobile/pair"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(MobileHelperPairingRequest(code: payload.code, name: String(deviceName.prefix(128))))
            let (data, response) = try await session.data(for: request, delegate: session.delegate as? any URLSessionTaskDelegate)
            try Self.validate(response)
            let result = try JSONDecoder().decode(MobileHelperPairingResponse.self, from: data)
            guard result.version == 1, result.helperID == payload.helperID,
                  UUID(uuidString: result.deviceID) != nil, MobileHelperCredential.isSecret(result.token),
                  MobileHelperCapabilities.isValid(result.capabilities),
                  result.capabilities == offeredCapabilities else { throw MobileHelperError.invalidIdentity }
            let credential = MobileHelperCredential(endpoint: payload.endpoint, helperID: payload.helperID,
                fingerprint: payload.fingerprint, name: payload.name, deviceID: result.deviceID,
                token: result.token, capabilities: result.capabilities)
            try await Self.verifyHealth(credential: credential, session: session)
            return MobileHelperConnection(credential: credential, session: session)
        } catch {
            // Invalidation can release the delegate and its recorded pin rejection.
            let actionableError = MobileHelperError.actionable(error, session: session)
            session.invalidateAndCancel()
            throw actionableError
        }
    }

    /// Pairing requires an exact consent/grant/health match. Reconnect may see
    /// disabled services, but must never expand the stored grant or omit the
    /// capability the caller is about to use.
    static func verifyHealth(credential: MobileHelperCredential, session: URLSession, requiredCapability: String? = nil) async throws {
        var request = URLRequest(url: credential.endpoint.appendingPathComponent("v1/mobile/health"))
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request, delegate: session.delegate as? any URLSessionTaskDelegate)
        try validate(response)
        let health = try JSONDecoder().decode(MobileHelperHealthResponse.self, from: data)
        guard health.version == 1, health.helperID == credential.helperID,
              MobileHelperCapabilities.isValid(health.capabilities) else { throw MobileHelperError.invalidIdentity }
        if let requiredCapability {
            guard Set(health.capabilities).isSubset(of: Set(credential.capabilities)) else {
                throw MobileHelperError.invalidIdentity
            }
            guard health.capabilities.contains(requiredCapability) else {
                throw MobileHelperError.missingCapability(requiredCapability)
            }
        } else {
            guard health.capabilities == credential.capabilities else { throw MobileHelperError.invalidIdentity }
        }
    }

    private static func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw MobileHelperError.unavailable }
        switch response.statusCode {
        case 200..<300: return
        case 300..<400: throw MobileHelperError.redirectRejected
        case 401, 403: throw MobileHelperError.revoked
        default: throw MobileHelperError.unavailable
        }
    }
}

/// URL reception never persists configuration. Only the owning confirmation
/// presenter may redeem, then authenticated health must succeed before selection.
@MainActor
public final class MobileHelperPairingCoordinator: ObservableObject {
    public static let shared = MobileHelperPairingCoordinator()
    @Published public private(set) var pendingPairing: MobileHelperPairingPayload?
    @Published public private(set) var isPairing = false
    @Published public private(set) var errorMessage: String?
    private let configuration: OllamaEndpointConfiguration
    private let client: MobileHelperPairingClient
    private let accountTransports: AccountTransportSelectionStore?
    private let didSelect: () -> Void
    private var generation: UInt64 = 0
    public var pendingGeneration: UInt64 { generation }
    private var pairingTask: Task<Void, Never>?

    public convenience init() {
        self.init(configuration: .shared, client: MobileHelperPairingClient(), accountTransports: .shared, didSelect: {
            OllamaService.shared.transportDidChange()
        })
    }
    init(configuration: OllamaEndpointConfiguration, client: MobileHelperPairingClient, accountTransports: AccountTransportSelectionStore? = nil, didSelect: @escaping () -> Void) {
        self.configuration = configuration; self.client = client; self.accountTransports = accountTransports; self.didSelect = didSelect
    }

    public static func isPairingURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "langtools-example-auth" && url.host?.lowercased() == "helper" && url.path == "/pair"
    }
    public func handle(_ url: URL) {
        cancel()
        errorMessage = nil
        do { pendingPairing = try MobileHelperPairingPayload.parse(url) }
        catch { errorMessage = "Invalid helper pairing QR. Create a new QR on the trusted Mac. \(error.localizedDescription)" }
    }
    public func confirm(_ payload: MobileHelperPairingPayload, generation confirmedGeneration: UInt64, deviceName: String) {
        // Consent binds to exactly what the sheet displayed, including its
        // generation. A replacement link (even A→B→A) invalidates old buttons.
        guard pendingPairing == payload, generation == confirmedGeneration, !isPairing else { return }
        pendingPairing = nil
        isPairing = true
        generation &+= 1
        let capturedGeneration = generation
        let snapshot = configuration.snapshot()
        let accountSnapshots = accountTransports.map { store in
            AccountLoginProvider.allCases.map { store.snapshot(for: $0) }
        } ?? []
        pairingTask = Task {
            do {
                let connection = try await client.pair(payload, deviceName: deviceName)
                // The connection's lease retires every discarded successful result,
                // including stale consent/settings and failed credential persistence.
                // Once selected, snapshots/providers keep that same lease alive.
                guard !Task.isCancelled, generation == capturedGeneration else { return }
                guard configuration.isCurrent(snapshot),
                      accountSnapshots.allSatisfy({ accountTransports?.isCurrent($0) == true }) else {
                    isPairing = false
                    pairingTask = nil
                    return
                }
                do {
                    // Account-only grants must not change the Ollama transport.
                    // Registering does not select Codex/Claude: those choices are explicit.
                    // Persist once before updating either selection. The same
                    // validated connection/lease is then shared by all capabilities.
                    try accountTransports?.registerPairedHelper(connection)
                    if connection.credential.capabilities.contains("ollama") {
                        try configuration.selectHelper(connection, persistCredential: accountTransports == nil)
                    } else {
                        configuration.rejectMissingOllamaGrant(helperID: connection.credential.helperID)
                    }
                } catch { throw MobileHelperError.persistence(error.localizedDescription) }
                didSelect()
            } catch {
                guard !Task.isCancelled, generation == capturedGeneration else { return }
                errorMessage = MobileHelperError.actionable(error).localizedDescription
            }
            guard generation == capturedGeneration else { return }
            isPairing = false
            pairingTask = nil
        }
    }
    public func cancel() {
        generation &+= 1
        pairingTask?.cancel()
        pairingTask = nil
        pendingPairing = nil
        isPairing = false
    }
    public func dismissError() { errorMessage = nil }
}
