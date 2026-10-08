import Foundation
import HelperLink
import Darwin

public struct MobileDevice: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let createdAt: Date
    public let capabilities: [String]
    let tokenHash: String
}

/// Only hashes persist. Codes and returned bearer tokens never enter the device file.
public actor MobileDeviceStore {
    public static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".langtools/mobile/devices-v1.json")
    public let helperID: String
    /// Capabilities granted to every device this store mints; validated in init.
    public nonisolated let capabilities: [String]
    private let fileURL: URL
    private var records: [MobileDevice]
    private var pairing: (code: String, expiry: Date)?
    private let now: @Sendable () -> Date

    public init(helperID: String, capabilities: [String] = ["ollama"],
                fileURL: URL = MobileDeviceStore.defaultURL, now: @escaping @Sendable () -> Date = { Date() }) throws {
        guard UUID(uuidString: helperID) != nil, MobileHelperCapabilities.isValid(capabilities) else { throw MobileHelperError.invalidStore }
        self.helperID = helperID
        self.capabilities = capabilities
        self.fileURL = fileURL
        self.now = now
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Self.requirePrivate(directory, directory: true)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try Self.requirePrivate(fileURL, directory: false)
            let data = try Data(contentsOf: fileURL)
            guard data.count <= 128 * 1024 else { throw MobileHelperError.invalidStore }
            let persisted = try JSONDecoder().decode(Persisted.self, from: data)
            guard persisted.helperID == helperID, persisted.devices.count <= 64,
                  Set(persisted.devices.map(\.id)).count == persisted.devices.count,
                  persisted.devices.allSatisfy({ UUID(uuidString: $0.id) != nil && MobileHelperPairingPayload.isDisplayName($0.name)
                      && MobileHelperPairingPayload.isHexSecret($0.tokenHash) && MobileHelperCapabilities.isValid($0.capabilities) })
            else { throw MobileHelperError.invalidStore }
            self.records = persisted.devices
        } else { self.records = [] }
    }

    public func generatePairingCode() throws -> (code: String, expiry: Date) {
        let result = (code: try randomSecret(), expiry: now().addingTimeInterval(300))
        pairing = result
        return result
    }

    public func cancelPairing(code: String? = nil) {
        if code == nil || pairing?.code == code { pairing = nil }
    }

    public func redeem(_ request: MobileHelperPairingRequest) throws -> MobileHelperPairingResponse {
        guard MobileHelperPairingPayload.isHexSecret(request.code), MobileHelperPairingPayload.isDisplayName(request.name),
              let pairing, pairing.expiry > now(),
              SecureTokenComparison.matches(expected: pairing.code, provided: request.code, maximumBytes: 64), records.count < 64
        else { throw MobileHelperError.invalidPairing }
        // Consume before persistence to prevent replay even if writing fails.
        self.pairing = nil
        let token = try randomSecret()
        let device = MobileDevice(id: UUID().uuidString, name: request.name, createdAt: now(), capabilities: capabilities, tokenHash: digest(Data(token.utf8)))
        let updated = records + [device]
        try persist(updated)
        records = updated
        return MobileHelperPairingResponse(helperID: helperID, deviceID: device.id, token: token, capabilities: capabilities)
    }

    public func authenticate(_ token: String?) -> MobileDevice? {
        guard let token, MobileHelperPairingPayload.isHexSecret(token) else { return nil }
        let hash = digest(Data(token.utf8))
        return records.first { SecureTokenComparison.matches(expected: $0.tokenHash, provided: hash, maximumBytes: 64) }
    }

    public func devices() -> [MobileDevice] { records }

    public func revoke(_ id: String) throws {
        let updated = records.filter { $0.id != id }
        try persist(updated)
        records = updated
    }

    private struct Persisted: Codable { let helperID: String; let devices: [MobileDevice] }

    private func persist(_ devices: [MobileDevice]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try Self.requirePrivate(directory, directory: true)
        let temporary = directory.appendingPathComponent(".devices-\(UUID().uuidString)")
        defer { if FileManager.default.fileExists(atPath: temporary.path) { try? FileManager.default.removeItem(at: temporary) } }
        try privateWrite(try JSONEncoder().encode(Persisted(helperID: helperID, devices: devices)), to: temporary)
        // Same-directory rename is atomic and retains the temporary file's 0600 mode.
        guard rename(temporary.path, fileURL.path) == 0 else { throw MobileHelperError.invalidStore }
    }

    private static func requirePrivate(_ url: URL, directory: Bool) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG) else { throw MobileHelperError.invalidStore }
    }
}
