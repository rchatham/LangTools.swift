import Combine
import Foundation
import HelperLink

struct MobileHelperPairingClient {
    let sessionFactory: (URL, String) -> URLSession
    init(sessionFactory: @escaping (URL, String) -> URLSession = MobileHelperSessionDelegate.session) {
        self.sessionFactory = sessionFactory
    }

    func pair(_ payload: MobileHelperPairingPayload, deviceName: String) async throws -> MobileHelperConnection {
        // The coordinator already checked the configured link envelope. Validate
        // all typed identity/endpoint/pin/code/name fields before creating transport,
        // without re-encoding a custom-scheme payload as a default-scheme link.
        try payload.validate()
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
            // Invalidation can release the delegate and its recorded pin rejection.
            let actionableError = MobileHelperError.actionable(error, session: session)
            session.invalidateAndCancel()
            throw actionableError
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
    private let scheme: String
    private var generation: UInt64 = 0
    public var pendingGeneration: UInt64 { generation }
    private var pairingTask: Task<Void, Never>?

    public convenience init() {
        self.init(configuration: .shared, client: MobileHelperPairingClient(), didSelect: {
            OllamaService.shared.transportDidChange()
        })
    }
    /// Custom clients use only their own configuration and selection callback.
    public convenience init(configuration: OllamaEndpointConfiguration, scheme: String,
                            didSelect: @escaping () -> Void) throws {
        try self.init(configuration: configuration, scheme: scheme,
            client: MobileHelperPairingClient(), didSelect: didSelect)
    }

    convenience init(configuration: OllamaEndpointConfiguration, client: MobileHelperPairingClient, didSelect: @escaping () -> Void) {
        self.init(configuration: configuration, validatedScheme: "langtools-example-auth", client: client, didSelect: didSelect)
    }

    convenience init(configuration: OllamaEndpointConfiguration, scheme: String,
                     client: MobileHelperPairingClient, didSelect: @escaping () -> Void) throws {
        guard Self.isValidScheme(scheme) else { throw MobileHelperLinkError.invalidPayload }
        self.init(configuration: configuration, validatedScheme: scheme, client: client, didSelect: didSelect)
    }

    private init(configuration: OllamaEndpointConfiguration, validatedScheme: String,
                 client: MobileHelperPairingClient, didSelect: @escaping () -> Void) {
        self.configuration = configuration; self.client = client; self.didSelect = didSelect
        scheme = validatedScheme
    }

    public static func isPairingURL(_ url: URL) -> Bool {
        isPairingURL(url, scheme: "langtools-example-auth")
    }

    public static func isPairingURL(_ url: URL, scheme: String) -> Bool {
        guard isValidScheme(scheme) else { return false }
        return url.scheme?.lowercased() == scheme.lowercased() && url.host?.lowercased() == "helper" && url.path == "/pair"
    }

    private static func isValidScheme(_ scheme: String) -> Bool {
        let bytes = scheme.utf8
        func isLetter(_ byte: UInt8) -> Bool { (65...90).contains(byte) || (97...122).contains(byte) }
        guard let first = bytes.first, isLetter(first) else { return false }
        return bytes.dropFirst().allSatisfy { isLetter($0) || (48...57).contains($0) || $0 == 43 || $0 == 45 || $0 == 46 }
    }
    public func handle(_ url: URL) {
        cancel()
        errorMessage = nil
        do { pendingPairing = try MobileHelperPairingPayload.parse(url, scheme: scheme) }
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
                // The connection's lease retires every discarded successful result,
                // including stale consent/settings and failed credential persistence.
                // Once selected, snapshots/providers keep that same lease alive.
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
