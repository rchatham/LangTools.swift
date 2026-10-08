import Foundation
import Security
import CryptoKit
import Network

public enum MobileHelperError: LocalizedError {
    case security(OSStatus)
    case invalidIdentity
    case opensslFailed
    case invalidInterface
    case invalidPairing
    case invalidStore
    case upstreamRejected
    case responseTooLarge

    public var errorDescription: String? {
        switch self {
        case .security(let status): return "Helper security operation failed (\(status))."
        case .invalidIdentity: return "The helper TLS identity could not be loaded. Re-pairing is required after an identity reset."
        case .opensslFailed: return "The system OpenSSL could not generate the helper TLS identity. LAN access remains disabled."
        case .invalidInterface: return "Select an active private IPv4 interface. Public and loopback listeners are not permitted."
        case .invalidPairing: return "The pairing code is invalid, expired or already used. Refresh the QR on the Mac."
        case .invalidStore: return "The helper device store is invalid or not private. LAN access remains disabled."
        case .upstreamRejected: return "The local Ollama response was rejected (redirect or unsupported encoding)."
        case .responseTooLarge: return "The Ollama response exceeded the relay size limit."
        }
    }
}

/// Private identity material lives only in Keychain. Temporary OpenSSL files are private and promptly removed.
/// The certificate is deliberately identity-bound, not IP-bound: phones verify the QR fingerprint and an
/// anchored X.509 chain using the basic policy. Changing LAN addresses must not silently change identity.
public struct MobileTLSIdentity: @unchecked Sendable {
    public let helperID: String
    public let identity: SecIdentity
    public let fingerprint: String

    private struct Stored: Codable {
        let helperID: String
        let password: String
        let pkcs12: Data
    }

    public static func loadOrCreate(service: String = "com.langtools.helper.mobile-identity.v1") throws -> Self {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: "identity"]
        var item: CFTypeRef?
        var lookup = query
        lookup[kSecReturnData as String] = true
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        if status == errSecSuccess {
            guard let data = item as? Data else { throw MobileHelperError.invalidIdentity }
            let stored = try JSONDecoder().decode(Stored.self, from: data)
            return try make(stored)
        }
        guard status == errSecItemNotFound else { throw MobileHelperError.security(status) }
        let stored = try generateMaterial()
        let result = try make(stored)
        var add = query
        add[kSecValueData as String] = try JSONEncoder().encode(stored)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw MobileHelperError.security(added) }
        return result
    }

    /// Isolated ephemeral identity for integration tests; never replaces the persistent helper identity.
    static func ephemeral() throws -> Self { try make(generateMaterial()) }

    public func tlsOptions() throws -> NWProtocolTLS.Options {
        guard let localIdentity = sec_identity_create(identity) else { throw MobileHelperError.invalidIdentity }
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(options.securityProtocolOptions, localIdentity)
        sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv12)
        sec_protocol_options_add_tls_application_protocol(options.securityProtocolOptions, "http/1.1")
        return options
    }

    private static func make(_ stored: Stored) throws -> Self {
        guard UUID(uuidString: stored.helperID) != nil else { throw MobileHelperError.invalidIdentity }
        var options: [String: Any] = [kSecImportExportPassphrase as String: stored.password]
        if #available(macOS 15.0, *) {
            options[kSecImportToMemoryOnly as String] = true
        }
        // macOS 14 imports into the user's protected login Keychain. Data-protection Keychain
        // requires application-identifier entitlements unavailable to this standalone helper.

        var items: CFArray?
        let status = SecPKCS12Import(stored.pkcs12 as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess else { throw MobileHelperError.security(status) }
        guard let first = (items as? [[String: Any]])?.first,
              let value = first[kSecImportItemIdentity as String], CFGetTypeID(value as CFTypeRef) == SecIdentityGetTypeID()
        else { throw MobileHelperError.invalidIdentity }
        let identity = value as! SecIdentity
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else {
            throw MobileHelperError.invalidIdentity
        }
        let der = SecCertificateCopyData(certificate) as Data
        return Self(helperID: stored.helperID, identity: identity, fingerprint: digest(der))
    }

    private static func generateMaterial() throws -> Stored {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("langtools-tls-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer {
            do { try manager.removeItem(at: directory) }
            catch { FileHandle.standardError.write(Data("Unable to remove private TLS temporary directory.\n".utf8)) }
        }
        let helperID = UUID().uuidString
        let password = try randomSecret()
        let config = directory.appendingPathComponent("request.cnf")
        let configuration = """
        [req]
        distinguished_name = dn
        x509_extensions = extensions
        prompt = no
        [dn]
        CN = LangToolsHelper-\(helperID)
        [extensions]
        basicConstraints = critical,CA:FALSE
        keyUsage = critical,digitalSignature,keyEncipherment
        extendedKeyUsage = serverAuth
        """
        try privateWrite(Data(configuration.utf8), to: config)
        let passFile = directory.appendingPathComponent("password")
        try privateWrite(Data(password.utf8), to: passFile)
        let key = directory.appendingPathComponent("key.pem")
        let cert = directory.appendingPathComponent("cert.pem")
        let p12 = directory.appendingPathComponent("identity.p12")
        // Precreate at 0600 so subprocess output never has an intermediate permissive mode.
        for url in [key, cert, p12] { try privateWrite(Data(), to: url) }
        try runOpenSSL(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "3650", "-sha256",
                        "-config", config.path, "-keyout", key.path, "-out", cert.path])
        try runOpenSSL(["pkcs12", "-export", "-inkey", key.path, "-in", cert.path, "-out", p12.path,
                        "-name", "LangToolsHelper-\(helperID)", "-passout", "file:\(passFile.path)"])
        let data = try Data(contentsOf: p12)
        guard !data.isEmpty, data.count < 64 * 1024 else { throw MobileHelperError.invalidIdentity }
        return Stored(helperID: helperID, password: password, pkcs12: data)
    }

    private static func runOpenSSL(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { throw MobileHelperError.opensslFailed }
    }
}

func privateWrite(_ data: Data, to url: URL) throws {
    guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
        throw MobileHelperError.invalidStore
    }
}

func randomSecret() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    guard status == errSecSuccess else { throw MobileHelperError.security(status) }
    return bytes.map { String(format: "%02x", $0) }.joined()
}

func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
