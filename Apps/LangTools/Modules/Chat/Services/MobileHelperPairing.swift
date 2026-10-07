import Combine
import Foundation
import HelperLink

struct MobileHelperPairingClient {
    let sessionFactory: (URL, String) -> URLSession
    init(sessionFactory: @escaping (URL, String) -> URLSession = MobileHelperSessionDelegate.session) {
        self.sessionFactory = sessionFactory
    }

    func pair(_ payload: MobileHelperPairingPayload, deviceName: String) async throws -> MobileHelperConnection {
        _ = try MobileHelperPairingPayload.parse(payload.pairingURL())
        let session = sessionFactory(payload.endpoint, payload.fingerprint)
        do {
            var request = URLRequest(url: payload.endpoint.appendingPathComponent("v1/mobile/pair"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(MobileHelperPairingRequest(code: payload.code, name: String(deviceName.prefix(128))))
            let (data, response) = try await session.data(for: request)
            try Self.validate(response)
            let result = try JSONDecoder().decode(MobileHelperPairingResponse.self, from: data)
            guard result.version == 1, result.helperID == payload.helperID,
                  UUID(uuidString: result.deviceID) != nil, MobileHelperCredential.isSecret(result.token),
                  result.capabilities == ["ollama"] else { throw MobileHelperError.invalidIdentity }
            let credential = MobileHelperCredential(endpoint: payload.endpoint, helperID: payload.helperID,
                fingerprint: payload.fingerprint, name: payload.name, deviceID: result.deviceID,
                token: result.token, capabilities: result.capabilities)
            try await Self.verifyHealth(credential: credential, session: session)
            return MobileHelperConnection(credential: credential, session: session)
        } catch {
            session.invalidateAndCancel()
            throw MobileHelperError.actionable(error, session: session)
        }
    }

    static func verifyHealth(credential: MobileHelperCredential, session: URLSession) async throws {
        var request = URLRequest(url: credential.endpoint.appendingPathComponent("v1/mobile/health"))
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try validate(response)
        let health = try JSONDecoder().decode(MobileHelperHealthResponse.self, from: data)
        guard health.version == 1, health.helperID == credential.helperID,
              health.capabilities == credential.capabilities else { throw MobileHelperError.invalidIdentity }
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
    private let didSelect: () -> Void
    private var generation: UInt64 = 0
    public var pendingGeneration: UInt64 { generation }
    private var pairingTask: Task<Void, Never>?

    public convenience init() {
        self.init(configuration: .shared, client: MobileHelperPairingClient(), didSelect: {
            OllamaService.shared.transportDidChange()
        })
    }
    init(configuration: OllamaEndpointConfiguration, client: MobileHelperPairingClient, didSelect: @escaping () -> Void) {
        self.configuration = configuration; self.client = client; self.didSelect = didSelect
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
        pairingTask = Task {
            do {
                let connection = try await client.pair(payload, deviceName: deviceName)
                guard !Task.isCancelled, generation == capturedGeneration else { return }
                guard configuration.isCurrent(snapshot) else {
                    isPairing = false
                    pairingTask = nil
                    return
                }
                do { try configuration.selectHelper(connection) }
                catch { throw MobileHelperError.persistence(error.localizedDescription) }
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
